defmodule MetadataApp.BusinessProcessBuilder.CatalogosPorModuloTest do
  # SPEC-SYS-1109202601 §2.3 (R35-R40): filtrar "Catálogo destino" por módulo.
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @modulos [
    %{prefijo: "CH", etiqueta: "Capital Humano", nav: "/ch"},
    %{prefijo: "NOM", etiqueta: "Nómina", nav: "/ch/nomina"},
    %{prefijo: "VTA", etiqueta: "Ventas", nav: "/ventas"}
  ]

  @catalogos [
    %{nombre: "pty_empleados", etiqueta: "Empleados", nav: "/ch/empleados"},
    %{nombre: "pty_recibos", etiqueta: "Recibos", nav: "/ch/nomina/recibos"},
    %{nombre: "pty_chx", etiqueta: "Otro que empieza con ch", nav: "/chx/algo"},
    %{nombre: "pty_pedidos", etiqueta: "Pedidos", nav: "/ventas/pedidos"},
    %{nombre: "pty_suelto", etiqueta: "Suelto", nav: "/suelto"},
    %{nombre: "meta_schema_empresa", etiqueta: "Empresa (sistema)", nav: nil}
  ]

  defp nombres(lista), do: Enum.map(lista, & &1.nombre)

  describe "catalogos_del_modulo/3" do
    test "\"Todos\" devuelve la lista completa (R39)" do
      assert MetaSchemaContext.catalogos_del_modulo(@catalogos, "", @modulos) == @catalogos
    end

    test "incluye subdirectorios y siempre los de sistema (R36)" do
      assert nombres(MetaSchemaContext.catalogos_del_modulo(@catalogos, "CH", @modulos)) ==
               ["pty_empleados", "pty_recibos", "meta_schema_empresa"]
    end

    test "compara por segmento completo: /ch no incluye /chx" do
      refute "pty_chx" in nombres(MetaSchemaContext.catalogos_del_modulo(@catalogos, "CH", @modulos))
    end

    test "un subdirectorio con prefijo propio filtra solo lo suyo" do
      assert nombres(MetaSchemaContext.catalogos_del_modulo(@catalogos, "NOM", @modulos)) ==
               ["pty_recibos", "meta_schema_empresa"]
    end

    test "un prefijo que no es módulo cae a la lista completa" do
      assert MetaSchemaContext.catalogos_del_modulo(@catalogos, "NOEX", @modulos) == @catalogos
    end
  end

  describe "modulo_de_nav/2 (R37)" do
    test "elige el directorio con prefijo más cercano" do
      assert MetaSchemaContext.modulo_de_nav(@modulos, "/ch/nomina/recibos") == "NOM"
      assert MetaSchemaContext.modulo_de_nav(@modulos, "/ch/empleados") == "CH"
    end

    test "sin directorio con prefijo, o sin ruta, es \"\" (Todos)" do
      assert MetaSchemaContext.modulo_de_nav(@modulos, "/suelto") == ""
      assert MetaSchemaContext.modulo_de_nav(@modulos, "/chx/algo") == ""
      assert MetaSchemaContext.modulo_de_nav(@modulos, nil) == ""
    end
  end

  describe "listar_modulos/0 y listar_catalogos_referenciables/0" do
    test "solo directorios vivos con prefijo, ordenados por prefijo; catálogos con nav" do
      sufijo = System.unique_integer([:positive])

      crear = fn nombre, tipo, nav, prefijo ->
        {:ok, {header, _}} =
          MetaSchemaContext.crear_header_con_detalles(%{
            "schema_context_name" => nombre,
            "schema_context_label" => "Etiqueta #{nombre}",
            "schema_context_nav" => nav,
            "schema_visible" => true,
            "schema_context_type" => tipo,
            "prefijo_directorio" => prefijo,
            "detalles" => []
          })

        header
      end

      crear.("pty_carpeta_mzz#{sufijo}", 2, "/mzz#{sufijo}", "MZZ")
      crear.("pty_carpeta_maa#{sufijo}", 2, "/maa#{sufijo}", "MAA")
      crear.("pty_carpeta_msin#{sufijo}", 2, "/msin#{sufijo}", nil)
      crear.("pty_cat_m#{sufijo}", 1, "/maa#{sufijo}/cat", nil)

      prefijos = MetaSchemaContext.listar_modulos() |> Enum.map(& &1.prefijo)
      assert Enum.filter(prefijos, &(&1 in ["MAA", "MZZ"])) == ["MAA", "MZZ"]
      refute Enum.any?(MetaSchemaContext.listar_modulos(), &(&1.nav == "/msin#{sufijo}"))

      catalogos = MetaSchemaContext.listar_catalogos_referenciables()
      assert Enum.find(catalogos, &(&1.nombre == "pty_cat_m#{sufijo}")).nav == "/maa#{sufijo}/cat"
      assert Enum.find(catalogos, &(&1.nombre == "meta_schema_empresa")).nav == nil
    end
  end
end
