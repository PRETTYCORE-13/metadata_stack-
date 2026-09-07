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

  # SPEC-SYS-0309202601, auditoría de replay desde cero (2026-09-04):
  # un catálogo con un campo "referencia" hacia otro catálogo SIN
  # relación de maestro/detalle tumbaba el import entero si el orden
  # alfabético del directorio los procesaba al revés (encontrado real:
  # pty_dsd_cs_clientes -> pty_dsd_dsd_fac_rfc). importar_meta/1 ahora
  # ordena topológicamente por esa dependencia también, no solo por
  # maestro/detalle.
  test "un catálogo con campo referencia importa bien aunque el referenciado venga después alfabéticamente" do
    sufijo = unique()
    # "a_..." antes que "z_..." en orden alfabético, a propósito -- el
    # que REFERENCIA (a_) viene primero en el directorio, el
    # REFERENCIADO (z_) después -- el caso real que rompía.
    referenciador = "pty_a_referenciador_#{sufijo}"
    referenciado = "pty_z_referenciado_#{sufijo}"

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{sufijo}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_meta_json(dir, %{
      "schema_context_name" => referenciado,
      "schema_context_label" => "Referenciado",
      "schema_context_nav" => "/#{referenciado}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [
        %{
          "schema_context_field" => "descripcion",
          "schema_context_properties" => %{
            "tipo" => "string",
            "etiqueta" => "Descripción",
            "orden" => 0,
            "visible" => true,
            "editable" => true,
            "opcional" => false
          }
        }
      ]
    })

    escribir_meta_json(dir, %{
      "schema_context_name" => referenciador,
      "schema_context_label" => "Referenciador",
      "schema_context_nav" => "/#{referenciador}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [
        %{
          "schema_context_field" => "#{referenciador}_ref",
          "schema_context_properties" => %{
            "tipo" => "referencia",
            "etiqueta" => "Referencia",
            "orden" => 0,
            "visible" => true,
            "editable" => true,
            "opcional" => false,
            "catalogo" => referenciado,
            "campo_visualizacion" => %{"modo" => "descripcion", "campo_descripcion" => "descripcion"}
          }
        }
      ]
    })

    mensajes = MetaImportExport.importar_meta(dir)

    assert Enum.any?(mensajes, &(&1 =~ "#{referenciador}: creado"))
    assert Enum.any?(mensajes, &(&1 =~ "#{referenciado}: creado"))
    refute Enum.any?(mensajes, &String.starts_with?(&1, "!"))
  end

  test "un catálogo con dependencia circular real no tumba el import de los demás" do
    sufijo = unique()
    a = "pty_ciclo_a_#{sufijo}"
    b = "pty_ciclo_b_#{sufijo}"
    aparte = "pty_sin_relacion_#{sufijo}"

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{sufijo}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    campo_referencia = fn nombre_campo, catalogo_destino ->
      %{
        "schema_context_field" => nombre_campo,
        "schema_context_properties" => %{
          "tipo" => "referencia",
          "etiqueta" => "Ref",
          "orden" => 0,
          "visible" => true,
          "editable" => true,
          "opcional" => false,
          "catalogo" => catalogo_destino,
          "campo_visualizacion" => %{"modo" => "descripcion", "campo_descripcion" => "#{catalogo_destino}_x"}
        }
      }
    end

    escribir_meta_json(dir, %{
      "schema_context_name" => a,
      "schema_context_label" => "Ciclo A",
      "schema_context_nav" => "/#{a}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [campo_referencia.("#{a}_a_b", b)]
    })

    escribir_meta_json(dir, %{
      "schema_context_name" => b,
      "schema_context_label" => "Ciclo B",
      "schema_context_nav" => "/#{b}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [campo_referencia.("#{b}_a_a", a)]
    })

    escribir_meta_json(dir, %{
      "schema_context_name" => aparte,
      "schema_context_label" => "Sin relación",
      "schema_context_nav" => "/#{aparte}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => [
        %{
          "schema_context_field" => "descripcion",
          "schema_context_properties" => %{
            "tipo" => "string",
            "etiqueta" => "Descripción",
            "orden" => 0,
            "visible" => true,
            "editable" => true,
            "opcional" => false
          }
        }
      ]
    })

    mensajes = MetaImportExport.importar_meta(dir)

    # El catálogo sin relación con el ciclo se importa igual -- no queda
    # atrapado detrás de los dos que sí chocan entre sí.
    assert Enum.any?(mensajes, &(&1 =~ "#{aparte}: creado"))
    assert MetaSchemaContext.obtener_header_por_nombre(aparte) != nil
  end
end
