defmodule MetadataApp.MetaImportExportTest do
  use MetadataApp.DataCase, async: false

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaImportExport

  defp unique, do: System.unique_integer([:positive])

  defp escribir_meta_json(dir, contexto) do
    nombre = contexto["schema_context_name"]
    File.write!(Path.join(dir, "#{nombre}.meta.json"), Jason.encode!(contexto))
  end

  test "republicar un catálogo ya existente sincroniza es_parametro/defaults/totales de un campo YA existente" do
    nombre = "pty_test_import_#{unique()}"

    {:ok, {_header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => [
          %{
            "schema_context_field" => "fecha",
            "schema_context_properties" => %{
              "tipo" => "date",
              "etiqueta" => "Fecha",
              "orden" => 0,
              "visible" => true,
              "editable" => true,
              "opcional" => false,
              "es_parametro" => false,
              "acotado" => false,
              "agregacion_activa" => false,
              "total_general_activo" => false,
              "total_pagina_activo" => false
            }
          }
        ]
      })

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_meta_json(dir, %{
      "schema_context_name" => nombre,
      "schema_context_label" => "Test",
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [
        %{
          "schema_context_field" => "fecha",
          "schema_context_properties" => %{
            "tipo" => "date",
            "etiqueta" => "Fecha",
            "orden" => 0,
            "visible" => true,
            "editable" => true,
            "opcional" => false,
            "es_parametro" => true,
            "defaults" => %{"modo" => "mes_actual"},
            "acotado" => true,
            "agregacion_activa" => false,
            "total_general_activo" => false,
            "total_pagina_activo" => false
          }
        }
      ]
    })

    MetaImportExport.importar_meta(dir)

    [detalle] = MetaSchemaContext.listar_detalles(nombre)

    assert detalle.schema_context_properties["es_parametro"] == true
    assert detalle.schema_context_properties["defaults"] == %{"modo" => "mes_actual"}
    assert detalle.schema_context_properties["acotado"] == true
  end
end
