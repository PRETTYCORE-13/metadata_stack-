defmodule MetadataApp.MetaStateEngineTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaStateEngine
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyClientes

  # Fixtures del motor: header real de "pty_clientes" (ya existe en la base,
  # generado por el Motor BC) + un mini-grafo de 2 estados propio de cada
  # test, aislado por el sandbox (no toca datos de otros tests ni persiste
  # entre corridas).
  defp fixture_estados_y_transicion(accion \\ "activar", reglas \\ []) do
    header = Repo.get_by!(Header, schema_context_name: "pty_clientes")

    {:ok, nuevo} =
      %Estado{}
      |> Estado.changeset(%{
        meta_schema_header_id: header.id,
        nombre: "nuevo_#{unique()}",
        es_inicial: true,
        orden: 1
      })
      |> put_change(:insert_guid, guid())
      |> Repo.insert()

    {:ok, activo} =
      %Estado{}
      |> Estado.changeset(%{
        meta_schema_header_id: header.id,
        nombre: "activo_#{unique()}",
        orden: 2
      })
      |> put_change(:insert_guid, guid())
      |> Repo.insert()

    {:ok, transicion} =
      %Transicion{}
      |> Transicion.changeset(%{
        meta_schema_header_id: header.id,
        accion: accion,
        etiqueta: "Activar",
        estado_origen_id: nuevo.id,
        estado_destino_id: activo.id
      })
      |> put_change(:insert_guid, guid())
      |> Repo.insert()

    Enum.each(reglas, fn attrs ->
      %TransicionRegla{}
      |> TransicionRegla.changeset(Map.put(attrs, :transicion_id, transicion.id))
      |> put_change(:insert_guid, guid())
      |> Repo.insert!()
    end)

    %{header: header, nuevo: nuevo, activo: activo, transicion: transicion}
  end

  defp fixture_cliente(estado_id) do
    %{
      pty_clientes_nombre: "cliente prueba #{unique()}",
      pty_clientes_edad: 30,
      pty_clientes_venta: Decimal.new("100.00")
    }
    |> then(&PtyClientes.changeset(%PtyClientes{}, &1))
    |> put_change(:insert_guid, guid())
    |> put_change(:estado_id, estado_id)
    |> Repo.insert!()
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  describe "ejecutar_transicion/3 — transición válida" do
    test "mueve el registro al estado destino y escribe el evento" do
      %{nuevo: nuevo, activo: activo} = fixture_estados_y_transicion()
      cliente = fixture_cliente(nuevo.id)

      assert {:ok, actualizado} = MetaStateEngine.ejecutar_transicion(cliente, "activar", %{})
      assert actualizado.estado_id == activo.id

      {:ok, res} =
        Ecto.Adapters.SQL.query(
          Repo,
          "select estado_origen_id, estado_destino_id, accion from meta_schema_transicion_eventos where registro_id = $1",
          [cliente.id]
        )

      assert res.rows == [[nuevo.id, activo.id, "activar"]]
    end

    test "aborta y no cambia nada si una postcondición transaccional falla" do
      %{nuevo: nuevo} =
        fixture_estados_y_transicion("activar", [
          %{tipo: "post", regla: "prueba_falla", transaccional: true, orden: 1}
        ])

      cliente = fixture_cliente(nuevo.id)

      assert {:error, {:postcondicion_fallida, _razon}} =
               MetaStateEngine.ejecutar_transicion(cliente, "activar", %{})

      recargado = Repo.get!(PtyClientes, cliente.id)
      assert recargado.estado_id == nuevo.id

      {:ok, res} =
        Ecto.Adapters.SQL.query(
          Repo,
          "select count(*) from meta_schema_transicion_eventos where registro_id = $1",
          [cliente.id]
        )

      assert res.rows == [[0]]
    end
  end

  describe "ejecutar_transicion/3 — transición inválida" do
    test "rechaza una acción que no existe desde el estado actual" do
      %{nuevo: nuevo} = fixture_estados_y_transicion()
      cliente = fixture_cliente(nuevo.id)

      assert {:error, {:transicion_invalida, %{estado_actual_id: estado_id}}} =
               MetaStateEngine.ejecutar_transicion(cliente, "accion_inexistente", %{})

      assert estado_id == nuevo.id
    end

    test "usa el estado REAL leído ahora, no el que trae el struct pasado por el caller" do
      %{nuevo: nuevo, activo: activo} = fixture_estados_y_transicion()
      cliente = fixture_cliente(nuevo.id)

      # Alguien más ya lo movió a "activo" mientras el caller tenía una copia
      # vieja en memoria (estado_id: nuevo.id).
      Repo.update_all(from(c in PtyClientes, where: c.id == ^cliente.id),
        set: [estado_id: activo.id]
      )

      cliente_desactualizado = %{cliente | estado_id: nuevo.id}

      assert {:error, {:transicion_invalida, %{estado_actual_id: estado_id}}} =
               MetaStateEngine.ejecutar_transicion(cliente_desactualizado, "activar", %{})

      assert estado_id == activo.id
    end

    test "junta TODAS las precondiciones fallidas, sin cortocircuito" do
      %{nuevo: nuevo} =
        fixture_estados_y_transicion("activar", [
          %{tipo: "pre", regla: "prueba_falla", params: %{"mensaje" => "falla 1"}, orden: 1},
          %{tipo: "pre", regla: "prueba_falla", params: %{"mensaje" => "falla 2"}, orden: 2}
        ])

      cliente = fixture_cliente(nuevo.id)

      assert {:error, {:precondiciones, fallas}} =
               MetaStateEngine.ejecutar_transicion(cliente, "activar", %{})

      assert length(fallas) == 2
      assert Enum.map(fallas, & &1.mensaje) == ["falla 1", "falla 2"]

      recargado = Repo.get!(PtyClientes, cliente.id)
      assert recargado.estado_id == nuevo.id
    end
  end

  describe "ejecutar_transicion/3 — concurrencia" do
    test "dos llamadas simultáneas a la misma transición: solo una gana, la otra ve conflicto" do
      %{nuevo: nuevo} = fixture_estados_y_transicion()
      cliente = fixture_cliente(nuevo.id)
      parent = self()

      correr = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        MetaStateEngine.ejecutar_transicion(cliente, "activar", %{})
      end

      resultados =
        [Task.async(correr), Task.async(correr)]
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(resultados, &match?({:ok, _}, &1)) == 1
      assert Enum.count(resultados, &match?({:error, :conflicto_concurrencia}, &1)) == 1
    end
  end
end
