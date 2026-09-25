defmodule MetadataApp.ConsultasSqlTest do
  @moduledoc "SPEC-SYS-2509202601 Grupo A: tipo 4, nombre técnico y alta."
  use MetadataApp.DataCase, async: true

  alias MetadataApp.ConsultasSql
  alias MetadataApp.MetaSchema.ConsultaSql
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp unique, do: System.unique_integer([:positive])

  describe "nombre_desde_nav/1" do
    test "prefijo pty_sql_ y segmentos normalizados" do
      assert ConsultasSql.nombre_desde_nav("/Ventas/Rutas Preventa-Activas") == "pty_sql_ventas_rutaspreventaactivas"
      assert ConsultasSql.nombre_desde_nav("/Almacén/2026 Empleados") == "pty_sql_almacen_empleados"
    end

    test "vacío si la navegación no deja nada utilizable" do
      assert ConsultasSql.nombre_desde_nav("") == ""
      assert ConsultasSql.nombre_desde_nav("/123/---") == ""
    end

    test "nunca pasa de 50 caracteres" do
      assert String.length(ConsultasSql.nombre_desde_nav("/" <> String.duplicate("a", 80))) == 50
    end
  end

  describe "crear/1" do
    test "crea el Header tipo 4 no visible y su fila sin SQL" do
      s = unique()

      assert {:ok, {header, consulta_sql}} =
               ConsultasSql.crear(%{"etiqueta" => "Rutas preventa", "nav" => "/dic_rutas_#{s}", "uso" => "diccionario"})

      assert header.schema_context_name == "pty_sql_dic_rutas_#{s}"
      assert header.schema_context_type == 4
      assert header.schema_visible == false
      assert %ConsultaSql{uso: "diccionario", sql: nil, columnas: [], bcs_autorizados: []} = consulta_sql
      assert ConsultasSql.obtener_por_catalogo(header.schema_context_name).id == consulta_sql.id
    end

    test "acepta el uso consulta" do
      assert {:ok, {_header, %ConsultaSql{uso: "consulta"}}} =
               ConsultasSql.crear(%{"etiqueta" => "Reporte", "nav" => "/rep_#{unique()}", "uso" => "consulta"})
    end

    test "rechaza etiqueta vacía, uso inválido y ruta repetida" do
      nav = "/rep_dup_#{unique()}"

      assert {:error, _} = ConsultasSql.crear(%{"etiqueta" => " ", "nav" => nav})
      assert {:error, _} = ConsultasSql.crear(%{"etiqueta" => "X", "nav" => nav, "uso" => "otro"})

      assert {:ok, _} = ConsultasSql.crear(%{"etiqueta" => "X", "nav" => nav})
      assert {:error, "Esa ruta ya la usa otro catálogo o carpeta."} = ConsultasSql.crear(%{"etiqueta" => "Y", "nav" => nav})
    end

    test "un fallo no deja un Header huérfano" do
      nav = "/huerfano_#{unique()}"
      assert {:error, _} = ConsultasSql.crear(%{"etiqueta" => "X", "nav" => nav, "uso" => "otro"})
      assert MetaSchemaContext.obtener_header_por_nav(nav) == nil
    end

    test "obtener_por_catalogo/1 ignora catálogos que no son tipo 4" do
      assert ConsultasSql.obtener_por_catalogo("meta_fixture_cliente") == nil
    end
  end

  describe "validar_sql/3 (Grupo B)" do
    test "detecta columnas con su tipo" do
      assert {:ok, columnas} =
               ConsultasSql.validar_sql("SELECT id, branch_name AS nombre, 1.5::numeric AS saldo FROM meta_schema_branch;", "diccionario")

      assert [%{"nombre" => "id", "tipo" => "integer"}, %{"nombre" => "nombre", "tipo" => "string"}, %{"nombre" => "saldo", "tipo" => "decimal"}] =
               columnas
    end

    test "rechaza SQL vacío, varias sentencias y todo lo que no sea lectura" do
      assert {:error, "Escribe el SQL antes de guardar."} = ConsultasSql.validar_sql("  ", "consulta")
      assert {:error, _} = ConsultasSql.validar_sql("SELECT 1 AS a; SELECT 2 AS b", "consulta")
      assert {:error, _} = ConsultasSql.validar_sql("INSERT INTO meta_schema_branch (branch_name) VALUES ('x')", "consulta")
      assert {:error, _} = ConsultasSql.validar_sql("DROP TABLE meta_schema_branch", "consulta")

      assert {:error, mensaje} =
               ConsultasSql.validar_sql("WITH x AS (DELETE FROM meta_schema_branch WHERE false RETURNING id) SELECT id FROM x", "consulta")

      assert mensaje =~ "data-modifying"
    end

    test "rechaza tablas inexistentes y errores de sintaxis con el mensaje de la base" do
      assert {:error, mensaje} = ConsultasSql.validar_sql("SELECT id FROM tabla_que_no_existe", "consulta")
      assert mensaje =~ "tabla_que_no_existe"
      assert {:error, _} = ConsultasSql.validar_sql("SELEC id FROM meta_schema_branch", "consulta")
    end

    test "reglas de Diccionario: id entero y al menos una columna más" do
      assert {:error, m1} = ConsultasSql.validar_sql("SELECT branch_name FROM meta_schema_branch", "diccionario")
      assert m1 =~ "«id»"
      assert {:error, _} = ConsultasSql.validar_sql("SELECT branch_name AS id, 1 AS x FROM meta_schema_branch", "diccionario")
      assert {:error, m2} = ConsultasSql.validar_sql("SELECT id FROM meta_schema_branch", "diccionario")
      assert m2 =~ "descripción"
    end

    test "una Consulta no exige id" do
      assert {:ok, [%{"nombre" => "nombre"}]} = ConsultasSql.validar_sql("SELECT branch_name AS nombre FROM meta_schema_branch", "consulta")
    end

    test "rechaza nombres de columna que no sirven como identificador" do
      assert {:error, mensaje} = ConsultasSql.validar_sql(~s(SELECT id, branch_name AS "Nombre Sucursal" FROM meta_schema_branch), "consulta")
      assert mensaje =~ "AS"
    end

    test "R11: no deja quitar columnas que usan los campos" do
      assert {:error, mensaje} = ConsultasSql.validar_sql("SELECT id, branch_name AS nombre FROM meta_schema_branch", "diccionario", ["id", "sucursal"])
      assert mensaje =~ "sucursal"
    end

    test "no deja la vista temporal viva en la conexión" do
      {:ok, _} = ConsultasSql.validar_sql("SELECT 1 AS id, 'a' AS d", "diccionario")
      assert {:ok, %{rows: [[nil]]}} = Repo.query("SELECT to_regclass('_validacion_sql')::text", [])
    end
  end

  describe "ejecución segura (Grupo B)" do
    test "corta la consulta al pasar el tiempo máximo" do
      assert {:error, :tiempo_excedido} = ConsultasSql.ejecutar(fn -> Repo.query!("SELECT pg_sleep(6)", []) end)
    end

    test "es de solo lectura" do
      assert {:error, mensaje} = ConsultasSql.ejecutar(fn -> Repo.query!("SELECT nextval('meta_schema_branch_id_seq')", []) end)
      assert mensaje =~ "read-only"
    end

    test "vista_previa/1 regresa a lo más 5 filas" do
      nombre = "pty_sql_vp_#{unique()}"
      Repo.query!("CREATE VIEW #{nombre} AS SELECT g AS id, 'fila ' || g AS descripcion FROM generate_series(1, 8) g", [])

      assert {:ok, %{columnas: ["id", "descripcion"], filas: filas}} = ConsultasSql.vista_previa(nombre)
      assert length(filas) == 5
    end

    test "vista_previa/1 no acepta nombres que no sean pty_sql_*" do
      assert_raise ArgumentError, fn -> ConsultasSql.vista_previa("meta_schema_branch; DROP TABLE x") end
    end
  end

  describe "alcance_por_columnas/3 (Grupo B)" do
    setup do
      nombre = "pty_sql_alc_#{unique()}"

      Repo.query!(
        "CREATE VIEW #{nombre} AS SELECT * FROM (VALUES (1, 10, 'a'), (2, 20, 'b'), (3, NULL, 'c')) AS t(id, branch_id, descripcion)",
        []
      )

      %{nombre: nombre, columnas: [%{"nombre" => "id"}, %{"nombre" => "branch_id"}, %{"nombre" => "descripcion"}]}
    end

    defp ids(nombre, scope, columnas) do
      from(v in nombre, select: field(v, :id), order_by: field(v, :id))
      |> ConsultasSql.alcance_por_columnas(scope, columnas)
      |> Repo.all()
    end

    test "acota por branch_id y deja visibles las filas sin valor", %{nombre: nombre, columnas: columnas} do
      scope = %MetadataApp.Autenticacion.Scope{usuario: %{id: -1}, empresa_activa: %{id: -1}, branches_permitidos: [10]}
      assert ids(nombre, scope, columnas) == [1, 3]
    end

    test "sin sesión no regresa nada", %{nombre: nombre, columnas: columnas} do
      assert ids(nombre, nil, columnas) == []
    end

    test "sin columnas de control no acota", %{nombre: nombre} do
      scope = %MetadataApp.Autenticacion.Scope{usuario: %{id: -1}, empresa_activa: %{id: -1}}
      assert ids(nombre, scope, [%{"nombre" => "id"}]) == [1, 2, 3]
      assert ConsultasSql.columnas_de_alcance([%{"nombre" => "id"}, %{"nombre" => "sales_unit_id"}]) == ["sales_unit_id"]
    end
  end

  describe "dependencias con catálogos (Grupo H, R29)" do
    setup do
      {:ok, {header, _}} = ConsultasSql.crear(%{"etiqueta" => "Dep", "nav" => "/dep_#{unique()}", "uso" => "consulta"})
      {:ok, _} = ConsultasSql.guardar_sql(header.schema_context_name, "SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo")
      %{nombre: header.schema_context_name}
    end

    test "detecta la SQL View que usa una tabla o una columna", %{nombre: nombre} do
      assert Enum.any?(ConsultasSql.vistas_que_dependen("meta_fixture_equipo"), &(&1.nombre == nombre))
      assert Enum.any?(ConsultasSql.vistas_que_dependen("meta_fixture_equipo", "meta_fixture_equipo_nombre_equipo"), &(&1.nombre == nombre))
      refute Enum.any?(ConsultasSql.vistas_que_dependen("meta_fixture_equipo", "fecha_registro"), &(&1.nombre == nombre))
    end

    test "eliminar_campo/4 rechaza antes de tocar la columna, nombrando la SQL View" do
      campo = "meta_fixture_equipo_nombre_equipo"

      assert {:error, mensaje} =
               MetadataApp.BusinessProcessBuilder.CatalogoGenerador.eliminar_campo("meta_fixture_equipo", campo, campo)

      assert mensaje =~ "SQL View"
      assert Enum.any?(MetaSchemaContext.listar_detalles("meta_fixture_equipo"), &(&1.schema_context_field == campo))
    end
  end
end
