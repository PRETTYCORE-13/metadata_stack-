defmodule MetadataApp.MetaClonadorTest do
  use MetadataApp.DataCase, async: false

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.{MetaClonador, MetaEstadosAdmin}

  defp unique, do: System.unique_integer([:positive])

  defp crear_original(nombre, opts) do
    detalles = Keyword.get(opts, :detalles, [])
    estados = Keyword.get(opts, :estados, [])
    transiciones = Keyword.get(opts, :transiciones, [])

    attrs = %{
      "header" => %{
        "schema_context_name" => nombre,
        "schema_context_label" => "Original",
        "schema_context_nav" => "/#{nombre}",
        "schema_context_type" => 1,
        "schema_visible" => true,
        "detalles" => detalles
      },
      "estados" => estados,
      "transiciones" => transiciones
    }

    {:ok, %{header: header}} = MetaEstadosAdmin.insertar_proceso(attrs)
    header
  end

  defp campo(nombre_original, sufijo, props) do
    %{"schema_context_field" => "#{nombre_original}_#{sufijo}", "schema_context_properties" => props}
  end

  defp props_string(etiqueta, orden) do
    %{"tipo" => "string", "etiqueta" => etiqueta, "orden" => orden, "visible" => true, "editable" => true, "opcional" => false}
  end

  test "clona un catálogo simple sin autómata: campos renombrados, sin estados/transiciones" do
    original = "pty_clon_simple_#{unique()}"
    sufijo = unique()
    nuevo = "clon_simple_#{sufijo}"

    crear_original(original,
      detalles: [
        campo(original, "descripcion", props_string("Descripción", 1)),
        %{"schema_context_field" => "fecha_registro", "schema_context_properties" => %{"tipo" => "date", "etiqueta" => "Fecha de registro", "orden" => 9999, "visible" => true, "editable" => false}}
      ]
    )

    {:ok, attrs_base} =
      MetaClonador.construir_plan(original, %{
        "schema_context_name" => nuevo,
        "schema_context_label" => "Clon Simple",
        "carpeta_padre" => "",
        "schema_context_icono" => nil
      })

    nombre_nuevo_completo = "pty_#{nuevo}"

    assert attrs_base["header"]["schema_context_name"] == nombre_nuevo_completo
    assert attrs_base["estados"] == []
    assert attrs_base["transiciones"] == []

    [detalle] = attrs_base["header"]["detalles"]
    assert detalle["schema_context_field"] == "#{nombre_nuevo_completo}_descripcion"
    assert detalle["schema_context_properties"]["etiqueta"] == "Descripción"
    refute Enum.any?(attrs_base["header"]["detalles"], &(&1["schema_context_field"] == "fecha_registro"))
  end

  test "clona autómata: estados tal cual, campos_editables renombrados y huérfanos descartados" do
    original = "pty_clon_automata_#{unique()}"
    sufijo = unique()
    nuevo = "clon_automata_#{sufijo}"

    _header_original =
      crear_original(original,
        detalles: [campo(original, "nombre", props_string("Nombre", 1)), campo(original, "operacion", props_string("Operación", 2))],
        estados: [
          %{"nombre" => "Activo", "orden" => 1, "es_inicial" => true, "color" => "#40edb3"},
          %{"nombre" => "Baja", "orden" => 2, "es_inicial" => false, "color" => "#ed4051"}
        ],
        transiciones: [
          %{
            "accion" => "alta",
            "etiqueta" => "Alta",
            "estado_origen" => nil,
            "estado_destino" => "Activo",
            "campos_editables" => ["#{original}_nombre", "#{original}_operacion"]
          },
          %{"accion" => "baja", "etiqueta" => "Baja", "estado_origen" => "Activo", "estado_destino" => "Baja", "campos_editables" => []}
        ]
      )

    # Mismo caso real encontrado en pty_dsd_cs_vigencias_frec: el campo
    # "operacion" se borró de meta_schema_detail (soft-delete) DESPUÉS de
    # quedar referenciado en campos_editables -- la transición nunca se
    # actualizó, queda huérfana.
    [detalle_operacion] = Enum.filter(MetaSchemaContext.listar_detalles(original), &(&1.schema_context_field == "#{original}_operacion"))
    {:ok, _} = MetaSchemaContext.eliminar_detalle(detalle_operacion)

    {:ok, attrs_base} =
      MetaClonador.construir_plan(original, %{
        "schema_context_name" => nuevo,
        "schema_context_label" => "Clon Autómata",
        "carpeta_padre" => "",
        "schema_context_icono" => nil
      })

    nombre_nuevo_completo = "pty_#{nuevo}"

    assert Enum.map(attrs_base["estados"], & &1["nombre"]) == ["Activo", "Baja"]

    alta = Enum.find(attrs_base["transiciones"], &(&1["accion"] == "alta"))
    assert alta["campos_editables"] == ["#{nombre_nuevo_completo}_nombre"]
    refute Enum.any?(alta["campos_editables"], &(&1 =~ "operacion"))
  end

  test "un campo referencia a OTRO catálogo no toca esa referencia, solo la autoreferencia" do
    original = "pty_clon_ref_#{unique()}"
    sufijo = unique()
    nuevo = "clon_ref_#{sufijo}"
    destino = "pty_catalogo_destino_#{unique()}"

    crear_original(destino, detalles: [campo(destino, "nombre", props_string("Nombre", 1))])

    crear_original(original,
      detalles: [
        %{
          "schema_context_field" => "#{original}_referencia",
          "schema_context_properties" => %{
            "tipo" => "referencia",
            "etiqueta" => "Referencia",
            "orden" => 1,
            "visible" => true,
            "editable" => true,
            "opcional" => false,
            "catalogo" => destino,
            "campo_visualizacion" => %{"modo" => "descripcion", "campo_descripcion" => "#{destino}_nombre"},
            "campos_acompanamiento" => ["#{destino}_nombre"],
            "campos_relacion" => ["#{original}_referencia"]
          }
        }
      ]
    )

    {:ok, attrs_base} =
      MetaClonador.construir_plan(original, %{
        "schema_context_name" => nuevo,
        "schema_context_label" => "Clon Ref",
        "carpeta_padre" => "",
        "schema_context_icono" => nil
      })

    nombre_nuevo_completo = "pty_#{nuevo}"
    [detalle] = attrs_base["header"]["detalles"]
    props = detalle["schema_context_properties"]

    assert detalle["schema_context_field"] == "#{nombre_nuevo_completo}_referencia"
    assert props["campos_relacion"] == ["#{nombre_nuevo_completo}_referencia"]
    assert props["catalogo"] == destino
    assert props["campos_acompanamiento"] == ["#{destino}_nombre"]
    assert props["campo_visualizacion"]["campo_descripcion"] == "#{destino}_nombre"
  end

  test "rechaza nombre destino inválido, ya existente, o con nav ya usada" do
    original = "pty_clon_validacion_#{unique()}"
    crear_original(original, detalles: [campo(original, "nombre", props_string("Nombre", 1))])

    atributos = fn nombre -> %{"schema_context_name" => nombre, "schema_context_label" => "X", "carpeta_padre" => "", "schema_context_icono" => nil} end

    # Nombre vacío (o que normaliza a vacío, ej. solo símbolos) -- no
    # cumple el regex de identificador.
    assert {:error, _} = MetaClonador.construir_plan(original, atributos.(""))
    assert {:error, _} = MetaClonador.construir_plan(original, atributos.("!!!"))

    # Ya existente: clonar contra sí mismo choca de nombre Y de nav.
    sufijo_propio = String.trim_leading(original, "pty_")
    assert {:error, _} = MetaClonador.construir_plan(original, atributos.(sufijo_propio))
  end

  test "rechaza origen no elegible: Consulta, detalle, o maestro con detalles propios" do
    consulta = "consulta_no_elegible_#{unique()}"

    {:ok, {_header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => consulta,
        "schema_context_label" => "Consulta",
        "schema_context_nav" => "/#{consulta}",
        "schema_context_type" => 3,
        "schema_visible" => true,
        "detalles" => []
      })

    atributos = %{"schema_context_name" => "clon_#{unique()}", "schema_context_label" => "X", "carpeta_padre" => "", "schema_context_icono" => nil}

    assert {:error, _} = MetaClonador.construir_plan(consulta, atributos)

    maestro = "pty_clon_maestro_con_det_#{unique()}"
    header_maestro = crear_original(maestro, detalles: [campo(maestro, "nombre", props_string("Nombre", 1))])

    detalle_nombre = "#{maestro}_det_renglon"

    {:ok, {_header_detalle, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => detalle_nombre,
        "schema_context_label" => "Detalle",
        "schema_context_nav" => "/#{detalle_nombre}",
        "schema_context_type" => 1,
        "schema_visible" => true,
        "schema_encabezado_id" => header_maestro.id,
        "detalles" => [campo(detalle_nombre, "campo1", props_string("Campo 1", 1))]
      })

    assert {:error, _} = MetaClonador.construir_plan(maestro, atributos)
    assert {:error, _} = MetaClonador.construir_plan(detalle_nombre, atributos)
  end
end
