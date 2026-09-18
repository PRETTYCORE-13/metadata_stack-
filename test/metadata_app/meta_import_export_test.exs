defmodule MetadataApp.MetaImportExportTest do
  use MetadataApp.DataCase, async: false

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.{MetaImportExport, MetaPlantillas, MetaConsultas, ConsultaEndpoints, Repo}
  alias MetadataApp.Autenticacion.Empresa

  defp unique, do: System.unique_integer([:positive])

  defp escribir_meta_json(dir, contexto) do
    nombre = contexto["schema_context_name"]
    File.write!(Path.join(dir, "#{nombre}.meta.json"), Jason.encode!(contexto))
  end

  defp escribir_motor_json(dir, catalogo, contenido) do
    File.write!(Path.join(dir, "#{catalogo}.motor.json"), Jason.encode!(Map.put(contenido, "catalogo", catalogo)))
  end

  defp escribir_plantillas_json(dir, catalogo, plantillas) do
    contenido = %{"catalogo" => catalogo, "plantillas" => plantillas}
    File.write!(Path.join(dir, "#{catalogo}.plantillas.json"), Jason.encode!(contenido))
  end

  defp definicion_simple(texto) do
    %{"tipo" => "raiz", "propiedades" => %{"filas" => 1, "columnas" => 1, "gap" => "normal", "nota" => texto}, "hijos" => []}
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

  # Encontrado real (2026-09-17): captura mostrando el orden de Get Config
  # (grilla de columnas + orden de filas por default) sin efecto tras
  # publicar -- exportar_header/2 no incluía orden_columnas_tabla ni
  # orden_resultados en el .meta.json.
  test "republicar un catálogo ya existente sincroniza orden_columnas_tabla y orden_resultados" do
    nombre = "pty_test_orden_columnas_#{unique()}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    assert header.orden_columnas_tabla == []
    assert header.orden_resultados == []

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_meta_json(dir, %{
      "schema_context_name" => nombre,
      "schema_context_label" => "Test",
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "orden_columnas_tabla" => ["id", "estado", "nombre"],
      "orden_resultados" => [%{"campo" => "nombre", "direccion" => "asc"}],
      "detalles" => []
    })

    mensajes = MetaImportExport.importar_meta(dir)

    assert Enum.any?(mensajes, &(&1 =~ "orden de columnas (Get Config) actualizado"))
    assert Enum.any?(mensajes, &(&1 =~ "orden de resultados actualizado"))

    actualizado = MetaSchemaContext.obtener_header_por_nombre(nombre)
    assert actualizado.orden_columnas_tabla == ["id", "estado", "nombre"]
    assert actualizado.orden_resultados == [%{"campo" => "nombre", "direccion" => "asc"}]
  end

  # Encontrado real (2026-09-17): un campo YA publicado que se oculta o
  # reordena en dev (Get Config → checkbox visible / drag-and-drop) y se
  # vuelve a publicar no se sincronizaba -- solo sincronizar_detalles_nuevos/2
  # cubría un campo recién creado, nunca uno existente.
  test "republicar un catálogo ya existente sincroniza visible/orden de un campo YA existente" do
    nombre = "pty_test_visible_orden_#{unique()}"

    {:ok, {_header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => [
          %{
            "schema_context_field" => "campo1",
            "schema_context_properties" => %{
              "tipo" => "string",
              "etiqueta" => "Campo 1",
              "orden" => 0,
              "visible" => true,
              "editable" => true,
              "opcional" => false
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
          "schema_context_field" => "campo1",
          "schema_context_properties" => %{
            "tipo" => "string",
            "etiqueta" => "Campo 1",
            "orden" => 5,
            "visible" => false,
            "editable" => true,
            "opcional" => false
          }
        }
      ]
    })

    mensajes = MetaImportExport.importar_meta(dir)

    assert Enum.any?(mensajes, &(&1 =~ "visible/orden actualizado"))

    [detalle] = MetaSchemaContext.listar_detalles(nombre)
    assert detalle.schema_context_properties["visible"] == false
    assert detalle.schema_context_properties["orden"] == 5
  end

  # Encontrado real (2026-09-17): captura de un catálogo publicado mostrando
  # el orden alfabético de siempre en vez del orden manual (drag-and-drop)
  # configurado en dev -- exportar_header/2 no incluía "orden" en el
  # .meta.json, y aunque lo incluyera, importar_contexto/1 no lo
  # sincronizaba para un catálogo YA existente (mismo patrón que
  # sincronizar_icono/2, ver #sincronizar_orden/2 arriba).
  test "republicar un catálogo ya existente sincroniza el orden manual del menú" do
    nombre = "pty_test_orden_#{unique()}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Test Orden",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "orden" => 0,
        "detalles" => []
      })

    assert header.orden == 0

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_meta_json(dir, %{
      "schema_context_name" => nombre,
      "schema_context_label" => "Test Orden",
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "orden" => 4,
      "detalles" => []
    })

    mensajes = MetaImportExport.importar_meta(dir)

    assert Enum.any?(mensajes, &(&1 =~ "orden de menú actualizado"))
    assert MetaSchemaContext.obtener_header_por_nombre(nombre).orden == 4
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

  # Encontrado real (2026-09-17): deploy a "unstable" con TODOS los pty_ch_*
  # bien configurados en dev, pero sin botón "Nuevo registro" tras publicar
  # -- importar_catalogo_motor/1 no tenía el mismo rescue por catálogo que
  # importar_contexto_tolerante/1, así que UN catálogo con un motor.json roto
  # (nombre "a_..." a propósito, ordena antes que los demás) cortaba
  # Enum.flat_map/2 y dejaba sin estados/transiciones a TODOS los que
  # venían después en la lista, no solo al roto.
  test "un catálogo con motor.json roto no tumba el import de los demás" do
    sufijo = unique()
    roto = "pty_a_motor_roto_#{sufijo}"
    sano = "pty_z_motor_sano_#{sufijo}"

    {:ok, {_header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => roto,
        "schema_context_label" => "Roto",
        "schema_context_nav" => "/#{roto}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    {:ok, {header_sano, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => sano,
        "schema_context_label" => "Sano",
        "schema_context_nav" => "/#{sano}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => [
          %{
            "schema_context_field" => "campo1",
            "schema_context_properties" => %{
              "tipo" => "string",
              "etiqueta" => "Campo 1",
              "orden" => 0,
              "visible" => true,
              "editable" => true,
              "opcional" => false
            }
          }
        ]
      })

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{sufijo}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_motor_json(dir, roto, %{
      "estados" => [%{"nombre" => "activo", "orden" => 0, "es_inicial" => true}],
      "transiciones" => [
        %{
          "accion" => "alta",
          "etiqueta" => "Alta",
          "estado_origen" => nil,
          "estado_destino" => "estado_que_no_existe",
          "campos_editables" => []
        }
      ]
    })

    escribir_motor_json(dir, sano, %{
      "estados" => [%{"nombre" => "activo", "orden" => 0, "es_inicial" => true}],
      "transiciones" => [
        %{
          "accion" => "alta",
          "etiqueta" => "Alta",
          "estado_origen" => nil,
          "estado_destino" => "activo",
          "campos_editables" => ["campo1"]
        }
      ]
    })

    mensajes = MetaImportExport.importar_motor(dir)

    assert Enum.any?(mensajes, &(String.starts_with?(&1, "!") and &1 =~ roto))

    transicion_sana = MetadataApp.MetaStateEngine.transicion_alta(sano)
    assert transicion_sana != nil
    assert transicion_sana.campos_editables == ["campo1"]
    assert MetadataApp.MetaStateEngine.campos_editables(sano, transicion_sana) == ["campo1"]

    assert MetadataApp.MetaEstadosAdmin.listar_estados(header_sano.id) != []
  end

  # Encontrado real (2026-09-17): las plantillas custom del Constructor
  # (Post Config) nunca viajaban al publicar un catálogo -- solo la
  # plantilla AUTOMÁTICA se autogeneraba en cada ambiente por separado, así
  # que un diseño a medida en dev jamás llegaba a unstable/producción.
  # Mismo criterio de tolerancia por catálogo que importar_motor/1.
  test "un catálogo con plantillas.json roto no tumba el import de los demás" do
    sufijo = unique()
    roto = "pty_a_plantilla_rota_#{sufijo}"
    sano = "pty_z_plantilla_sana_#{sufijo}"

    {:ok, {_header_roto, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => roto,
        "schema_context_label" => "Roto",
        "schema_context_nav" => "/#{roto}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    {:ok, {header_sano, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => sano,
        "schema_context_label" => "Sano",
        "schema_context_nav" => "/#{sano}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{sufijo}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_plantillas_json(dir, roto, [
      %{
        "nombre" => "Plantilla automática",
        "descripcion" => nil,
        "estado" => "publicada",
        "definicion" => nil,
        "disponible_multi_vista" => false,
        "proposito" => "vista"
      }
    ])

    escribir_plantillas_json(dir, sano, [
      %{
        "nombre" => "Plantilla automática",
        "descripcion" => "desc",
        "estado" => "publicada",
        "definicion" => definicion_simple("sano"),
        "disponible_multi_vista" => false,
        "proposito" => "vista"
      }
    ])

    mensajes = MetaImportExport.importar_plantillas(dir)

    assert Enum.any?(mensajes, &(String.starts_with?(&1, "!") and &1 =~ roto))

    [plantilla] = MetaPlantillas.listar_plantillas(header_sano.id)
    assert plantilla.definicion == definicion_simple("sano")
    assert plantilla.estado == "publicada"
  end

  test "republicar sincroniza el contenido de una plantilla existente y respeta la unicidad de publicada" do
    nombre = "pty_test_plantilla_sync_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    {:ok, vieja} = MetaPlantillas.crear_plantilla(header.id, %{"nombre" => "Manual", "estado" => "borrador", "definicion" => definicion_simple("vieja")})
    {:ok, _vieja} = MetaPlantillas.publicar_plantilla(vieja)

    dir = Path.join(System.tmp_dir!(), "meta_import_export_test_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escribir_plantillas_json(dir, nombre, [
      %{
        "nombre" => "Manual",
        "descripcion" => "actualizada",
        "estado" => "borrador",
        "definicion" => definicion_simple("nueva"),
        "disponible_multi_vista" => true,
        "proposito" => "vista"
      },
      %{
        "nombre" => "Nueva del bundle",
        "descripcion" => nil,
        "estado" => "publicada",
        "definicion" => definicion_simple("bundle"),
        "disponible_multi_vista" => false,
        "proposito" => "vista"
      }
    ])

    mensajes = MetaImportExport.importar_plantillas(dir)

    assert Enum.any?(mensajes, &(&1 =~ "\"Manual\": actualizada"))
    assert Enum.any?(mensajes, &(&1 =~ "\"Nueva del bundle\" (vista): creada"))

    plantillas = MetaPlantillas.listar_plantillas(header.id) |> Map.new(&{&1.nombre, &1})

    assert plantillas["Manual"].definicion == definicion_simple("nueva")
    assert plantillas["Manual"].disponible_multi_vista == true
    # "Manual" venía publicada de antes; el bundle no pide publicarla (trae
    # "borrador"), así que su propio sync no la toca -- pero "Nueva del
    # bundle" SÍ pide "publicada", y publicar_plantilla/1 demota a
    # cualquier otra del mismo (header, propósito) en la misma transacción
    # -- por eso termina en "borrador", sin haberlo pedido su propia entrada.
    assert plantillas["Manual"].estado == "borrador"
    assert plantillas["Nueva del bundle"].estado == "publicada"
    assert Enum.count(Map.values(plantillas), &(&1.estado == "publicada")) == 1
  end

  describe "importar_endpoint/1 (SPEC-SYS-1009202602, design.md §13, R67-R71)" do
    defp empresa!(nombre) do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: nombre}) |> Repo.insert()
      empresa
    end

    defp consulta_vacia!(nombre) do
      {:ok, {header, _detalles}} =
        MetaSchemaContext.crear_header_con_detalles(%{
          "schema_context_name" => nombre,
          "schema_context_label" => nombre,
          "schema_context_nav" => "/#{nombre}",
          "schema_visible" => true,
          "schema_context_type" => 3,
          "detalles" => []
        })

      {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
      consulta
    end

    defp escribir_endpoint_json(dir, atributos) do
      File.write!(Path.join(dir, "#{atributos["catalogo"]}.endpoint.json"), Jason.encode!(atributos))
    end

    test "crea el endpoint cuando la Consulta y la Empresa ya existen en destino" do
      nombre = "meta_import_export_endpoint_#{unique()}"
      empresa = empresa!("Empresa import endpoint #{unique()}")
      consulta = consulta_vacia!(nombre)

      dir = Path.join(System.tmp_dir!(), "meta_import_export_endpoint_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      escribir_endpoint_json(dir, %{
        "catalogo" => nombre,
        "nombre" => "Reporte de prueba",
        "metodo" => "get",
        "ruta" => "reporte-#{unique()}",
        "estado" => "publicado",
        "empresa_nombre" => empresa.nombre,
        "catalogo_base" => "meta_fixture_cliente"
      })

      mensajes = MetaImportExport.importar_endpoint(dir)
      assert Enum.any?(mensajes, &(&1 =~ "creado"))

      endpoint = ConsultaEndpoints.obtener_por_consulta(consulta.id)
      assert endpoint.nombre == "Reporte de prueba"
      assert endpoint.estado == "publicado"
      assert endpoint.empresa_id == empresa.id
    end

    test "una segunda importación actualiza en vez de duplicar" do
      nombre = "meta_import_export_endpoint_#{unique()}"
      empresa = empresa!("Empresa import endpoint #{unique()}")
      consulta = consulta_vacia!(nombre)

      dir = Path.join(System.tmp_dir!(), "meta_import_export_endpoint_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      atributos = %{
        "catalogo" => nombre,
        "nombre" => "Reporte v1",
        "metodo" => "get",
        "ruta" => "reporte-#{unique()}",
        "estado" => "borrador",
        "empresa_nombre" => empresa.nombre,
        "catalogo_base" => "meta_fixture_cliente"
      }

      escribir_endpoint_json(dir, atributos)
      MetaImportExport.importar_endpoint(dir)
      primero = ConsultaEndpoints.obtener_por_consulta(consulta.id)

      escribir_endpoint_json(dir, Map.put(atributos, "nombre", "Reporte v2"))
      mensajes = MetaImportExport.importar_endpoint(dir)
      assert Enum.any?(mensajes, &(&1 =~ "actualizado"))

      segundo = ConsultaEndpoints.obtener_por_consulta(consulta.id)
      assert segundo.id == primero.id
      assert segundo.nombre == "Reporte v2"
    end

    test "sin una Empresa con ese nombre en destino, mensaje de error y no crea nada" do
      nombre = "meta_import_export_endpoint_#{unique()}"
      consulta = consulta_vacia!(nombre)

      dir = Path.join(System.tmp_dir!(), "meta_import_export_endpoint_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      escribir_endpoint_json(dir, %{
        "catalogo" => nombre,
        "nombre" => "Reporte",
        "metodo" => "get",
        "ruta" => "reporte-#{unique()}",
        "estado" => "borrador",
        "empresa_nombre" => "Empresa que no existe #{unique()}",
        "catalogo_base" => "meta_fixture_cliente"
      })

      mensajes = MetaImportExport.importar_endpoint(dir)
      assert Enum.any?(mensajes, &(&1 =~ "no existe ninguna Empresa"))
      assert ConsultaEndpoints.obtener_por_consulta(consulta.id) == nil
    end

    test "el tombstone {\"eliminado\": true} borra el endpoint existente en destino" do
      nombre = "meta_import_export_endpoint_#{unique()}"
      empresa = empresa!("Empresa import endpoint #{unique()}")
      consulta = consulta_vacia!(nombre)

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, %{
          "nombre" => "Reporte",
          "metodo" => "get",
          "ruta" => "reporte-#{unique()}",
          "empresa_id" => empresa.id
        })

      dir = Path.join(System.tmp_dir!(), "meta_import_export_endpoint_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      escribir_endpoint_json(dir, %{"catalogo" => nombre, "eliminado" => true})

      mensajes = MetaImportExport.importar_endpoint(dir)
      assert Enum.any?(mensajes, &(&1 =~ "eliminado"))
      assert ConsultaEndpoints.obtener_por_consulta(consulta.id) == nil
      refute Repo.get(MetadataApp.MetaSchema.ConsultaEndpoint, endpoint.id)
    end

    test "el tombstone es idempotente cuando ya no existía ningún endpoint" do
      nombre = "meta_import_export_endpoint_#{unique()}"
      consulta_vacia!(nombre)

      dir = Path.join(System.tmp_dir!(), "meta_import_export_endpoint_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      escribir_endpoint_json(dir, %{"catalogo" => nombre, "eliminado" => true})

      mensajes = MetaImportExport.importar_endpoint(dir)
      assert Enum.any?(mensajes, &(&1 =~ "ya no existía"))
    end
  end
end
