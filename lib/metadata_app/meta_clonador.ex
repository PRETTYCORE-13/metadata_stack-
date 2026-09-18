defmodule MetadataApp.MetaClonador do
  @moduledoc """
  "Copiar" un catálogo maestro simple bajo un nombre nuevo
  (SPEC-SYS-1809202602) — clona header + detalles + autómata (si lo
  tiene), renombrando el prefijo propio de cada campo, y genera la
  tabla física + plantilla automática con el mismo camino que ya usa
  "Nuevo catálogo" (`MetaEstadosAdmin.crear_proceso_completo/1` +
  `CatalogoGenerador.generar/1`).

  Alcance v1 (`design.md` §1): solo catálogos maestro simples --
  `schema_context_type: 1`, sin `schema_encabezado_id`, sin detalles
  propios que dependan de él como maestro. Nunca copia filas de datos,
  plantillas CUSTOM del Constructor, ni permisos ya otorgados.
  """

  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerador, MetaSchemaContext}
  alias MetadataApp.MetaEstadosAdmin

  @doc """
  `atributos_nuevos`: %{"schema_context_name" (el "topic" corto, sin
  "pty_" -- mismo criterio que "Nuevo catálogo"), "schema_context_label",
  "carpeta_padre", "schema_context_icono"}.

  {:ok, header_nuevo} | {:error, mensaje}
  """
  def clonar(nombre_original, atributos_nuevos) do
    with {:ok, attrs_base} <- construir_plan(nombre_original, atributos_nuevos),
         {:ok, %{header: header_nuevo}} <- crear(attrs_base),
         {:ok, _resultado} <- CatalogoGenerador.generar(header_nuevo.schema_context_name) do
      {:ok, header_nuevo}
    else
      {:error, _mensaje} = error -> error
      {:error, _paso, motivo, _cambios} -> {:error, formatear_error(motivo)}
    end
  end

  @doc """
  Parte PURA de `clonar/2` -- solo lee metadata y arma el `attrs_base`
  renombrado, SIN escribir nada en la base. Separado de `clonar/2` a
  propósito para poder testear la lógica de renombrado (la parte con
  casos difíciles: autoreferencia vs. referencia a otro catálogo,
  huérfanos en `campos_editables`) sin pasar por `CatalogoGenerador.generar/1`
  (DDL en caliente, sin cobertura automatizada posible bajo el Sandbox
  transaccional de los tests -- ver `alcance_por_catalogo_ui_test.exs`).

  {:ok, attrs_base} | {:error, mensaje}
  """
  def construir_plan(nombre_original, atributos_nuevos) do
    with {:ok, header_original} <- validar_origen(nombre_original),
         {:ok, nombre_nuevo, nav_nueva} <- validar_destino(atributos_nuevos) do
      {:ok, armar_attrs(header_original, atributos_nuevos, nombre_nuevo, nav_nueva)}
    end
  end

  @doc "true si `header` es elegible para \"Copiar\" (v1: maestro simple, sin detalles propios)."
  def elegible?(%{schema_context_type: 1, schema_encabezado_id: nil} = header) do
    MetaSchemaContext.listar_catalogos_detalle(header.id) == []
  end

  def elegible?(_header), do: false

  defp validar_origen(nombre_original) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre_original) do
      nil ->
        {:error, "\"#{nombre_original}\" no existe."}

      header ->
        if elegible?(header) do
          {:ok, header}
        else
          {:error, "\"#{nombre_original}\" no se puede copiar (v1: solo catálogos maestro simples, sin Consultas ni detalles)."}
        end
    end
  end

  defp validar_destino(atributos_nuevos) do
    nombre_nuevo = MetaSchemaContext.nombre_sistema_desde(atributos_nuevos["schema_context_name"])
    nav_nueva = MetaSchemaContext.componer_nav(atributos_nuevos["carpeta_padre"], atributos_nuevos["schema_context_name"])

    with :ok <- MetaSchemaContext.validar_nombre_y_nav(nombre_nuevo, nav_nueva),
         :ok <- validar_etiqueta(atributos_nuevos["schema_context_label"]) do
      {:ok, nombre_nuevo, nav_nueva}
    end
  end

  defp validar_etiqueta(etiqueta) do
    if (etiqueta || "") |> String.trim() != "" do
      :ok
    else
      {:error, "La etiqueta no puede quedar vacía."}
    end
  end

  defp armar_attrs(header_original, atributos_nuevos, nombre_nuevo, nav_nueva) do
    nombre_original = header_original.schema_context_name
    detalles_nuevos = armar_detalles(nombre_original, nombre_nuevo)

    header_attrs = %{
      "schema_context_name" => nombre_nuevo,
      "schema_context_label" => atributos_nuevos["schema_context_label"],
      "schema_context_nav" => nav_nueva,
      "schema_context_icono" => atributos_nuevos["schema_context_icono"] || header_original.schema_context_icono,
      "schema_context_type" => 1,
      "schema_visible" => header_original.schema_visible,
      "schema_es_transaccional" => header_original.schema_es_transaccional,
      "requiere_folio" => header_original.requiere_folio,
      "alcance_habilitado" => header_original.alcance_habilitado,
      "cargar_todos_por_default" => header_original.cargar_todos_por_default,
      "mostrar_id_en_tabla" => header_original.mostrar_id_en_tabla,
      "mostrar_estado_en_tabla" => header_original.mostrar_estado_en_tabla,
      "mostrar_trn_en_tabla" => header_original.mostrar_trn_en_tabla,
      "mostrar_folio_en_tabla" => header_original.mostrar_folio_en_tabla,
      "mostrar_empresa_en_tabla" => header_original.mostrar_empresa_en_tabla,
      "mostrar_branch_en_tabla" => header_original.mostrar_branch_en_tabla,
      "mostrar_inventory_location_en_tabla" => header_original.mostrar_inventory_location_en_tabla,
      "mostrar_sales_unit_en_tabla" => header_original.mostrar_sales_unit_en_tabla,
      "mostrar_creado_por_en_tabla" => header_original.mostrar_creado_por_en_tabla,
      "schema_encabezado_id" => nil,
      "detalles" => detalles_nuevos
    }

    {estados_attrs, transiciones_attrs} = armar_automata(header_original, nombre_original, nombre_nuevo, detalles_nuevos)

    %{"header" => header_attrs, "estados" => estados_attrs, "transiciones" => transiciones_attrs}
  end

  # "fecha_registro" nunca se clona -- CatalogoGenerador.generar/1 la
  # vuelve a agregar sola (asegurar_detalle_fecha_registro/1), igual que
  # a cualquier catálogo nuevo.
  defp armar_detalles(nombre_original, nombre_nuevo) do
    nombre_original
    |> MetaSchemaContext.listar_detalles()
    |> Enum.reject(&(&1.schema_context_field == "fecha_registro"))
    |> Enum.map(fn detalle ->
      %{
        "schema_context_field" => renombrar_campo(detalle.schema_context_field, nombre_original, nombre_nuevo),
        "schema_context_properties" => renombrar_propiedades(detalle.schema_context_properties, nombre_original, nombre_nuevo)
      }
    end)
  end

  # Solo "campos_relacion" es autoreferencia (siempre el propio campo,
  # nunca el de otro catálogo) -- "catalogo"/"campo_visualizacion"/
  # "campos_acompanamiento" apuntan al catálogo REFERENCIADO y quedan
  # intactos (design.md §3, R7 de requirements.md).
  defp renombrar_propiedades(propiedades, nombre_original, nombre_nuevo) do
    case propiedades["campos_relacion"] do
      nil ->
        propiedades

      lista ->
        Map.put(propiedades, "campos_relacion", Enum.map(lista, &renombrar_campo(&1, nombre_original, nombre_nuevo)))
    end
  end

  defp armar_automata(header_original, nombre_original, nombre_nuevo, detalles_nuevos) do
    case MetaEstadosAdmin.listar_estados(header_original.id) do
      [] ->
        {[], []}

      estados ->
        nombres_campos_nuevos = MapSet.new(detalles_nuevos, & &1["schema_context_field"])

        estados_attrs =
          Enum.map(estados, &%{"nombre" => &1.nombre, "orden" => &1.orden, "es_inicial" => &1.es_inicial, "color" => &1.color, "icono" => &1.icono})

        nombres_por_id = Map.new(estados, &{&1.id, &1.nombre})

        transiciones_attrs =
          header_original.id
          |> MetaEstadosAdmin.listar_transiciones()
          |> Enum.map(fn t ->
            campos_editables_nuevos =
              t.campos_editables
              |> Enum.map(&renombrar_campo(&1, nombre_original, nombre_nuevo))
              |> Enum.filter(&MapSet.member?(nombres_campos_nuevos, &1))

            %{
              "accion" => t.accion,
              "etiqueta" => t.etiqueta,
              "estado_origen" => t.estado_origen_id && Map.fetch!(nombres_por_id, t.estado_origen_id),
              "estado_destino" => Map.fetch!(nombres_por_id, t.estado_destino_id),
              "campos_editables" => campos_editables_nuevos
            }
          end)

        {estados_attrs, transiciones_attrs}
    end
  end

  defp renombrar_campo(campo, nombre_original, nombre_nuevo) do
    prefijo = nombre_original <> "_"

    if String.starts_with?(campo, prefijo) do
      nombre_nuevo <> "_" <> String.trim_leading(campo, prefijo)
    else
      campo
    end
  end

  # insertar_proceso/1, NO crear_proceso_completo/1: ese último exige un
  # estado inicial o transición "alta" para cualquier maestro -- correcto
  # para el wizard "Nuevo catálogo" (algo armado de CERO), pero un
  # original que nunca adoptó el motor de estados se clona igual de "sin
  # motor" (R10 de requirements.md), sin inventarle un autómata para
  # pasar esa regla.
  defp crear(attrs_base), do: MetaEstadosAdmin.insertar_proceso(attrs_base)

  defp formatear_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {campo, {mensaje, _opts}} -> "#{campo}: #{mensaje}" end)
    |> Enum.join(", ")
  end

  defp formatear_error(motivo) when is_binary(motivo), do: motivo
  defp formatear_error(motivo), do: inspect(motivo)
end
