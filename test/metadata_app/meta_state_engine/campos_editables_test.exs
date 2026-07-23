defmodule MetadataApp.MetaStateEngine.CamposEditablesTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
  defp header_equipos_nfl, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_equipo")

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
  # estados" reusando un fixture real y permanente (meta_fixture_equipo,
  # ver priv/repo/migrations/20260723220000_crear_fixtures_de_test.exs) en
  # vez de depender de un catálogo pty_* descartable, que por diseño puede
  # borrarse entre sesiones (nunca vive en git) y ya rompió este test más
  # de una vez en el pasado.
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
      meta_fixture_cliente_nombre: "cliente #{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    }

    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> put_change(:insert_guid, guid())
    |> put_change(:estado_id, estado_id)
    |> Repo.insert!()
  end

  describe "campos_editables/2 — catálogo SIN motor de estados" do
    test "devuelve todos los campos, sin restringir nada" do
      header = header_equipos_nfl()
      desactivar_motor(header)

      assert MetaStateEngine.campos_editables("meta_fixture_equipo", nil) == [
               "meta_fixture_equipo_nombre_equipo"
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
          campos_editables: ["meta_fixture_cliente_nombre"]
        })

      t_activo =
        fixture_transicion(header, %{
          accion: "guardar_#{unique()}",
          etiqueta: "Guardar",
          estado_origen_id: activo.id,
          estado_destino_id: activo.id,
          campos_editables: ["meta_fixture_cliente_nombre", "meta_fixture_cliente_edad"]
        })

      assert MetaStateEngine.campos_editables("meta_fixture_cliente", t_nuevo) == ["meta_fixture_cliente_nombre"]

      assert Enum.sort(MetaStateEngine.campos_editables("meta_fixture_cliente", t_activo)) == [
               "meta_fixture_cliente_edad",
               "meta_fixture_cliente_nombre"
             ]
    end

    test "sin transición resuelta (nil) no habilita ningún campo" do
      header = header_clientes()
      fixture_estado(header, %{nombre: "editables_solo_#{unique()}", es_inicial: true})

      assert MetaStateEngine.campos_editables("meta_fixture_cliente", nil) == []
    end
  end

  describe "estado_inicial/1" do
    test "nil si el catálogo no adoptó el motor" do
      header = header_equipos_nfl()
      desactivar_motor(header)

      assert MetaStateEngine.estado_inicial("meta_fixture_equipo") == nil
    end

    test "devuelve el estado marcado es_inicial: true" do
      header = header_clientes()
      inicial = fixture_estado(header, %{nombre: "inicial_#{unique()}", es_inicial: true})
      fixture_estado(header, %{nombre: "otro_#{unique()}"})

      assert MetaStateEngine.estado_inicial("meta_fixture_cliente").id == inicial.id
    end
  end

  describe "CatalogoGenerico.crear/2 — asignación automática del estado inicial" do
    test "catálogo sin motor de estados: estado_id sigue en nil" do
      header = header_equipos_nfl()
      desactivar_motor(header)

      {:ok, equipo} =
        CatalogoGenerico.crear(MetaFixtureEquipo, %{
          "meta_fixture_equipo_nombre_equipo" => "equipo #{unique()}"
        })

      assert equipo.estado_id == nil
    end

    test "catálogo con motor de estados: nace en el estado inicial" do
      header = header_clientes()
      inicial = fixture_estado(header, %{nombre: "crear_inicial_#{unique()}", es_inicial: true})

      {:ok, cliente} =
        CatalogoGenerico.crear(MetaFixtureCliente, %{
          "meta_fixture_cliente_nombre" => "cliente #{unique()}",
          "meta_fixture_cliente_edad" => 25,
          "meta_fixture_cliente_venta" => "10.00"
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
        campos_editables: ["meta_fixture_cliente_nombre"]
      })

      cliente = fixture_cliente(estado.id)

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(cliente, %{"meta_fixture_cliente_nombre" => "nombre nuevo"})

      assert actualizado.meta_fixture_cliente_nombre == "nombre nuevo"
    end

    test "rechaza (con error visible) un campo que no está en campos_editables de la transición actual" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "act_rechazado_#{unique()}", es_inicial: true})

      fixture_transicion(header, %{
        accion: "guardar",
        etiqueta: "Guardar",
        estado_origen_id: estado.id,
        estado_destino_id: estado.id,
        campos_editables: ["meta_fixture_cliente_nombre"]
      })

      # meta_fixture_cliente_edad NO está en campos_editables de esta transición.
      cliente = fixture_cliente(estado.id)

      assert {:error, changeset} =
               CatalogoGenerico.actualizar(cliente, %{"meta_fixture_cliente_edad" => 99})

      assert "no editable en el estado actual" in errors_on(changeset).meta_fixture_cliente_edad
      assert Repo.get!(MetaFixtureCliente, cliente.id).meta_fixture_cliente_edad == 30
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
        campos_editables: ["meta_fixture_cliente_nombre"]
      })

      cliente = fixture_cliente(estado.id)

      assert {:error, changeset} =
               CatalogoGenerico.actualizar(cliente, %{
                 "meta_fixture_cliente_nombre" => "cambio válido",
                 "estado_id" => otro.id
               })

      assert "no editable en el estado actual" in errors_on(changeset).estado_id
      assert Repo.get!(MetaFixtureCliente, cliente.id).estado_id == estado.id
    end

    test "catálogo sin motor de estados sigue funcionando sin restricción (compat)" do
      header = header_equipos_nfl()
      desactivar_motor(header)

      {:ok, equipo} =
        CatalogoGenerico.crear(MetaFixtureEquipo, %{
          "meta_fixture_equipo_nombre_equipo" => "equipo #{unique()}"
        })

      assert {:ok, actualizado} =
               CatalogoGenerico.actualizar(equipo, %{
                 "meta_fixture_equipo_nombre_equipo" => "otro nombre"
               })

      assert actualizado.meta_fixture_equipo_nombre_equipo == "otro nombre"
    end
  end
end
