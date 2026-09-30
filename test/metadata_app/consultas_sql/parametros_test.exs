defmodule MetadataApp.ConsultasSql.ParametrosTest do
  @moduledoc "SPEC-SYS-2509202601 K2: validación de los parámetros declarados de un Servicio (R35)."
  use ExUnit.Case, async: true

  alias MetadataApp.ConsultasSql
  alias MetadataApp.ConsultasSql.Parametros

  defp p(nombre, tipo, extra \\ %{}), do: Map.merge(%{"nombre" => nombre, "tipo" => tipo}, extra)

  describe "validar/1: casos válidos" do
    test "lista vacía" do
      assert Parametros.validar([]) == {:ok, []}
    end

    test "normaliza obligatorio y default, y respeta el orden" do
      assert {:ok,
              [
                %{
                  "nombre" => "direccion_id",
                  "tipo" => "entero",
                  "obligatorio" => true,
                  "default" => nil
                },
                %{
                  "nombre" => "productos",
                  "tipo" => "lista_enteros",
                  "obligatorio" => true,
                  "default" => nil
                },
                %{
                  "nombre" => "fecha",
                  "tipo" => "fecha",
                  "obligatorio" => false,
                  "default" => nil
                }
              ]} =
               Parametros.validar([
                 p("direccion_id", "entero", %{"obligatorio" => true}),
                 p("productos", "lista_enteros", %{"obligatorio" => "true"}),
                 p("fecha", "fecha", %{"default" => ""})
               ])
    end

    test "acepta llaves átomo" do
      assert {:ok, [%{"nombre" => "x", "tipo" => "texto", "obligatorio" => false}]} =
               Parametros.validar([%{nombre: "x", tipo: "texto"}])
    end

    test "el default queda en su forma JSON canónica" do
      assert {:ok, parametros} =
               Parametros.validar([
                 p("a", "entero", %{"default" => " 42 "}),
                 p("b", "decimal", %{"default" => "12.50"}),
                 p("c", "fecha", %{"default" => "2026-10-01"}),
                 p("d", "booleano", %{"default" => "false"}),
                 p("e", "lista_enteros", %{"default" => "1, 2,3"}),
                 p("f", "texto", %{"default" => "hola"})
               ])

      assert Enum.map(parametros, & &1["default"]) == [
               42,
               "12.50",
               "2026-10-01",
               false,
               [1, 2, 3],
               "hola"
             ]
    end

    test "ConsultasSql.validar_parametros/1 delega en Parametros.validar/1" do
      assert ConsultasSql.validar_parametros([p("x", "entero")]) ==
               Parametros.validar([p("x", "entero")])
    end
  end

  describe "validar/1: rechazos" do
    test "nombre inválido" do
      for nombre <- [
            "",
            "1dir",
            "Dir",
            "dir-id",
            "dir id",
            "dirección",
            String.duplicate("a", 42)
          ] do
        assert {:error, mensaje} = Parametros.validar([p(nombre, "entero")])
        assert mensaje =~ "nombre inválido"
      end
    end

    test "nombre repetido" do
      assert {:error, mensaje} = Parametros.validar([p("x", "entero"), p("x", "texto")])
      assert mensaje =~ "«x» está repetido"
    end

    test "tipo inválido" do
      assert {:error, mensaje} = Parametros.validar([p("x", "fecha_hora")])
      assert mensaje =~ "tipo inválido «fecha_hora»"
    end

    test "obligatorio inválido" do
      assert {:error, mensaje} =
               Parametros.validar([p("x", "entero", %{"obligatorio" => "tal vez"})])

      assert mensaje =~ "obligatorio"
    end

    test "default incompatible con su tipo" do
      casos = [
        {"entero", "1.5"},
        {"entero", "uno"},
        {"decimal", "1,5"},
        {"fecha", "01/10/2026"},
        {"booleano", "si"},
        {"lista_enteros", "1,a,3"},
        {"texto", 5}
      ]

      for {tipo, default} <- casos do
        assert {:error, mensaje} = Parametros.validar([p("x", tipo, %{"default" => default})])
        assert mensaje =~ "default del parámetro «x»"
      end
    end

    test "un elemento que no es mapa" do
      assert {:error, mensaje} = Parametros.validar(["x"])
      assert mensaje =~ "parámetro 1"
    end

    test "algo que no es lista" do
      assert {:error, _} = Parametros.validar(%{"nombre" => "x"})
    end
  end

  describe "convertir/2" do
    test "acepta la forma nativa y la forma texto" do
      assert Parametros.convertir("entero", 7) == {:ok, 7}
      assert Parametros.convertir("entero", "7") == {:ok, 7}
      assert Parametros.convertir("decimal", 1.5) == {:ok, Decimal.from_float(1.5)}
      assert Parametros.convertir("fecha", ~D[2026-10-01]) == {:ok, ~D[2026-10-01]}
      assert Parametros.convertir("booleano", true) == {:ok, true}
      assert Parametros.convertir("lista_enteros", [1, "2"]) == {:ok, [1, 2]}
      assert Parametros.convertir("lista_enteros", "") == {:ok, []}
    end

    test "nil siempre es válido: la obligatoriedad se revisa aparte" do
      for tipo <- Parametros.tipos(), do: assert(Parametros.convertir(tipo, nil) == {:ok, nil})
    end
  end

  describe "traducir/2 (K3, D3)" do
    setup do
      {:ok, parametros} =
        Parametros.validar([
          %{"nombre" => "direccion_id", "tipo" => "entero", "obligatorio" => true},
          %{"nombre" => "productos", "tipo" => "lista_enteros", "obligatorio" => true},
          %{"nombre" => "fecha", "tipo" => "fecha"}
        ])

      %{parametros: parametros}
    end

    test "traduce a las dos versiones", %{parametros: parametros} do
      sql =
        "SELECT * FROM t WHERE t.dir = :direccion_id AND t.mat = ANY(:productos) AND t.f <= COALESCE(:fecha, now()::date)"

      assert {:ok, %{validacion: validacion, funcion: funcion, usados: usados}} =
               Parametros.traducir(sql, parametros)

      assert validacion ==
               "SELECT * FROM t WHERE t.dir = (NULL::bigint) AND t.mat = ANY((NULL::bigint[])) AND t.f <= COALESCE((NULL::date), now()::date)"

      assert funcion ==
               "SELECT * FROM t WHERE t.dir = p_direccion_id AND t.mat = ANY(p_productos) AND t.f <= COALESCE(p_fecha, now()::date)"

      assert usados == ["direccion_id", "productos", "fecha"]
    end

    test "un parámetro usado varias veces se traduce en cada lugar", %{parametros: parametros} do
      sql = "SELECT :direccion_id, :direccion_id WHERE :productos IS NOT NULL"
      assert {:ok, %{funcion: funcion, usados: usados}} = Parametros.traducir(sql, parametros)
      assert funcion == "SELECT p_direccion_id, p_direccion_id WHERE p_productos IS NOT NULL"
      assert usados == ["direccion_id", "productos"]
    end

    test "los casts :: no son parámetros, aunque el tipo coincida con un nombre" do
      {:ok, parametros} =
        Parametros.validar([%{"nombre" => "date", "tipo" => "fecha", "obligatorio" => true}])

      assert {:ok, %{funcion: "SELECT x::date, p_date"}} =
               Parametros.traducir("SELECT x::date, :date", parametros)
    end

    test "no traduce dentro de textos, identificadores, textos con $ ni comentarios", %{
      parametros: parametros
    } do
      sql = """
      SELECT ':fecha' AS a, 'it''s :fecha' AS b, "col:fecha" AS c, $$ :fecha $$ AS d, $x$ :fecha $x$ AS e
      -- :fecha en comentario
      /* :fecha /* anidado :fecha */ sigue :fecha */
      FROM t WHERE t.dir = :direccion_id AND t.mat = ANY(:productos)
      """

      assert {:ok, %{funcion: funcion, usados: usados}} = Parametros.traducir(sql, parametros)
      assert usados == ["direccion_id", "productos"]

      assert funcion =~
               "':fecha' AS a, 'it''s :fecha' AS b, \"col:fecha\" AS c, $$ :fecha $$ AS d, $x$ :fecha $x$ AS e"

      assert funcion =~ "-- :fecha en comentario\n"
      assert funcion =~ "/* :fecha /* anidado :fecha */ sigue :fecha */"
      assert funcion =~ "t.dir = p_direccion_id AND t.mat = ANY(p_productos)"
    end

    test "rechaza una referencia no declarada (R36)", %{parametros: parametros} do
      sql = "SELECT :direccion_id, :productos, :cliente, :sucursal"
      assert {:error, mensaje} = Parametros.traducir(sql, parametros)
      assert mensaje =~ "no están declarados: :cliente, :sucursal"
    end

    test "rechaza un obligatorio que el SQL no usa (R36)", %{parametros: parametros} do
      assert {:error, mensaje} = Parametros.traducir("SELECT :direccion_id", parametros)
      assert mensaje =~ "obligatorios que el SQL no usa: :productos"
    end

    test "un opcional sin usar sí se acepta", %{parametros: parametros} do
      assert {:ok, %{usados: ["direccion_id", "productos"]}} =
               Parametros.traducir("SELECT :direccion_id, :productos", parametros)
    end

    test "un texto sin cerrar no truena: se copia y Postgres lo rechaza al validar", %{
      parametros: parametros
    } do
      assert {:ok, %{funcion: funcion}} =
               Parametros.traducir(
                 "SELECT :direccion_id, :productos, 'abierto :fecha",
                 parametros
               )

      assert funcion == "SELECT p_direccion_id, p_productos, 'abierto :fecha"
    end

    test "respeta acentos y otros caracteres", %{parametros: parametros} do
      assert {:ok, %{funcion: "SELECT 'Sucursal Añil' AS n, p_direccion_id, p_productos -- año"}} =
               Parametros.traducir(
                 "SELECT 'Sucursal Añil' AS n, :direccion_id, :productos -- año",
                 parametros
               )
    end
  end

  test "tipo_pg/1 sigue la tabla del diseño §11.2" do
    assert Enum.map(~w(entero decimal texto fecha booleano lista_enteros), &Parametros.tipo_pg/1) ==
             ~w(bigint numeric text date boolean bigint[])
  end
end
