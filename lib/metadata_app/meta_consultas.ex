defmodule MetadataApp.MetaConsultas do
  @moduledoc """
  Consulta Ecto (BC tipo 3): un reporte de solo lectura compuesto de N
  tablas (Fase 1: una sola, `catalogo_base` — joins quedan para Fase 2).
  Sin tabla física propia, sin motor de estados, sin TRN — a diferencia
  de un catálogo normal, `MetaSchemaContext.modulo_por_nombre/1` nunca
  resuelve nada para el `schema_context_name` de una Consulta: los datos
  siempre se leen de `catalogo_base` (y, en Fase 2, de los catálogos
  unidos por `joins`), nunca de una tabla propia.
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Consulta
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico

  def obtener_por_header_id(header_id) do
    Repo.get_by(Consulta, meta_schema_header_id: header_id)
  end

  def obtener_por_catalogo(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      nil -> nil
      header -> obtener_por_header_id(header.id)
    end
  end

  # Arma la consulta con TODOS los campos de catalogo_base ya
  # seleccionados y visibles — arranca completa, el admin la recorta
  # después desde el editor (mismo criterio que un catálogo normal: nace
  # con "visible: true" en todos sus campos).
  def crear(%{id: header_id}, catalogo_base) do
    %Consulta{}
    |> Consulta.changeset(%{
      "meta_schema_header_id" => header_id,
      "catalogo_base" => catalogo_base,
      "campos" => campos_todos_del_catalogo(catalogo_base)
    })
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Etiqueta tomada de meta_schema_detail si el campo existe ahí; si no
  # (columna sin contrato propio — relevante sobre todo para Fase 2, un
  # campo calculado por un join), el nombre lógico tal cual, sin inventar
  # una etiqueta bonita.
  defp campos_todos_del_catalogo(catalogo) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.map(fn detalle ->
      props = detalle.schema_context_properties || %{}

      %{
        "catalogo" => catalogo,
        "campo" => detalle.schema_context_field,
        "etiqueta" => Map.get(props, "etiqueta") || detalle.schema_context_field,
        "tipo" => Map.get(props, "tipo", "string"),
        "orden" => Map.get(props, "orden", 0),
        "visible" => true,
        "totalizar" => false
      }
    end)
  end

  def actualizar_campos(%Consulta{} = consulta, campos) do
    consulta
    |> Consulta.changeset(%{"campos" => campos})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  @doc """
  Total de filas para los mismos filtros/búsqueda, sin paginar — mismo
  propósito que `CatalogoGenerico.contar/3` (que es lo que delega acá),
  para que CatalogoLive pueda calcular `total_paginas` ANTES de pedir la
  página con el offset correcto, igual que ya hace para un catálogo normal.
  """
  def contar(%Consulta{} = consulta, filtros \\ %{}, busqueda \\ nil) do
    modulo = MetaSchemaContext.modulo_por_nombre(consulta.catalogo_base)

    from(r in modulo, where: is_nil(r.delete_guid))
    |> CatalogoGenerico.aplicar_filtros(filtros)
    |> CatalogoGenerico.aplicar_busqueda(busqueda)
    |> Repo.aggregate(:count)
  end

  @doc """
  Ejecuta la consulta y devuelve `%{filas:, total_filas:, totales:}`.
  `filtros`/`opciones`/`busqueda` — mismo shape exacto que
  `CatalogoGenerico.listar/4` + `contar/3`, para reusar el mismo popover
  de filtros de CatalogoLive sin ninguna adaptación.

  `totales` — suma de cada campo marcado `"totalizar": true`, sobre TODAS
  las filas que matchean filtros/búsqueda (no solo la página actual) —
  banda de solo esas columnas, calculada en una query aparte con `sum/1`.
  """
  def ejecutar(%Consulta{} = consulta, filtros \\ %{}, opciones \\ [], busqueda \\ nil) do
    modulo = MetaSchemaContext.modulo_por_nombre(consulta.catalogo_base)
    campos_atoms = campos_seleccionados_atoms(consulta)

    base =
      from(r in modulo, where: is_nil(r.delete_guid), order_by: [asc: r.id])
      |> CatalogoGenerico.aplicar_filtros(filtros)
      |> CatalogoGenerico.aplicar_busqueda(busqueda)

    total_filas = Repo.aggregate(base, :count)

    filas =
      base
      |> select([r], map(r, ^campos_atoms))
      |> CatalogoGenerico.aplicar_paginacion(opciones)
      |> Repo.all()

    %{filas: filas, total_filas: total_filas, totales: totales(base, consulta)}
  end

  defp campos_seleccionados_atoms(%Consulta{campos: campos}) do
    campos
    |> Enum.filter(&(Map.get(&1, "visible") == true))
    |> Enum.sort_by(&Map.get(&1, "orden", 0))
    |> Enum.map(&String.to_existing_atom(Map.fetch!(&1, "campo")))
  end

  defp totales(base_query, %Consulta{campos: campos}) do
    campos_a_sumar =
      campos
      |> Enum.filter(&(Map.get(&1, "totalizar") == true))
      |> Enum.map(&Map.get(&1, "campo"))

    case campos_a_sumar do
      [] ->
        %{}

      _ ->
        campos_atoms = Enum.map(campos_a_sumar, &String.to_existing_atom/1)
        select_dinamico = Enum.into(campos_atoms, %{}, &{&1, dynamic([r], sum(field(r, ^&1)))})

        base_query
        # order_by choca con un SELECT agregado sin GROUP BY (no tiene
        # sentido ordenar una sola fila totalizada) — se descarta acá,
        # nunca afecta el order_by real de `filas`.
        |> exclude(:order_by)
        |> select([r], ^select_dinamico)
        |> Repo.one()
        |> Kernel.||(%{})
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
