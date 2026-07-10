defmodule MetadataApp.MetaStateEngine.CamposEditablesTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaStateEngine
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaSchema.Estado
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyClientes

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "pty_clientes")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # Marca `campo` (nombre de meta_schema_detail.schema_context_field) como
  # editable solo en `estados_ids`, mergeando sobre sus properties actuales
  # (rollback automático por el sandbox al terminar el test).
  defp marcar_editable_en(header, campo, estados_ids) do
    detail = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: campo)
    props = Map.put(detail.schema_context_properties, "editable_en", estados_ids)

    detail
    |> Ecto.Changeset.change(%{schema_context_properties: props})
    |> Repo.update!()
  end

  defp fixture_cliente(estado_id) do
    attrs = %{
      pty_clientes_nombre: "cliente #{unique()}",
      pty_clientes_edad: 30,
      pty_clientes_venta: Decimal.new("100.00")
    }

    %PtyClientes{}
    |> PtyClientes.changeset(attrs)
    |> put_change(:insert_guid, guid())
    |> put_change(:estado_id, estado_id)
    |> Repo.insert!()
  end

  describe "campos_editables/2 — catálogo SIN motor de estados" do
    test "devuelve todos los campos, sin restringir nada" do
      # pty_canal no tiene ninguna fila en meta_schema_estados.
      campos = MetaStateEngine.campos_editables("pty_canal", nil)
      assert Enum.sort(campos) == ["canal_nombre", "canal_orden"]
    end
  end

  describe "campos_editables/2 — catálogo CON motor de estados" do
    test "solo devuelve los campos con editable_en para el estado actual" do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "editables_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "editables_activo_#{unique()}"})

      marcar_editable_en(header, "pty_clientes_nombre", [nuevo.id, activo.id])
      marcar_editable_en(header, "pty_clientes_edad", [activo.id])
      # pty_clientes_venta no declara editable_en -> nunca editable.

      assert Enum.sort(MetaStateEngine.campos_editables("pty_clientes", nuevo.id)) == [
               "pty_clientes_nombre"
             ]

      assert Enum.sort(MetaStateEngine.campos_editables("pty_clientes", activo.id)) == [
               "pty_clientes_edad",
               "pty_clientes_nombre"
             ]
    end

    test "estado_id nil no habilita ningún campo" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "editables_solo_#{unique()}", es_inicial: true})
      marcar_editable_en(header, "pty_clientes_nombre", [estado.id])

      assert MetaStateEngine.campos_editables("pty_clientes", nil) == []
    end
  end

  describe "estado_inicial/1" do
    test "nil si el catálogo no adoptó el motor" do
      assert MetaStateEngine.estado_inicial("pty_canal") == nil
    end

    test "devuelve el estado marcado es_inicial: true" do
      header = header_clientes()
      inicial = fixture_estado(header, %{nombre: "inicial_#{unique()}", es_inicial: true})
      fixture_estado(header, %{nombre: "otro_#{unique()}"})

      assert MetaStateEngine.estado_inicial("pty_clientes").id == inicial.id
    end
  end

  describe "CatalogoGenerico.crear/2 — asignación automática del estado inicial" do
    test "catálogo sin motor de estados: estado_id sigue en nil" do
      {:ok, canal} =
        CatalogoGenerico.crear(MetadataApp.MetaBusinessProcess.Catalogos.PtyCanal, %{
          "canal_nombre" => "canal #{unique()}",
          "canal_orden" => 1
        })

      assert canal.estado_id == nil
    end

    test "catálogo con motor de estados: nace en el estado inicial" do
      header = header_clientes()
      inicial = fixture_estado(header, %{nombre: "crear_inicial_#{unique()}", es_inicial: true})

      {:ok, cliente} =
        CatalogoGenerico.crear(PtyClientes, %{
          "pty_clientes_nombre" => "cliente #{unique()}",
          "pty_clientes_edad" => 25,
          "pty_clientes_venta" => "10.00"
        })

      assert cliente.estado_id == inicial.id
    end
  end

  describe "CatalogoGenerico.actualizar/2 — whitelist por estado" do
    test "permite actualizar un campo declarado editable_en para el estado actual" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_permitido_#{unique()}", es_inicial: true})
      marcar_editable_en(header, "pty_clientes_nombre", [estado.id])

      cliente = fixture_cliente(estado.id)

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(cliente, %{"pty_clientes_nombre" => "nombre nuevo"})

      assert actualizado.pty_clientes_nombre == "nombre nuevo"
    end

    test "rechaza (con error visible) un campo que no está en la whitelist del estado actual" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_rechazado_#{unique()}", es_inicial: true})
      marcar_editable_en(header, "pty_clientes_nombre", [estado.id])
      # pty_clientes_edad NO está en editable_en para este estado.

      cliente = fixture_cliente(estado.id)

      assert {:error, changeset} =
               CatalogoGenerico.actualizar(cliente, %{"pty_clientes_edad" => 99})

      assert "no editable en el estado actual" in errors_on(changeset).pty_clientes_edad
      assert Repo.get!(PtyClientes, cliente.id).pty_clientes_edad == 30
    end

    test "nunca permite tocar estado_id por esta vía, aunque venga en los attrs" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_estado_id_#{unique()}", es_inicial: true})
      otro = fixture_estado(header, %{nombre: "act_estado_id_otro_#{unique()}"})
      marcar_editable_en(header, "pty_clientes_nombre", [estado.id])

      cliente = fixture_cliente(estado.id)

      assert {:error, changeset} =
               CatalogoGenerico.actualizar(cliente, %{
                 "pty_clientes_nombre" => "cambio válido",
                 "estado_id" => otro.id
               })

      assert "no editable en el estado actual" in errors_on(changeset).estado_id
      assert Repo.get!(PtyClientes, cliente.id).estado_id == estado.id
    end

    test "catálogo sin motor de estados sigue funcionando sin restricción (compat)" do
      {:ok, canal} =
        CatalogoGenerico.crear(MetadataApp.MetaBusinessProcess.Catalogos.PtyCanal, %{
          "canal_nombre" => "canal #{unique()}",
          "canal_orden" => 1
        })

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(canal, %{"canal_orden" => 2})

      assert actualizado.canal_orden == 2
    end
  end
end
