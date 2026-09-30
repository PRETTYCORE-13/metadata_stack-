defmodule MetadataApp.ConsultasSqlTest do
  @moduledoc "SPEC-SYS-2509202601 Grupo A: tipo 4, nombre técnico y alta."
  use MetadataApp.DataCase, async: true

  alias MetadataApp.ConsultasSql
  alias MetadataApp.MetaSchema.ConsultaSql
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp unique, do: System.unique_integer([:positive])

  describe "nombre_desde_nav/1" do
    test "prefijo pty_sql_ y segmentos normalizados" do
      assert ConsultasSql.nombre_desde_nav("/Ventas/Rutas Preventa-Activas") ==
               "pty_sql_ventas_rutaspreventaactivas"

      assert ConsultasSql.nombre_desde_nav("/Almacén/2026 Empleados") ==
               "pty_sql_almacen_empleados"
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
               ConsultasSql.crear(%{
                 "etiqueta" => "Rutas preventa",
                 "nav" => "/dic_rutas_#{s}",
                 "uso" => "diccionario"
               })

      assert header.schema_context_name == "pty_sql_dic_rutas_#{s}"
      assert header.schema_context_type == 4
      assert header.schema_visible == false

      assert %ConsultaSql{uso: "diccionario", sql: nil, columnas: [], bcs_autorizados: []} =
               consulta_sql

      assert ConsultasSql.obtener_por_catalogo(header.schema_context_name).id == consulta_sql.id
    end

    test "acepta el uso consulta" do
      assert {:ok, {_header, %ConsultaSql{uso: "consulta"}}} =
               ConsultasSql.crear(%{
                 "etiqueta" => "Reporte",
                 "nav" => "/rep_#{unique()}",
                 "uso" => "consulta"
               })
    end

    # SPEC-SYS-2509202601 K1
    test "acepta el uso servicio, sin parámetros y con el tope por default" do
      assert {:ok, {_header, %ConsultaSql{uso: "servicio", parametros: [], tope_renglones: 1000}}} =
               ConsultasSql.crear(%{
                 "etiqueta" => "Servicio",
                 "nav" => "/svc_#{unique()}",
                 "uso" => "servicio"
               })
    end

    test "rechaza etiqueta vacía, uso inválido y ruta repetida" do
      nav = "/rep_dup_#{unique()}"

      assert {:error, _} = ConsultasSql.crear(%{"etiqueta" => " ", "nav" => nav})
      assert {:error, _} = ConsultasSql.crear(%{"etiqueta" => "X", "nav" => nav, "uso" => "otro"})

      assert {:ok, _} = ConsultasSql.crear(%{"etiqueta" => "X", "nav" => nav})

      assert {:error, "Esa ruta ya la usa otro catálogo o carpeta."} =
               ConsultasSql.crear(%{"etiqueta" => "Y", "nav" => nav})
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
               ConsultasSql.validar_sql(
                 "SELECT id, branch_name AS nombre, 1.5::numeric AS saldo FROM meta_schema_branch;",
                 "diccionario"
               )

      assert [
               %{"nombre" => "id", "tipo" => "integer"},
               %{"nombre" => "nombre", "tipo" => "string"},
               %{"nombre" => "saldo", "tipo" => "decimal"}
             ] =
               columnas
    end

    test "rechaza SQL vacío, varias sentencias y todo lo que no sea lectura" do
      assert {:error, "Escribe el SQL antes de guardar."} =
               ConsultasSql.validar_sql("  ", "consulta")

      assert {:error, _} = ConsultasSql.validar_sql("SELECT 1 AS a; SELECT 2 AS b", "consulta")

      assert {:error, _} =
               ConsultasSql.validar_sql(
                 "INSERT INTO meta_schema_branch (branch_name) VALUES ('x')",
                 "consulta"
               )

      assert {:error, _} = ConsultasSql.validar_sql("DROP TABLE meta_schema_branch", "consulta")

      assert {:error, mensaje} =
               ConsultasSql.validar_sql(
                 "WITH x AS (DELETE FROM meta_schema_branch WHERE false RETURNING id) SELECT id FROM x",
                 "consulta"
               )

      assert mensaje =~ "data-modifying"
    end

    test "rechaza tablas inexistentes y errores de sintaxis con el mensaje de la base" do
      assert {:error, mensaje} =
               ConsultasSql.validar_sql("SELECT id FROM tabla_que_no_existe", "consulta")

      assert mensaje =~ "tabla_que_no_existe"

      assert {:error, _} =
               ConsultasSql.validar_sql("SELEC id FROM meta_schema_branch", "consulta")
    end

    test "reglas de Diccionario: id entero y al menos una columna más" do
      assert {:error, m1} =
               ConsultasSql.validar_sql(
                 "SELECT branch_name FROM meta_schema_branch",
                 "diccionario"
               )

      assert m1 =~ "«id»"

      assert {:error, _} =
               ConsultasSql.validar_sql(
                 "SELECT branch_name AS id, 1 AS x FROM meta_schema_branch",
                 "diccionario"
               )

      assert {:error, m2} =
               ConsultasSql.validar_sql("SELECT id FROM meta_schema_branch", "diccionario")

      assert m2 =~ "descripción"
    end

    test "una Consulta no exige id" do
      assert {:ok, [%{"nombre" => "nombre"}]} =
               ConsultasSql.validar_sql(
                 "SELECT branch_name AS nombre FROM meta_schema_branch",
                 "consulta"
               )
    end

    test "rechaza nombres de columna que no sirven como identificador" do
      assert {:error, mensaje} =
               ConsultasSql.validar_sql(
                 ~s(SELECT id, branch_name AS "Nombre Sucursal" FROM meta_schema_branch),
                 "consulta"
               )

      assert mensaje =~ "AS"
    end

    test "R11: no deja quitar columnas que usan los campos" do
      assert {:error, mensaje} =
               ConsultasSql.validar_sql(
                 "SELECT id, branch_name AS nombre FROM meta_schema_branch",
                 "diccionario",
                 ["id", "sucursal"]
               )

      assert mensaje =~ "sucursal"
    end

    test "no deja la vista temporal viva en la conexión" do
      {:ok, _} = ConsultasSql.validar_sql("SELECT 1 AS id, 'a' AS d", "diccionario")

      assert {:ok, %{rows: [[nil]]}} =
               Repo.query("SELECT to_regclass('_validacion_sql')::text", [])
    end
  end

  describe "ejecución segura (Grupo B)" do
    test "corta la consulta al pasar el tiempo máximo" do
      assert {:error, :tiempo_excedido} =
               ConsultasSql.ejecutar(fn -> Repo.query!("SELECT pg_sleep(6)", []) end)
    end

    test "es de solo lectura" do
      assert {:error, mensaje} =
               ConsultasSql.ejecutar(fn ->
                 Repo.query!("SELECT nextval('meta_schema_branch_id_seq')", [])
               end)

      assert mensaje =~ "read-only"
    end

    test "vista_previa/1 regresa a lo más 5 filas" do
      nombre = "pty_sql_vp_#{unique()}"

      Repo.query!(
        "CREATE VIEW #{nombre} AS SELECT g AS id, 'fila ' || g AS descripcion FROM generate_series(1, 8) g",
        []
      )

      assert {:ok, %{columnas: ["id", "descripcion"], filas: filas}} =
               ConsultasSql.vista_previa(nombre)

      assert length(filas) == 5
    end

    test "vista_previa/1 no acepta nombres que no sean pty_sql_*" do
      assert_raise ArgumentError, fn ->
        ConsultasSql.vista_previa("meta_schema_branch; DROP TABLE x")
      end
    end
  end

  describe "alcance_por_columnas/3 (Grupo B)" do
    setup do
      nombre = "pty_sql_alc_#{unique()}"

      Repo.query!(
        "CREATE VIEW #{nombre} AS SELECT * FROM (VALUES (1, 10, 'a'), (2, 20, 'b'), (3, NULL, 'c')) AS t(id, branch_id, descripcion)",
        []
      )

      %{
        nombre: nombre,
        columnas: [%{"nombre" => "id"}, %{"nombre" => "branch_id"}, %{"nombre" => "descripcion"}]
      }
    end

    defp ids(nombre, scope, columnas) do
      from(v in nombre, select: field(v, :id), order_by: field(v, :id))
      |> ConsultasSql.alcance_por_columnas(scope, columnas)
      |> Repo.all()
    end

    test "acota por branch_id y deja visibles las filas sin valor", %{
      nombre: nombre,
      columnas: columnas
    } do
      scope = %MetadataApp.Autenticacion.Scope{
        usuario: %{id: -1},
        empresa_activa: %{id: -1},
        branches_permitidos: [10]
      }

      assert ids(nombre, scope, columnas) == [1, 3]
    end

    test "sin sesión no regresa nada", %{nombre: nombre, columnas: columnas} do
      assert ids(nombre, nil, columnas) == []
    end

    test "sin columnas de control no acota", %{nombre: nombre} do
      scope = %MetadataApp.Autenticacion.Scope{usuario: %{id: -1}, empresa_activa: %{id: -1}}
      assert ids(nombre, scope, [%{"nombre" => "id"}]) == [1, 2, 3]

      assert ConsultasSql.columnas_de_alcance([
               %{"nombre" => "id"},
               %{"nombre" => "sales_unit_id"}
             ]) == ["sales_unit_id"]
    end
  end

  describe "dependencias con catálogos (Grupo H, R29)" do
    setup do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Dep",
          "nav" => "/dep_#{unique()}",
          "uso" => "consulta"
        })

      {:ok, _} =
        ConsultasSql.guardar_sql(
          header.schema_context_name,
          "SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo"
        )

      %{nombre: header.schema_context_name}
    end

    test "detecta la SQL View que usa una tabla o una columna", %{nombre: nombre} do
      assert Enum.any?(
               ConsultasSql.vistas_que_dependen("meta_fixture_equipo"),
               &(&1.nombre == nombre)
             )

      assert Enum.any?(
               ConsultasSql.vistas_que_dependen(
                 "meta_fixture_equipo",
                 "meta_fixture_equipo_nombre_equipo"
               ),
               &(&1.nombre == nombre)
             )

      refute Enum.any?(
               ConsultasSql.vistas_que_dependen("meta_fixture_equipo", "fecha_registro"),
               &(&1.nombre == nombre)
             )
    end

    test "eliminar_campo/4 rechaza antes de tocar la columna, nombrando la SQL View" do
      campo = "meta_fixture_equipo_nombre_equipo"

      assert {:error, mensaje} =
               MetadataApp.BusinessProcessBuilder.CatalogoGenerador.eliminar_campo(
                 "meta_fixture_equipo",
                 campo,
                 campo
               )

      assert mensaje =~ "SQL View"

      assert Enum.any?(
               MetaSchemaContext.listar_detalles("meta_fixture_equipo"),
               &(&1.schema_context_field == campo)
             )
    end
  end

  describe "dependencias de un Servicio (SPEC-SYS-2509202601 L4, R54)" do
    setup do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "DepSvc",
          "nav" => "/dep_svc_#{unique()}",
          "uso" => "servicio"
        })

      {:ok, _} =
        ConsultasSql.guardar_sql(
          header.schema_context_name,
          "SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo WHERE id = :equipo",
          %{"parametros" => [%{"nombre" => "equipo", "tipo" => "entero", "obligatorio" => true}]}
        )

      %{nombre: header.schema_context_name}
    end

    test "detecta el Servicio que usa una tabla o una columna", %{nombre: nombre} do
      assert Enum.any?(
               ConsultasSql.vistas_que_dependen("meta_fixture_equipo"),
               &(&1.nombre == nombre)
             )

      assert Enum.any?(
               ConsultasSql.vistas_que_dependen(
                 "meta_fixture_equipo",
                 "meta_fixture_equipo_nombre_equipo"
               ),
               &(&1.nombre == nombre)
             )

      refute Enum.any?(
               ConsultasSql.vistas_que_dependen("meta_fixture_equipo", "fecha_registro"),
               &(&1.nombre == nombre)
             )
    end

    test "eliminar_campo/4 rechaza la columna que usa el Servicio" do
      campo = "meta_fixture_equipo_nombre_equipo"

      assert {:error, mensaje} =
               MetadataApp.BusinessProcessBuilder.CatalogoGenerador.eliminar_campo(
                 "meta_fixture_equipo",
                 campo,
                 campo
               )

      assert mensaje =~ "SQL View"

      assert Enum.any?(
               MetaSchemaContext.listar_detalles("meta_fixture_equipo"),
               &(&1.schema_context_field == campo)
             )
    end

    test "catalogos_que_usa/1 da lo mismo que para una vista con el mismo SQL", %{nombre: nombre} do
      {:ok, {vista, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "DepV",
          "nav" => "/dep_v_#{unique()}",
          "uso" => "consulta"
        })

      {:ok, _} =
        ConsultasSql.guardar_sql(
          vista.schema_context_name,
          "SELECT id, meta_fixture_equipo_nombre_equipo AS nombre FROM meta_fixture_equipo WHERE id = 1"
        )

      assert ConsultasSql.catalogos_que_usa(nombre) ==
               ConsultasSql.catalogos_que_usa(vista.schema_context_name)
    end

    test "L5 (R55): no se elimina si lo mencionan las reglas de un catálogo", %{nombre: nombre} do
      {:ok, {otro, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Pedido de prueba",
          "nav" => "/l5_#{unique()}",
          "uso" => "consulta"
        })

      regla =
        %MetadataApp.MetaSchema.ReglaCodigo{}
        |> MetadataApp.MetaSchema.ReglaCodigo.changeset(%{
          meta_schema_header_id: otro.id,
          tipo: "post",
          codigo_fuente: ~s|MetaBcApi.ejecutar_servicio("#{nombre}", %{}, contexto)|
        })
        |> Ecto.Changeset.change(%{insert_guid: "l5prueba"})
        |> Repo.insert!()

      assert [%{catalogo: _, etiqueta: "Pedido de prueba", tipo: "post"}] =
               ConsultasSql.reglas_que_usan(nombre)

      assert {:error, mensaje} = ConsultasSql.eliminar(nombre)
      assert mensaje == "No se puede eliminar: lo usan las reglas de Pedido de prueba (POST)."
      assert ConsultasSql.obtener_por_catalogo(nombre)

      regla |> Ecto.Changeset.change(%{delete_guid: "borrada"}) |> Repo.update!()
      assert ConsultasSql.reglas_que_usan(nombre) == []
      assert ConsultasSql.eliminar(nombre) == :ok
    end

    test "L5: el _ del nombre no actúa como comodín", %{nombre: nombre} do
      {:ok, {otro, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Otro",
          "nav" => "/l5c_#{unique()}",
          "uso" => "consulta"
        })

      parecido = String.replace(nombre, "_", "X")

      %MetadataApp.MetaSchema.ReglaCodigo{}
      |> MetadataApp.MetaSchema.ReglaCodigo.changeset(%{
        meta_schema_header_id: otro.id,
        tipo: "pre",
        codigo_fuente: "# #{parecido}"
      })
      |> Ecto.Changeset.change(%{insert_guid: "l5comodin"})
      |> Repo.insert!()

      assert ConsultasSql.reglas_que_usan(nombre) == []
    end

    test "Postgres también bloquea borrar la columna directamente", %{nombre: _nombre} do
      assert_raise Postgrex.Error, ~r/depend/, fn ->
        Repo.query!(
          "ALTER TABLE meta_fixture_equipo DROP COLUMN meta_fixture_equipo_nombre_equipo",
          []
        )
      end
    end
  end

  describe "nombre de la migración de la vista" do
    test "cada guardado genera un nombre de migración único (Ecto no acepta nombres repetidos)" do
      a = ConsultasSql.ruta_migracion("vista", "pty_sql_x", "20260925180122")
      b = ConsultasSql.ruta_migracion("vista", "pty_sql_x", "20260925180448")

      assert a == "priv/repo/migrations/20260925180122_vista_pty_sql_x_20260925180122.exs"

      nombre = fn ruta ->
        ruta |> Path.basename(".exs") |> String.split("_", parts: 2) |> List.last()
      end

      refute nombre.(a) == nombre.(b)
    end
  end

  describe "guardar un Servicio (SPEC-SYS-2509202601 L1-L2)" do
    setup do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Svc",
          "nav" => "/l_svc_#{unique()}",
          "uso" => "servicio"
        })

      parametros = [
        %{"nombre" => "empresa", "tipo" => "entero", "obligatorio" => true},
        %{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true},
        %{"nombre" => "desde", "tipo" => "fecha"}
      ]

      %{nombre: header.schema_context_name, parametros: parametros}
    end

    defp funcion_existe(nombre) do
      case Repo.query!(
             "SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = $1",
             [nombre]
           ).rows do
        [[argumentos]] -> argumentos
        [] -> nil
      end
    end

    @sql_valido """
    SELECT e.id AS empresa_id, e.nombre, :desde AS desde
      FROM meta_schema_empresa e
     WHERE e.id = :empresa OR e.id = ANY(:ids)
    """

    test "crea la función con sus argumentos y guarda parámetros y columnas", %{
      nombre: nombre,
      parametros: parametros
    } do
      assert {:ok, guardada} =
               ConsultasSql.guardar_sql(nombre, @sql_valido, %{
                 "parametros" => parametros,
                 "tope_renglones" => 50
               })

      assert funcion_existe(nombre) == "p_empresa bigint, p_ids bigint[], p_desde date"
      assert Enum.map(guardada.columnas, & &1["nombre"]) == ["empresa_id", "nombre", "desde"]
      assert Enum.find(guardada.columnas, &(&1["nombre"] == "desde"))["tipo"] == "date"

      assert [
               %{"obligatorio" => true},
               %{"obligatorio" => true},
               %{"nombre" => "desde", "obligatorio" => false}
             ] = guardada.parametros

      assert guardada.tope_renglones == 50
      assert guardada.sql == String.trim(@sql_valido)
    end

    test "la función responde con sus argumentos (Postgres real)", %{
      nombre: nombre,
      parametros: parametros
    } do
      # Sin depender de datos de la base de test: devuelve lo que recibe.
      sql =
        "SELECT :empresa AS empresa, cardinality(:ids) AS cuantos, COALESCE(:desde, DATE '2000-01-01') AS desde"

      {:ok, _} = ConsultasSql.guardar_sql(nombre, sql, %{"parametros" => parametros})

      assert %{columns: ["empresa", "cuantos", "desde"], rows: [[7, 3, ~D[2026-10-01]]]} =
               Repo.query!("SELECT * FROM #{nombre}($1, $2, $3)", [7, [1, 2, 3], ~D[2026-10-01]])

      assert %{rows: [[7, 0, ~D[2000-01-01]]]} =
               Repo.query!("SELECT * FROM #{nombre}($1, $2, $3)", [7, [], nil])
    end

    test "volver a guardar con otras columnas reemplaza la función (DROP + CREATE)", %{
      nombre: nombre,
      parametros: parametros
    } do
      {:ok, _} = ConsultasSql.guardar_sql(nombre, @sql_valido, %{"parametros" => parametros})

      assert {:ok, guardada} =
               ConsultasSql.guardar_sql(
                 nombre,
                 "SELECT count(*) AS total FROM meta_schema_empresa WHERE id = :empresa OR id = ANY(:ids)"
               )

      assert Enum.map(guardada.columnas, & &1["nombre"]) == ["total"]

      assert guardada.parametros ==
               Enum.map(parametros, &Map.put_new(&1, "obligatorio", false))
               |> Enum.map(&Map.put_new(&1, "default", nil))
    end

    test "rechaza sin crear nada: parámetro no declarado, escritura, tope inválido o SQL vacío",
         %{nombre: nombre, parametros: parametros} do
      casos = [
        {"SELECT :empresa, :ids, :otro", %{"parametros" => parametros},
         "no están declarados: :otro"},
        {"DELETE FROM meta_schema_empresa WHERE id = :empresa OR id = ANY(:ids)",
         %{"parametros" => parametros}, "syntax error"},
        {@sql_valido, %{"parametros" => parametros, "tope_renglones" => 0}, "tope"},
        {"  ;  ", %{"parametros" => parametros}, "Escribe el SQL"}
      ]

      for {sql, extras, esperado} <- casos do
        assert {:error, mensaje} = ConsultasSql.guardar_sql(nombre, sql, extras)
        assert mensaje =~ esperado
        assert funcion_existe(nombre) == nil
      end

      assert %ConsultaSql{sql: nil, parametros: []} = ConsultasSql.obtener_por_catalogo(nombre)
    end

    test "eliminar un Servicio quita la función", %{nombre: nombre, parametros: parametros} do
      {:ok, _} = ConsultasSql.guardar_sql(nombre, @sql_valido, %{"parametros" => parametros})
      assert funcion_existe(nombre)

      assert ConsultasSql.eliminar(nombre) == :ok
      assert funcion_existe(nombre) == nil
      assert ConsultasSql.obtener_por_catalogo(nombre) == nil
    end

    test "un Diccionario sigue guardándose como vista (R58)" do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Dic",
          "nav" => "/l_dic_#{unique()}",
          "uso" => "diccionario"
        })

      assert {:ok, _} =
               ConsultasSql.guardar_sql(
                 header.schema_context_name,
                 "SELECT id, nombre FROM meta_schema_empresa"
               )

      assert Repo.query!("SELECT count(*) FROM pg_views WHERE viewname = $1", [
               header.schema_context_name
             ]).rows == [[1]]
    end

    test "definicion_funcion/4 y la ruta de la migración" do
      parametros = [
        %{"nombre" => "a", "tipo" => "entero"},
        %{"nombre" => "b", "tipo" => "lista_enteros"}
      ]

      columnas = [%{"nombre" => "order", "tipo_pg" => "numeric(20,4)"}]

      assert ConsultasSql.definicion_funcion("pty_sql_x", parametros, columnas, "SELECT 1") ==
               ~s|CREATE FUNCTION pty_sql_x(p_a bigint, p_b bigint[]) RETURNS TABLE ("order" numeric(20,4)) LANGUAGE sql STABLE BEGIN ATOMIC SELECT 1; END|

      assert ConsultasSql.ruta_migracion("funcion", "pty_sql_x", "20260929120000") ==
               "priv/repo/migrations/20260929120000_funcion_pty_sql_x_20260929120000.exs"
    end
  end

  describe "ejecutar un Servicio (SPEC-SYS-2509202601 grupo M)" do
    @datos "(VALUES (1, 10, 5, 'a'), (2, 20, 5, 'b'), (3, NULL, 6, 'c')) AS t(id, branch_id, empresa_id, descripcion)"

    defp servicio(sql, parametros, tope \\ 1000) do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{"etiqueta" => "M", "nav" => "/m_#{unique()}", "uso" => "servicio"})

      {:ok, _} =
        ConsultasSql.guardar_sql(header.schema_context_name, sql, %{
          "parametros" => parametros,
          "tope_renglones" => tope
        })

      header.schema_context_name
    end

    defp ids_de({:ok, %{filas: filas}}), do: filas |> Enum.map(& &1["id"]) |> Enum.sort()

    setup do
      nombre =
        servicio(
          "SELECT * FROM #{@datos} WHERE t.id = ANY(:ids) AND (:excluir IS NULL OR t.descripcion <> :excluir)",
          [
            %{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true},
            %{"nombre" => "excluir", "tipo" => "texto"}
          ]
        )

      %{nombre: nombre}
    end

    test "M2: regresa columnas y filas como mapas", %{nombre: nombre} do
      assert {:ok, %{columnas: ["id", "branch_id", "empresa_id", "descripcion"], filas: filas}} =
               ConsultasSql.ejecutar_servicio(nombre, %{"ids" => "1,3"}, :sistema)

      assert Enum.sort_by(filas, & &1["id"]) == [
               %{"id" => 1, "branch_id" => 10, "empresa_id" => 5, "descripcion" => "a"},
               %{"id" => 3, "branch_id" => nil, "empresa_id" => 6, "descripcion" => "c"}
             ]
    end

    test "M2 (R41): un texto malicioso es solo un valor", %{nombre: nombre} do
      resultado =
        ConsultasSql.ejecutar_servicio(
          nombre,
          %{"ids" => [1, 2], "excluir" => "a'; DROP TABLE meta_fixture_equipo; --"},
          :sistema
        )

      assert ids_de(resultado) == [1, 2]

      assert Repo.query!("SELECT to_regclass('meta_fixture_equipo') IS NOT NULL", []).rows == [
               [true]
             ]
    end

    test "M1 (R40): un valor inválido se rechaza sin ejecutar", %{nombre: nombre} do
      assert ConsultasSql.ejecutar_servicio(nombre, %{"ids" => "1; DROP TABLE x"}, :sistema) ==
               {:error,
                "El parámetro «ids» no es un valor válido de tipo lista_enteros: \"1; DROP TABLE x\"."}

      assert ConsultasSql.ejecutar_servicio(nombre, %{}, :sistema) ==
               {:error, "Falta el parámetro obligatorio «ids»."}
    end

    test "M3 (R44): alcance por tipo", %{nombre: nombre} do
      todos = %{"ids" => [1, 2, 3]}

      scope = %MetadataApp.Autenticacion.Scope{
        usuario: %{id: -1},
        empresa_activa: %{id: -1},
        branches_permitidos: [10]
      }

      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, todos, :sistema)) == [1, 2, 3]
      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, todos, scope)) == [1, 3]
      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, todos, nil)) == []
      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, todos, {:empresa_fija, 5})) == [1, 2]
    end

    test "M3: sin columnas de control no acota" do
      nombre =
        servicio("SELECT t.id FROM #{@datos} WHERE t.id = ANY(:ids)", [
          %{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true}
        ])

      scope = %MetadataApp.Autenticacion.Scope{
        usuario: %{id: -1},
        empresa_activa: %{id: -1},
        branches_permitidos: []
      }

      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, %{"ids" => [1, 2, 3]}, scope)) == [
               1,
               2,
               3
             ]

      assert ids_de(
               ConsultasSql.ejecutar_servicio(nombre, %{"ids" => [1, 2, 3]}, {:empresa_fija, 5})
             ) == [1, 2, 3]
    end

    test "M5 (R43): pasar el tope rechaza la llamada completa; justo en el tope pasa" do
      sql = "SELECT t.id FROM #{@datos} WHERE t.id = ANY(:ids)"
      parametros = [%{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true}]

      nombre = servicio(sql, parametros, 2)

      assert {:error, mensaje} =
               ConsultasSql.ejecutar_servicio(nombre, %{"ids" => [1, 2, 3]}, :sistema)

      assert mensaje =~ "excede el tope de 2 renglones"

      assert ids_de(ConsultasSql.ejecutar_servicio(nombre, %{"ids" => [1, 2]}, :sistema)) == [
               1,
               2
             ]
    end

    # El sandbox abre su transacción por fuera de Ecto, así que ahí
    # `Repo.in_transaction?()` da false y la ejecución tomaría el camino
    # sin transacción. Una regla real siempre corre dentro de
    # `Repo.transaction`: esto la emula para probar el camino del savepoint.
    defp como_regla(fun) do
      {:ok, resultado} =
        Repo.transaction(fn ->
          assert Repo.in_transaction?()
          fun.()
        end)

      resultado
    end

    test "M4 (D5, R47): dentro de una transacción ve lo no confirmado y la deja sana" do
      Repo.query!("CREATE TABLE m4_tabla (id bigint)", [])

      nombre =
        servicio("SELECT id FROM m4_tabla WHERE id = :x", [
          %{"nombre" => "x", "tipo" => "entero", "obligatorio" => true}
        ])

      como_regla(fn ->
        [[timeout_antes]] = Repo.query!("SHOW statement_timeout", []).rows
        Repo.query!("INSERT INTO m4_tabla VALUES (42)", [])

        assert {:ok, %{filas: [%{"id" => 42}]}} =
                 ConsultasSql.ejecutar_servicio(nombre, %{"x" => 42}, :sistema)

        assert Repo.query!("SHOW statement_timeout", []).rows == [[timeout_antes]]
        assert Repo.query!("SHOW transaction_read_only", []).rows == [["off"]]
        Repo.query!("INSERT INTO m4_tabla VALUES (43)", [])
        assert Repo.query!("SELECT count(*) FROM m4_tabla", []).rows == [[2]]
      end)
    end

    test "M4 (K4): un Servicio que llama a una función que escribe se rechaza y la transacción sigue sana" do
      Repo.query!("CREATE TABLE m4_escrita (id bigint)", [])

      Repo.query!(
        "CREATE FUNCTION m4_escribe(p bigint) RETURNS bigint LANGUAGE plpgsql VOLATILE AS $$ BEGIN INSERT INTO m4_escrita VALUES (p); RETURN p; END $$",
        []
      )

      nombre =
        servicio("SELECT m4_escribe(:x) AS escrito", [
          %{"nombre" => "x", "tipo" => "entero", "obligatorio" => true}
        ])

      como_regla(fn ->
        assert {:error, mensaje} = ConsultasSql.ejecutar_servicio(nombre, %{"x" => 1}, :sistema)
        assert mensaje =~ "read-only"
        assert Repo.query!("SELECT count(*) FROM m4_escrita", []).rows == [[0]]
        assert Repo.query!("SHOW transaction_read_only", []).rows == [["off"]]
        Repo.query!("INSERT INTO m4_escrita VALUES (9)", [])
      end)

      # Fuera de una transacción (camino READ ONLY) también se rechaza.
      assert {:error, mensaje} = ConsultasSql.ejecutar_servicio(nombre, %{"x" => 1}, :sistema)
      assert mensaje =~ "read-only"
      assert Repo.query!("SELECT count(*) FROM m4_escrita", []).rows == [[1]]
    end

    test "M4 (R13.1): lo mismo aplica a una vista (Diccionario/Consulta) dentro de una transacción" do
      Repo.query!("CREATE TABLE m4_escrita_v (id bigint)", [])

      Repo.query!(
        "CREATE FUNCTION m4_escribe_v() RETURNS bigint LANGUAGE plpgsql VOLATILE AS $$ BEGIN INSERT INTO m4_escrita_v VALUES (1); RETURN 1; END $$",
        []
      )

      {:ok, {header, _}} =
        ConsultasSql.crear(%{"etiqueta" => "V", "nav" => "/m4v_#{unique()}", "uso" => "consulta"})

      {:ok, _} =
        ConsultasSql.guardar_sql(header.schema_context_name, "SELECT m4_escribe_v() AS escrito")

      como_regla(fn ->
        assert {:error, mensaje} = ConsultasSql.vista_previa(header.schema_context_name)
        assert mensaje =~ "read-only"
        assert Repo.query!("SELECT count(*) FROM m4_escrita_v", []).rows == [[0]]
        assert Repo.query!("SHOW transaction_read_only", []).rows == [["off"]]
        assert Repo.query!("SELECT 1", []).rows == [[1]]
      end)
    end

    test "M4: un error de ejecución no aborta la transacción de afuera" do
      nombre =
        servicio("SELECT 1 / :d AS r", [
          %{"nombre" => "d", "tipo" => "entero", "obligatorio" => true}
        ])

      como_regla(fn ->
        assert {:error, mensaje} = ConsultasSql.ejecutar_servicio(nombre, %{"d" => 0}, :sistema)
        assert mensaje =~ "division by zero"
        assert Repo.query!("SELECT 1", []).rows == [[1]]
      end)
    end

    @tag timeout: 30_000
    test "M6 (R42): excede el tiempo máximo" do
      nombre =
        servicio("SELECT 1 AS x FROM pg_sleep(:s)", [
          %{"nombre" => "s", "tipo" => "decimal", "obligatorio" => true}
        ])

      assert ConsultasSql.ejecutar_servicio(nombre, %{"s" => "6"}, :sistema) ==
               {:error, :tiempo_excedido}

      assert Repo.query!("SELECT 1", []).rows == [[1]]
    end

    test "errores claros: no existe, no es Servicio o no tiene SQL" do
      inexistente = "pty_sql_no_existe_#{unique()}"

      assert ConsultasSql.ejecutar_servicio(inexistente, %{}, :sistema) ==
               {:error, "No existe el servicio #{inexistente} en este ambiente."}

      {:ok, {consulta, _}} =
        ConsultasSql.crear(%{"etiqueta" => "C", "nav" => "/mc_#{unique()}", "uso" => "consulta"})

      assert {:error, m1} =
               ConsultasSql.ejecutar_servicio(consulta.schema_context_name, %{}, :sistema)

      assert m1 =~ "no es un Servicio"

      {:ok, {vacio, _}} =
        ConsultasSql.crear(%{"etiqueta" => "S", "nav" => "/ms_#{unique()}", "uso" => "servicio"})

      assert {:error, m2} =
               ConsultasSql.ejecutar_servicio(vacio.schema_context_name, %{}, :sistema)

      assert m2 =~ "todavía no tiene SQL"
    end
  end

  describe "MetaBcApi.ejecutar_servicio/2 (SPEC-SYS-2509202601 N1)" do
    setup do
      nombre =
        servicio("SELECT * FROM #{@datos} WHERE t.id = ANY(:ids)", [
          %{"nombre" => "ids", "tipo" => "lista_enteros", "obligatorio" => true}
        ])

      %{nombre: nombre}
    end

    test "corre como sistema: no acota aunque el Servicio exponga branch_id (R44)", %{
      nombre: nombre
    } do
      assert ids_de(MetadataApp.MetaBcApi.ejecutar_servicio(nombre, %{"ids" => [1, 2, 3]})) == [
               1,
               2,
               3
             ]
    end

    test "da lo mismo que ejecutar_servicio/3 con :sistema (R45)", %{nombre: nombre} do
      assert MetadataApp.MetaBcApi.ejecutar_servicio(nombre, %{ids: [2]}) ==
               ConsultasSql.ejecutar_servicio(nombre, %{"ids" => [2]}, :sistema)
    end

    test "error claro si el Servicio no existe en el ambiente (R48)" do
      assert MetadataApp.MetaBcApi.ejecutar_servicio("pty_sql_no_publicado", %{}) ==
               {:error, "No existe el servicio pty_sql_no_publicado en este ambiente."}
    end

    test "dentro de una transición ve lo no confirmado y un error no la aborta (R46, R47)" do
      Repo.query!("CREATE TABLE n1_tabla (id bigint)", [])

      nombre =
        servicio("SELECT id, 10 / id AS r FROM n1_tabla WHERE id = :x", [
          %{"nombre" => "x", "tipo" => "entero", "obligatorio" => true}
        ])

      como_regla(fn ->
        Repo.query!("INSERT INTO n1_tabla VALUES (5), (0)", [])

        assert {:ok, %{filas: [%{"id" => 5, "r" => 2}]}} =
                 MetadataApp.MetaBcApi.ejecutar_servicio(nombre, %{"x" => 5})

        assert {:error, mensaje} = MetadataApp.MetaBcApi.ejecutar_servicio(nombre, %{"x" => 0})
        assert mensaje =~ "division by zero"
        Repo.query!("INSERT INTO n1_tabla VALUES (6)", [])
        assert Repo.query!("SELECT count(*) FROM n1_tabla", []).rows == [[3]]
      end)
    end
  end

  describe "cambio de uso con Servicio (SPEC-SYS-2509202601 K5, R39)" do
    defp alta(uso) do
      {:ok, {header, _}} =
        ConsultasSql.crear(%{"etiqueta" => uso, "nav" => "/k5_#{uso}_#{unique()}", "uso" => uso})

      header.schema_context_name
    end

    test "un Servicio no cambia a Diccionario ni a Consulta" do
      nombre = alta("servicio")

      for uso <- ["diccionario", "consulta"] do
        assert ConsultasSql.cambiar_uso(nombre, uso) ==
                 {:error, "Un Servicio no puede cambiar de uso."}
      end

      assert ConsultasSql.obtener_por_catalogo(nombre).uso == "servicio"
    end

    test "un Diccionario o una Consulta no pasan a Servicio" do
      for uso <- ["diccionario", "consulta"] do
        nombre = alta(uso)

        assert ConsultasSql.cambiar_uso(nombre, "servicio") ==
                 {:error, "Una Consulta SQL no puede pasar a Servicio: crea un Servicio nuevo."}

        assert ConsultasSql.obtener_por_catalogo(nombre).uso == uso
      end
    end

    test "un Servicio no puede marcarse como visible" do
      nombre = alta("servicio")

      assert ConsultasSql.validar_cambio(nombre, "servicio", true) ==
               {:error, "Un Servicio no puede ser visible: no aparece en el menú."}

      assert ConsultasSql.validar_cambio(nombre, "servicio", false) == :ok
    end

    test "Diccionario y Consulta siguen cambiando entre sí como antes (R58)" do
      nombre = alta("diccionario")
      assert {:ok, %ConsultaSql{uso: "consulta"}} = ConsultasSql.cambiar_uso(nombre, "consulta")

      assert {:ok, %ConsultaSql{uso: "diccionario"}} =
               ConsultasSql.cambiar_uso(nombre, "diccionario")
    end
  end

  describe "tope de renglones de un Servicio (SPEC-SYS-2509202601 K1)" do
    setup do
      {:ok, {_header, consulta_sql}} =
        ConsultasSql.crear(%{
          "etiqueta" => "Servicio",
          "nav" => "/svc_tope_#{unique()}",
          "uso" => "servicio"
        })

      %{consulta_sql: consulta_sql}
    end

    test "acepta de 1 a 5000", %{consulta_sql: consulta_sql} do
      for tope <- [1, 5000] do
        assert {:ok, %ConsultaSql{tope_renglones: ^tope}} =
                 consulta_sql
                 |> ConsultaSql.changeset(%{"tope_renglones" => tope})
                 |> Repo.update()
      end
    end

    test "rechaza fuera de rango", %{consulta_sql: consulta_sql} do
      for tope <- [0, 5001] do
        changeset = ConsultaSql.changeset(consulta_sql, %{"tope_renglones" => tope})
        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :tope_renglones)
      end
    end

    test "el constraint de la base también lo rechaza", %{consulta_sql: consulta_sql} do
      assert_raise Postgrex.Error, ~r/tope_renglones_rango/, fn ->
        Repo.query!("UPDATE meta_schema_consulta_sql SET tope_renglones = 0 WHERE id = $1", [
          consulta_sql.id
        ])
      end
    end

    test "guarda los parámetros tal cual", %{consulta_sql: consulta_sql} do
      parametros = [
        %{"nombre" => "fecha", "tipo" => "fecha", "obligatorio" => false, "default" => nil}
      ]

      assert {:ok, %ConsultaSql{parametros: ^parametros}} =
               consulta_sql
               |> ConsultaSql.changeset(%{"parametros" => parametros})
               |> Repo.update()
    end
  end
end
