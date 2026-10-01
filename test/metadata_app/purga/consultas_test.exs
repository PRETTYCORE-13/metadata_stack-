defmodule MetadataApp.Purga.ConsultasTest do
  @moduledoc "Purga de Consultas y Consultas SQL (SPEC-ARQ-3009202601, R15, Grupo E2)."
  use MetadataApp.DataCase, async: true

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Purga.Base
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup do
    s = System.unique_integer([:positive])
    catalogo = "pty_cq_cat#{s}"
    consulta_sql = "pty_sql_cq#{s}"

    {:ok, {_, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(catalogo, 1, []))
    Repo.query!(~s|CREATE TABLE "#{catalogo}" (id bigserial PRIMARY KEY, nombre text)|, [])
    {:ok, {h_sql, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(consulta_sql, 4, []))

    priv = Path.join(System.tmp_dir!(), "purga_cq_#{s}")
    File.mkdir_p!(priv)
    on_exit(fn -> File.rm_rf!(priv) end)

    %{catalogo: catalogo, consulta_sql: consulta_sql, h_sql: h_sql, priv: priv}
  end

  defp attrs(nombre, tipo, detalles) do
    %{
      "schema_context_name" => nombre,
      "schema_context_label" => nombre,
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => false,
      "schema_context_type" => tipo,
      "detalles" => detalles
    }
  end

  defp registro_consulta_sql(h_sql, uso) do
    ahora = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "meta_schema_consulta_sql",
        [
          %{
            meta_schema_header_id: h_sql.id,
            uso: uso,
            insert_guid: "x",
            inserted_at: ahora,
            updated_at: ahora
          }
        ],
        returning: [:id]
      )

    id
  end

  defp endpoint(consulta_sql_id, opts) do
    admin = usuario_fixture()

    {:ok, empresa} =
      MetadataApp.Autenticacion.crear_empresa_para_usuario(
        "Empresa cq #{System.unique_integer()}",
        admin.id
      )

    ahora = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("meta_schema_consulta_endpoint", [
      %{
        nombre: "ep_cq",
        metodo: "GET",
        ruta: "cq",
        empresa_id: empresa.id,
        meta_schema_consulta_sql_id: consulta_sql_id,
        insert_guid: "x",
        delete_guid: opts[:delete_guid],
        inserted_at: ahora,
        updated_at: ahora
      }
    ])
  end

  defp params(nombre),
    do: %{
      artefacto: nombre,
      tablas: [nombre],
      versiones: [],
      filas_confirmadas: 0,
      usuario_email: "dev@x.mx"
    }

  defp header?(t),
    do: Repo.exists?(from h in "meta_schema_header", where: h.schema_context_name == ^t)

  defp objeto?(t),
    do:
      Repo.query!(
        "SELECT to_regclass($1) IS NOT NULL OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = $1)",
        [t]
      ).rows == [[true]]

  test "un Diccionario (vista) libre se purga: sin vista, sin registro, sin header", c do
    Repo.query!(
      ~s|CREATE VIEW "#{c.consulta_sql}" AS SELECT id, nombre AS descripcion FROM "#{c.catalogo}"|,
      []
    )

    registro_consulta_sql(c.h_sql, "diccionario")

    assert {:ok, %{tablas: [%{objeto: "vista", filas: 0}]}} =
             Base.impacto(c.consulta_sql, [c.consulta_sql], [], priv_dir: c.priv)

    assert {:ok, %{resultado: "ok"}} = Base.ejecutar(params(c.consulta_sql), priv_dir: c.priv)

    refute objeto?(c.consulta_sql)
    refute header?(c.consulta_sql)

    refute Repo.exists?(
             from s in "meta_schema_consulta_sql", where: s.meta_schema_header_id == ^c.h_sql.id
           )

    # El catálogo del que leía sigue intacto.
    assert objeto?(c.catalogo)
  end

  test "un Servicio (función) libre se purga", c do
    Repo.query!(
      ~s|CREATE FUNCTION "#{c.consulta_sql}"() RETURNS bigint LANGUAGE sql AS $$ SELECT 1::bigint $$|,
      []
    )

    registro_consulta_sql(c.h_sql, "servicio")

    assert {:ok, %{tablas: [%{objeto: "funcion"}]}} =
             Base.impacto(c.consulta_sql, [c.consulta_sql], [], priv_dir: c.priv)

    assert {:ok, %{resultado: "ok"}} = Base.ejecutar(params(c.consulta_sql), priv_dir: c.priv)
    refute objeto?(c.consulta_sql)
  end

  test "un Diccionario usado por un campo bloquea", c do
    Repo.query!(~s|CREATE VIEW "#{c.consulta_sql}" AS SELECT 1 AS id|, [])

    {:ok, _} =
      MetaSchemaContext.crear_header_con_detalles(
        attrs("#{c.catalogo}_usa", 1, [
          %{
            "schema_context_field" => "cliente",
            "schema_context_properties" => %{
              "etiqueta" => "Cliente",
              "tipo" => "referencia",
              "orden" => 0,
              "visible" => true,
              "editable" => true,
              "diccionario" => %{"consulta" => c.consulta_sql}
            }
          }
        ])
      )

    assert {:ok, %{dependencias: [dep]}} =
             Base.impacto(c.consulta_sql, [c.consulta_sql], [], priv_dir: c.priv)

    assert dep =~ "usa el Diccionario #{c.consulta_sql}"
    assert {:error, _} = Base.ejecutar(params(c.consulta_sql), priv_dir: c.priv)
    assert header?(c.consulta_sql)
  end

  test "un Endpoint vivo bloquea; uno con borrado lógico se borra junto", c do
    Repo.query!(~s|CREATE VIEW "#{c.consulta_sql}" AS SELECT 1 AS id|, [])
    id = registro_consulta_sql(c.h_sql, "servicio")

    endpoint(id, [])

    assert {:ok, %{dependencias: [dep]}} =
             Base.impacto(c.consulta_sql, [c.consulta_sql], [], priv_dir: c.priv)

    assert dep =~ "Endpoint «ep_cq»"

    Repo.update_all(
      from(e in "meta_schema_consulta_endpoint", where: e.meta_schema_consulta_sql_id == ^id),
      set: [delete_guid: "borrado"]
    )

    assert {:ok, %{resultado: "ok"}} = Base.ejecutar(params(c.consulta_sql), priv_dir: c.priv)

    refute Repo.exists?(
             from e in "meta_schema_consulta_endpoint",
               where: e.meta_schema_consulta_sql_id == ^id
           )
  end

  test "una Consulta SQL que lee la tabla bloquea la purga del catálogo, no al revés", c do
    Repo.query!(~s|CREATE VIEW "#{c.consulta_sql}" AS SELECT id FROM "#{c.catalogo}"|, [])

    assert {:ok, %{dependencias: [dep]}} =
             Base.impacto(c.catalogo, [c.catalogo], [], priv_dir: c.priv)

    assert dep =~ c.consulta_sql

    assert {:ok, %{dependencias: []}} =
             Base.impacto(c.consulta_sql, [c.consulta_sql], [], priv_dir: c.priv)
  end
end
