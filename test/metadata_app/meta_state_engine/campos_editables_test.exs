defmodule MetadataApp.MetaStateEngine.CamposEditablesTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PtyClientes, PtyEquiposNfl}

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "pty_clientes")
  defp header_equipos_nfl, do: Repo.get_by!(Header, schema_context_name: "pty_equipos_nfl")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_transicion(header, attrs) do
    %Transicion{}
    |> Transicion.changeset(Map.merge(%{meta_schema_header_id: header.id}, attrs))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # Vacía el autómata de `header` (reglas + transiciones + estados + su
  # historial) SOLO dentro de la transacción del test (sandbox: se revierte
  # solo al terminar) -- así se puede probar "catálogo sin motor de
  # estados" reusando un catálogo real y permanente (pty_equipos_nfl) en vez
  # de depender de uno descartable que puede borrarse entre sesiones (ya
  # pasó una vez con pty_canal).
  defp desactivar_motor(header) do
    MetaEstadosAdmin.purgar_historial(header.id)

    transicion_ids =
      from(t in Transicion, where: t.meta_schema_header_id == ^header.id, select: t.id)
      |> Repo.all()

    from(r in TransicionRegla, where: r.transicion_id in ^transicion_ids) |> Repo.delete_all()
    from(t in Transicion, where: t.meta_schema_header_id == ^header.id) |> Repo.delete_all()
    from(e in Estado, where: e.meta_schema_header_id == ^header.id) |> Repo.delete_all()
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
      header = header_equipos_nfl()
      desactivar_motor(header)

      assert MetaStateEngine.campos_editables("pty_equipos_nfl", nil) == [
               "pty_equipos_nfl_nombre_equipo"
             ]
    end
  end

  describe "campos_editables/2 — catálogo CON motor de estados" do
    test "solo devuelve los campos declarados en campos_editables de la transición" do
      header = header_clientes()
      nuevo = fixture_estado(header, %{nombre: "editables_nuevo_#{unique()}", es_inicial: true})
      activo = fixture_estado(header, %{nombre: "editables_activo_#{unique()}"})

      t_nuevo =
        fixture_transicion(header, %{
          accion: "guardar_#{unique()}",
          etiqueta: "Guardar",
          estado_origen_id: nuevo.id,
          estado_destino_id: nuevo.id,
          campos_editables: ["pty_clientes_nombre"]
        })

      t_activo =
        fixture_transicion(header, %{
          accion: "guardar_#{unique()}",
          etiqueta: "Guardar",
          estado_origen_id: activo.id,
          estado_destino_id: activo.id,
          campos_editables: ["pty_clientes_nombre", "pty_clientes_edad"]
        })

      assert MetaStateEngine.campos_editables("pty_clientes", t_nuevo) == ["pty_clientes_nombre"]

      assert Enum.sort(MetaStateEngine.campos_editables("pty_clientes", t_activo)) == [
               "pty_clientes_edad",
               "pty_clientes_nombre"
             ]
    end

    test "sin transición resuelta (nil) no habilita ningún campo" do
      header = header_clientes()
      fixture_estado(header, %{nombre: "editables_solo_#{unique()}", es_inicial: true})

      assert MetaStateEngine.campos_editables("pty_clientes", nil) == []
    end
  end

  describe "estado_inicial/1" do
    test "nil si el catálogo no adoptó el motor" do
      header = header_equipos_nfl()
      desactivar_motor(header)

      assert MetaStateEngine.estado_inicial("pty_equipos_nfl") == nil
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
      header = header_equipos_nfl()
      desactivar_motor(header)

      {:ok, equipo} =
        CatalogoGenerico.crear(PtyEquiposNfl, %{
          "pty_equipos_nfl_nombre_equipo" => "equipo #{unique()}"
        })

      assert equipo.estado_id == nil
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

  describe "CatalogoGenerico.actualizar/2 — whitelist por transición" do
    test "permite actualizar un campo declarado en campos_editables de la transición guardar" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_permitido_#{unique()}", es_inicial: true})

      fixture_transicion(header, %{
        accion: "guardar",
        etiqueta: "Guardar",
        estado_origen_id: estado.id,
        estado_destino_id: estado.id,
        campos_editables: ["pty_clientes_nombre"]
      })

      cliente = fixture_cliente(estado.id)

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(cliente, %{"pty_clientes_nombre" => "nombre nuevo"})

      assert actualizado.pty_clientes_nombre == "nombre nuevo"
    end

    test "rechaza (con error visible) un campo que no está en campos_editables de la transición actual" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_rechazado_#{unique()}", es_inicial: true})

      fixture_transicion(header, %{
        accion: "guardar",
        etiqueta: "Guardar",
        estado_origen_id: estado.id,
        estado_destino_id: estado.id,
        campos_editables: ["pty_clientes_nombre"]
      })

      # pty_clientes_edad NO está en campos_editables de esta transición.
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

      fixture_transicion(header, %{
        accion: "guardar",
        etiqueta: "Guardar",
        estado_origen_id: estado.id,
        estado_destino_id: estado.id,
        campos_editables: ["pty_clientes_nombre"]
      })

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
      header = header_equipos_nfl()
      desactivar_motor(header)

      {:ok, equipo} =
        CatalogoGenerico.crear(PtyEquiposNfl, %{
          "pty_equipos_nfl_nombre_equipo" => "equipo #{unique()}"
        })

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(equipo, %{
                 "pty_equipos_nfl_nombre_equipo" => "otro nombre"
               })

      assert actualizado.pty_equipos_nfl_nombre_equipo == "otro nombre"
    end
  end
end
