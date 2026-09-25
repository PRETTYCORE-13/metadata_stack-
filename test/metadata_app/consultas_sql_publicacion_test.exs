defmodule MetadataApp.ConsultasSqlPublicacionTest do
  @moduledoc "SPEC-SYS-2509202601 Grupo I (R31-R32): export/import y paquete de publicación."
  use MetadataApp.DataCase, async: false

  alias MetadataApp.{ConsultasSql, MetaImportExport, MetaPublicador}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}

  defp unique, do: System.unique_integer([:positive])

  defp sql_view(sql) do
    {:ok, {header, _}} = ConsultasSql.crear(%{"etiqueta" => "Pub", "nav" => "/pub_#{unique()}"})
    {:ok, _} = ConsultasSql.guardar_sql(header.schema_context_name, sql)
    {:ok, _} = ConsultasSql.autorizar_bc(header.schema_context_name, "meta_fixture_cliente")
    MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "consultas_sql_pub_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "el .meta.json de una SQL View lleva su definición; el de un catálogo no" do
    header = sql_view("SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo")
    dir = tmp_dir()

    MetaSchemaContext.exportar_header(header, dir)
    json = Jason.decode!(File.read!(Path.join(dir, "#{header.schema_context_name}.meta.json")))

    assert %{"uso" => "diccionario", "sql" => sql, "columnas" => [_, _], "bcs_autorizados" => ["meta_fixture_cliente"]} = json["consulta_sql"]
    assert sql =~ "meta_fixture_equipo"

    MetaSchemaContext.exportar_header(Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente"), dir)
    refute Map.has_key?(Jason.decode!(File.read!(Path.join(dir, "meta_fixture_cliente.meta.json"))), "consulta_sql")
  end

  test "importar crea la definición y su permiso; reimportar sincroniza lo que cambió" do
    nombre = "pty_sql_importada_#{unique()}"
    dir = tmp_dir()

    contexto = fn sql ->
      %{
        "schema_context_name" => nombre,
        "schema_context_label" => "Importada",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => false,
        "schema_context_type" => 4,
        "detalles" => [],
        "consulta_sql" => %{"uso" => "diccionario", "sql" => sql, "columnas" => [%{"nombre" => "id"}], "bcs_autorizados" => ["meta_fixture_cliente"]}
      }
    end

    File.write!(Path.join(dir, "#{nombre}.meta.json"), Jason.encode!(contexto.("SELECT 1 AS id, 'a' AS d")))
    mensajes = MetaImportExport.importar_meta(dir)
    assert Enum.any?(mensajes, &(&1 =~ "definición SQL creada"))
    assert ConsultasSql.obtener_por_catalogo(nombre).sql == "SELECT 1 AS id, 'a' AS d"
    assert MetadataApp.Permissions.permiso_existe?(nombre, "leer")

    File.write!(Path.join(dir, "#{nombre}.meta.json"), Jason.encode!(contexto.("SELECT 2 AS id, 'b' AS d")))
    assert Enum.any?(MetaImportExport.importar_meta(dir), &(&1 =~ "definición SQL actualizada"))
    assert ConsultasSql.obtener_por_catalogo(nombre).sql == "SELECT 2 AS id, 'b' AS d"

    refute Enum.any?(MetaImportExport.importar_meta(dir), &(&1 =~ "definición SQL"))
  end

  test "el paquete de una SQL View incluye los catálogos que usa su SQL" do
    header = sql_view("SELECT e.id, e.meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo e")
    paquete = MetaSchemaContext.calcular_paquete_publicacion([header.schema_context_name])

    assert header.schema_context_name in paquete
    assert "meta_fixture_equipo" in paquete
  end

  test "el paquete de un catálogo con un campo que usa un Diccionario incluye ese Diccionario" do
    header = sql_view("SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo")
    cliente = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    detalle = Repo.get_by!(Detail, meta_schema_header_id: cliente.id, schema_context_field: "meta_fixture_cliente_edad")

    props =
      detalle.schema_context_properties
      |> Map.merge(%{"tipo" => "referencia", "catalogo" => "meta_fixture_equipo", "diccionario" => %{"consulta" => header.schema_context_name, "descripcion" => ["nombre"]}})

    detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

    assert header.schema_context_name in MetaSchemaContext.calcular_paquete_publicacion(["meta_fixture_cliente"])
  end

  test "MetaPublicador valida una SQL View por su SQL, no por un autómata" do
    header = sql_view("SELECT 1 AS id, 'a' AS d")
    assert {:ok, %{catalogos: catalogos}} = MetaPublicador.validar([header.schema_context_name])
    assert header.schema_context_name in catalogos

    {:ok, {sin_sql, _}} = ConsultasSql.crear(%{"etiqueta" => "Sin SQL", "nav" => "/sin_sql_#{unique()}"})
    assert {:error, mensaje} = MetaPublicador.validar([sin_sql.schema_context_name])
    assert mensaje =~ "SQL"
  end
end
