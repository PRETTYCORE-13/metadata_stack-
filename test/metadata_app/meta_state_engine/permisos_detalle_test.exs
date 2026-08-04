defmodule MetadataApp.MetaStateEngine.PermisosDetalleTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.Estado

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # header_clientes() alcanza como "header_detalle" de prueba acá: estas
  # funciones son un lookup puro por (estado_id, header_detalle_id), no
  # validan que ese header sea de verdad un catálogo detalle — mismo
  # criterio que ya usan los tests de MetaEstadosAdmin para otras funciones
  # (Estado/Transicion no exigen que el header "sea" nada en particular).
  describe "permiso_detalle/2" do
    test "sin fila, todo denegado (deny-by-default)" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "permiso_sin_fila_#{unique()}"})

      assert MetaEstadosAdmin.permiso_detalle(estado.id, header.id) == %{
               permite_insertar: false,
               permite_actualizar: false,
               permite_borrar: false
             }
    end

    test "con fila, devuelve los flags guardados" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "permiso_con_fila_#{unique()}"})

      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_insertar)

      assert MetaEstadosAdmin.permiso_detalle(estado.id, header.id) == %{
               permite_insertar: true,
               permite_actualizar: false,
               permite_borrar: false
             }
    end
  end

  describe "toggle_permiso_detalle/3" do
    test "primera vez crea la fila con el flag en true" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "toggle_crea_#{unique()}"})

      {:ok, permiso} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_borrar)

      assert permiso.permite_borrar == true
      assert permiso.insert_guid != nil
    end

    test "click de nuevo invierte el flag (true -> false)" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "toggle_invierte_#{unique()}"})

      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_actualizar)
      {:ok, permiso} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_actualizar)

      assert permiso.permite_actualizar == false
      assert permiso.update_guid != nil
    end

    test "no pisa los otros 2 flags de la misma fila" do
      header = header_clientes()
      estado = fixture_estado(header, %{nombre: "toggle_no_pisa_#{unique()}"})

      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_insertar)
      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado.id, header.id, :permite_borrar)

      assert MetaEstadosAdmin.permiso_detalle(estado.id, header.id) == %{
               permite_insertar: true,
               permite_actualizar: false,
               permite_borrar: true
             }
    end
  end

  describe "listar_permisos_detalle/1" do
    test "trae solo las filas de estados de ESE header, keyed por {estado_id, header_detalle_id}" do
      header = header_clientes()
      estado_a = fixture_estado(header, %{nombre: "listar_a_#{unique()}"})
      estado_b = fixture_estado(header, %{nombre: "listar_b_#{unique()}"})

      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado_a.id, header.id, :permite_insertar)
      {:ok, _} = MetaEstadosAdmin.toggle_permiso_detalle(estado_b.id, header.id, :permite_borrar)

      mapa = MetaEstadosAdmin.listar_permisos_detalle(header.id)

      assert %{permite_insertar: true} = mapa[{estado_a.id, header.id}]
      assert %{permite_borrar: true} = mapa[{estado_b.id, header.id}]
    end
  end
end
