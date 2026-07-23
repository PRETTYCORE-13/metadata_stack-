defmodule MetadataApp.MetaImportExport do
  @moduledoc """
  Lógica de importación de metadata (catálogos + autómata) SIN ninguna
  dependencia de `Mix` — extraída de `mix meta.import`/`mix motor.import`
  (2026-07-23) porque `MetadataApp.Release` (que corre en un release de
  producción, donde `Mix` no existe) también necesita invocarla — ver
  `rel/overlays/bin/import_meta`, usado por `.github/workflows/bc-deploy.yml`
  para poblar `meta_schema_header`/`detail`/`estados`/`transiciones` de un
  BC recién desplegado (la migración crea la TABLA física; esto es lo que
  falta para que el catálogo exista como Business Context real).

  Cada función devuelve una lista de mensajes de texto en vez de escribir
  directo — el caller (un Mix.Task vía `Mix.shell().info/1`, o un release
  script vía `IO.puts/1`) decide cómo mostrarlos.
  """

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @doc "Importa cada `*.meta.json` de `dir` — crea el Header+Detalles si el catálogo no existe todavía, lo deja sin tocar si ya existe."
  def importar_meta(dir \\ "priv/repo/catalogos") do
    dir
    |> leer_json(".meta.json")
    |> Enum.map(&importar_contexto/1)
  end

  defp importar_contexto(contexto) do
    nombre = contexto["schema_context_name"]

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        case MetaSchemaContext.crear_header_con_detalles(contexto) do
          {:ok, {_header, _detalles}} -> "+ #{nombre}: creado"
          {:error, motivo} -> raise "Error importando #{nombre}: #{inspect(motivo)}"
        end

      _existente ->
        "= #{nombre}: ya existía, sin cambios"
    end
  end

  @doc "Importa cada `*.motor.json` de `dir` — recrea estados/transiciones resolviendo toda referencia por NOMBRE, no por id. Idempotente."
  def importar_motor(dir \\ "priv/repo/catalogos") do
    dir
    |> leer_json(".motor.json")
    |> Enum.flat_map(&importar_catalogo_motor/1)
  end

  defp importar_catalogo_motor(%{"catalogo" => nombre} = datos) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        ["- #{nombre}: catálogo no encontrado, saltado (¿faltó importar_meta antes?)"]

      header ->
        {estados_por_nombre, mensajes_estados} = importar_estados(header, datos["estados"] || [])
        mensajes_transiciones = importar_transiciones(header, datos["transiciones"] || [], estados_por_nombre)
        mensajes_estados ++ mensajes_transiciones
    end
  end

  defp importar_estados(header, lista) do
    existentes = header.id |> MetaEstadosAdmin.listar_estados() |> Map.new(&{&1.nombre, &1})

    Enum.reduce(lista, {existentes, []}, fn attrs, {acc, mensajes} ->
      nombre = attrs["nombre"]

      if Map.has_key?(acc, nombre) do
        {acc, mensajes ++ ["= #{header.schema_context_name} estado \"#{nombre}\": ya existía"]}
      else
        atributos = %{
          "meta_schema_header_id" => header.id,
          "nombre" => nombre,
          "orden" => attrs["orden"],
          "es_inicial" => attrs["es_inicial"] || false,
          "color" => attrs["color"],
          "icono" => attrs["icono"],
          "empresa_id" => attrs["empresa_id"]
        }

        case MetaEstadosAdmin.crear_estado_importado(atributos) do
          {:ok, estado} ->
            {Map.put(acc, nombre, estado), mensajes ++ ["+ #{header.schema_context_name} estado \"#{nombre}\": creado"]}

          {:error, changeset} ->
            raise "Error importando estado \"#{nombre}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        end
      end
    end)
  end

  defp importar_transiciones(header, lista, estados_por_nombre) do
    {_acc, mensajes} =
      Enum.reduce(lista, {MetaEstadosAdmin.listar_transiciones(header.id), []}, fn attrs, {acc, mensajes} ->
        origen_id = resolver_estado_id(attrs["estado_origen"], estados_por_nombre)
        destino_id = resolver_estado_id(attrs["estado_destino"], estados_por_nombre)

        case Enum.find(acc, &(&1.accion == attrs["accion"] and &1.estado_origen_id == origen_id)) do
          nil ->
            crear_transicion(header, attrs, origen_id, destino_id, acc, mensajes)

          _transicion ->
            {acc, mensajes ++ ["= #{header.schema_context_name} transición \"#{attrs["accion"]}\": ya existía"]}
        end
      end)

    mensajes
  end

  # Reglas PRE/POST (rediseño 2026-07-21) ya no viajan en el JSON de
  # transiciones — son código por catálogo, ver MetaReglasCodigo. Si el
  # JSON importado es de una versión vieja y todavía trae "reglas" por
  # transición, se ignora a propósito.
  defp crear_transicion(header, attrs, origen_id, destino_id, acumulado, mensajes) do
    atributos = %{
      "meta_schema_header_id" => header.id,
      "accion" => attrs["accion"],
      "etiqueta" => attrs["etiqueta"],
      "estado_origen_id" => origen_id,
      "estado_destino_id" => destino_id,
      "empresa_id" => attrs["empresa_id"],
      "campos_editables" => attrs["campos_editables"] || []
    }

    case MetaEstadosAdmin.crear_transicion(atributos) do
      {:ok, transicion} ->
        {[transicion | acumulado], mensajes ++ ["+ #{header.schema_context_name} transición \"#{attrs["accion"]}\": creada"]}

      {:error, changeset} ->
        raise "Error importando transición \"#{attrs["accion"]}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
    end
  end

  defp resolver_estado_id(nil, _estados_por_nombre), do: nil

  defp resolver_estado_id(nombre, estados_por_nombre) do
    case Map.fetch(estados_por_nombre, nombre) do
      {:ok, estado} -> estado.id
      :error -> raise "Estado \"#{nombre}\" no encontrado — ¿faltó en la lista de estados del JSON?"
    end
  end

  # Directorio ausente = cero archivos, no un error (ver mix meta.import) —
  # estado normal de un checkout/release sin ningún BC desplegado todavía.
  defp leer_json(dir, sufijo) do
    nombres = if File.dir?(dir), do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, sufijo)), else: []

    nombres
    |> Enum.sort()
    |> Enum.map(&(dir |> Path.join(&1) |> File.read!() |> Jason.decode!()))
  end
end
