defmodule MetadataApp.MetaTepache do
  @moduledoc """
  "Tepache" (nombre interno de equipo — técnicamente un *bundle*): arma y
  comparte un paquete de BCs entre desarrolladores para previsualizar,
  **sin** disparar ningún deploy a producción — a diferencia de
  `MetadataApp.MetaPublicador`, que sí lo hace.

  Reutiliza `MetaPublicador.armar_bundle/1` para el `.tar.gz` en sí (mismo
  contenido: schema + migraciones + metadata + reglas) — lo único propio
  de este módulo es CÓMO se distribuye: un release nuevo por tepache,
  tageado `TEPACHE-NNNNNN` (consecutivo global, sin fecha — GitHub ya
  trackea fecha/autor del release solo, ver docs/roadmap.md #14), nunca
  reutilizando el tag `bc-<catalogo>` que usa la publicación real.

  Del lado de quien importa: registra los permisos del/los catálogo(s)
  recién traídos (CRUD + cada transición real) SIN concedérselos a ningún
  rol — RBAC (roles, concesiones) queda 100% fuera del bundle, es
  decisión de cada empresa/entorno, nunca algo que se hereda en silencio
  de la máquina de quien armó el tepache.

  ## Reconciliación al importar un catálogo que YA existe localmente

  `MetaImportExport.importar_meta/1` es (a propósito) solo aditivo: nunca
  borra un campo que exista localmente pero no venga en el `.meta.json`
  entrante — es lo correcto para el caso "restaurar en un ambiente vacío"
  (producción recién desplegada), pero NO alcanza para "el mismo catálogo
  siguió evolucionando" (ver docs/roadmap.md #14): si en el origen se
  quitó un campo, la migración `DROP COLUMN` sí viaja y sí corre (la
  columna física desaparece), pero la metadata local se queda con una
  fila húerfana apuntando a una columna que ya no existe.

  Por eso `preparar_import/1` DETECTA esto ANTES de tocar nada (ni migrar
  ni extraer) y devuelve `{:confirmar_remocion, ...}` si hace falta que
  un humano confirme — nunca se borra un campo (con datos reales) sin que
  alguien lo pida explícito. `aplicar_import/1` es el paso 2, ya con la
  decisión tomada.
  """

  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerador, MetaSchemaContext}
  alias MetadataApp.{MetaEstadosAdmin, MetaImportExport, MetaPublicador, Permissions}

  @doc """
  Orquesta el export completo — valida, re-sincroniza schemas, exporta
  metadata+autómata, arma el bundle y lo publica como `TEPACHE-NNNNNN`.
  Mismo flujo que `mix motor.tepache`, compartido con el LiveView (mismo
  criterio que `MetadataApp.MetaPublicador`, compartido entre CLI y
  wizard).

  `descripcion` es texto libre de quien publica (motivo/impacto/notas) —
  va primero en las notas del release, antes del resumen automático.

  {:ok, %{tag:, catalogos:, automaticos:, problemas:}} | {:error, mensaje}
  """
  def exportar(nombres, descripcion \\ "") do
    case MetaPublicador.validar(nombres) do
      {:error, _} = error ->
        error

      {:ok, %{catalogos: catalogos, problemas: problemas}} ->
        regenerar_schemas()
        exportar_metadata()
        armar_y_publicar(nombres, catalogos, problemas, descripcion)
    end
  end

  defp regenerar_schemas do
    MetaSchemaContext.listar_headers()
    |> Enum.map(& &1.schema_context_name)
    |> MetaSchemaContext.ordenar_por_dependencias()
    |> Enum.each(&CatalogoGenerador.generar/1)
  end

  defp exportar_metadata do
    headers = MetaSchemaContext.listar_headers()
    Enum.each(headers, &MetaSchemaContext.exportar_header(&1, "priv/repo/catalogos"))
    Enum.each(headers, &MetaEstadosAdmin.exportar_header(&1, "priv/repo/catalogos"))
  end

  defp armar_y_publicar(nombres, catalogos, problemas, descripcion) do
    case MetaPublicador.armar_bundle(catalogos) do
      {:error, _} = error ->
        error

      {:ok, bundle_path} ->
        automaticos = catalogos -- nombres
        notas = armar_notas(descripcion, nombres, automaticos, problemas)

        case publicar(bundle_path, notas) do
          {:ok, tag} ->
            File.rm(bundle_path)
            {:ok, %{tag: tag, catalogos: catalogos, automaticos: automaticos, problemas: problemas}}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Paso 1 del import: baja el tepache, mira qué catálogos trae, y detecta
  si alguno de ellos ya existe localmente con campos que el bundle
  entrante NO tiene (candidatos a "se quitaron en el origen"). NO migra
  ni extrae nada todavía — es seguro llamar esto sin que pase nada
  destructivo. El bundle queda descargado (sin borrar) para que
  `aplicar_import/1` no tenga que bajarlo de nuevo.

  {:ok, %{bundle_path:, nombres:, campos_removidos: %{catalogo => [campos]}}} | {:error, mensaje}
  """
  def preparar_import(tag) do
    with {:ok, bundle_path} <- descargar(tag),
         {:ok, nombres} <- catalogos_en_bundle(bundle_path) do
      campos_removidos = detectar_campos_removidos(bundle_path, nombres)
      {:ok, %{bundle_path: bundle_path, nombres: nombres, campos_removidos: campos_removidos}}
    end
  end

  @doc """
  Paso 2 del import: recibe el resultado de `preparar_import/1` (o uno
  con `campos_removidos` ya filtrado/confirmado por un humano) y aplica
  de verdad — extrae, migra (sin Mix, mismo mecanismo que
  `MetadataApp.Release.migrate/0`), importa metadata+autómata, borra
  (soft-delete) los campos confirmados en `campos_removidos`, y registra
  permisos de cada catálogo. Borra el bundle temporal al terminar.

  {:ok, %{catalogos:, mensajes:, campos_removidos:}} | {:error, mensaje}
  """
  def aplicar_import(%{bundle_path: bundle_path, nombres: nombres, campos_removidos: campos_removidos}) do
    case extraer(bundle_path) do
      {:error, _} = error ->
        error

      :ok ->
        File.rm(bundle_path)
        MetadataApp.Release.migrate()

        mensajes = MetaImportExport.importar_meta() ++ MetaImportExport.importar_motor()

        Enum.each(campos_removidos, fn {nombre, campos} ->
          Enum.each(campos, &eliminar_campo_local(nombre, &1))
        end)

        Enum.each(nombres, &registrar_permisos/1)

        {:ok, %{catalogos: nombres, mensajes: mensajes, campos_removidos: campos_removidos}}
    end
  end

  defp eliminar_campo_local(nombre_catalogo, campo) do
    case Enum.find(MetaSchemaContext.listar_detalles(nombre_catalogo), &(&1.schema_context_field == campo)) do
      nil -> :ok
      detalle -> MetaSchemaContext.eliminar_detalle(detalle) |> then(fn _ -> :ok end)
    end
  end

  # Compara, catálogo por catálogo, los campos que YA existen localmente
  # contra los que trae el .meta.json del bundle -- solo tiene sentido
  # para un catálogo que YA existe local (uno nuevo no tiene nada que
  # comparar, todo es alta). No asume que sea el mismo origen -- si
  # alguien armó el mismo nombre de catálogo de forma independiente, esto
  # lo va a marcar como "removidos" igual (falso positivo razonable: mejor
  # preguntar de más que borrar de menos).
  defp detectar_campos_removidos(bundle_path, nombres) do
    Enum.reduce(nombres, %{}, fn nombre, acc ->
      campos_locales = nombre |> MetaSchemaContext.listar_detalles() |> MapSet.new(& &1.schema_context_field)

      if MapSet.size(campos_locales) == 0 do
        acc
      else
        case leer_meta_json_del_bundle(bundle_path, nombre) do
          {:ok, entrante} ->
            campos_entrantes =
              (entrante["detalles"] || [])
              |> Enum.map(& &1["schema_context_field"])
              |> MapSet.new()

            case MapSet.difference(campos_locales, campos_entrantes) |> MapSet.to_list() do
              [] -> acc
              removidos -> Map.put(acc, nombre, removidos)
            end

          {:error, _} ->
            acc
        end
      end
    end)
  end

  # Extrae UN archivo puntual del bundle a stdout (sin tocar disco) --
  # para leer el .meta.json entrante y compararlo contra la metadata
  # local ANTES de decidir si hace falta confirmar algo.
  defp leer_meta_json_del_bundle(bundle_path, nombre_catalogo) do
    ruta_interna = "priv/repo/catalogos/#{nombre_catalogo}.meta.json"

    con_ruta_relativa(bundle_path, fn ruta ->
      case System.cmd("tar", ["-xzOf", ruta, ruta_interna], stderr_to_stdout: true) do
        {salida, 0} -> Jason.decode(salida)
        {salida, status} -> {:error, "tar -xzOf falló (status #{status}):\n#{salida}"}
      end
    end)
  end

  @doc """
  Próximo tag `TEPACHE-NNNNNN` — lista los releases existentes con ese
  prefijo y le suma 1 al mayor consecutivo encontrado (0 si no hay
  ninguno todavía). {:ok, tag} | {:error, mensaje}
  """
  def siguiente_tag do
    case System.cmd("gh", ["release", "list", "--json", "tagName"], stderr_to_stdout: true) do
      {salida, 0} ->
        numero =
          salida
          |> Jason.decode!()
          |> Enum.flat_map(fn %{"tagName" => tag} ->
            case Regex.run(~r/^TEPACHE-(\d{6})$/, tag) do
              [_, n] -> [String.to_integer(n)]
              _ -> []
            end
          end)
          |> Enum.max(fn -> 0 end)
          |> Kernel.+(1)

        {:ok, "TEPACHE-" <> String.pad_leading(Integer.to_string(numero), 6, "0")}

      {salida, status} ->
        {:error, "gh release list falló (status #{status}):\n#{salida}"}
    end
  end

  @doc """
  Notas del release en Markdown: la descripción libre de quien publica
  primero (si la puso), después catálogos seleccionados, los que se
  agregaron automático (detalles/referencias) y las advertencias del
  validador — mismos datos que ya muestra el wizard de BC List, para que
  quien reciba el tepache sepa qué trae y por qué sin tener que abrirlo.
  """
  def armar_notas(descripcion, seleccionados, automaticos, problemas) do
    """
    #{seccion_descripcion(descripcion)}**Catálogos incluidos:** #{Enum.join(seleccionados, ", ")}
    #{seccion_automaticos(automaticos)}
    #{seccion_problemas(problemas)}
    """
    |> String.trim_trailing()
  end

  defp seccion_descripcion(nil), do: ""
  defp seccion_descripcion(""), do: ""
  defp seccion_descripcion(texto), do: "#{String.trim(texto)}\n\n"

  defp seccion_automaticos([]), do: ""

  defp seccion_automaticos(automaticos) do
    "\n**Incluidos automáticamente (detalles/referencias):** #{Enum.join(automaticos, ", ")}\n"
  end

  defp seccion_problemas([]), do: "\nSin advertencias."

  defp seccion_problemas(problemas) do
    lineas = Enum.map(problemas, &"- [#{&1.severidad}] #{&1.mensaje}")
    "\n**Advertencias:**\n" <> Enum.join(lineas, "\n")
  end

  @doc """
  Crea el release `TEPACHE-NNNNNN` (calculado con `siguiente_tag/0`) y le
  sube el bundle ya armado como asset fijo `tepache.tar.gz` (nombre fijo,
  no el temporal de `armar_bundle/1` — así quien importa siempre sabe qué
  archivo bajar). {:ok, tag} | {:error, mensaje}
  """
  def publicar(bundle_path, notas) do
    case siguiente_tag() do
      {:error, _} = error -> error
      {:ok, tag} -> crear_release(tag, bundle_path, notas)
    end
  end

  # "local_path#texto" en "gh release upload" NO renombra el asset (probado
  # real, ver docs/roadmap.md #14) -- ese "#texto" define un LABEL (lo que
  # se ve en la UI de GitHub), pero el `name` real del asset se queda con
  # el filename de origen (el temporal de armar_bundle/1, ej.
  # "bc-bundle-962.tar.gz"). Por eso se copia primero a un archivo que YA
  # se llama "tepache.tar.gz" antes de subirlo -- así el asset real (no
  # solo la etiqueta) queda con un nombre fijo y predecible.
  defp crear_release(tag, bundle_path, notas) do
    destino_local = Path.join(Path.dirname(bundle_path), "tepache.tar.gz")
    File.cp!(bundle_path, destino_local)

    resultado =
      case System.cmd("gh", ["release", "create", tag, "--title", tag, "--notes", notas], stderr_to_stdout: true) do
        {_salida, 0} ->
          case System.cmd("gh", ["release", "upload", tag, destino_local], stderr_to_stdout: true) do
            {_salida, 0} -> {:ok, tag}
            {salida, status} -> {:error, "gh release upload falló (status #{status}):\n#{salida}"}
          end

        {salida, status} ->
          {:error, "gh release create falló (status #{status}):\n#{salida}"}
      end

    File.rm(destino_local)
    resultado
  end

  @doc """
  Baja el único asset `.tar.gz` del release `tag` al directorio actual
  como `tepache.tar.gz` (sobreescribe si ya existía uno de una bajada
  anterior). Por patrón, no por nombre fijo -- un release de tepache
  siempre tiene un solo asset, mismo criterio que ya usa `ci.yml` para
  restaurar los `bc-*` en cada deploy. {:ok, path} | {:error, mensaje}
  """
  def descargar(tag) do
    args = ["release", "download", tag, "-p", "*.tar.gz", "-O", "tepache.tar.gz", "--clobber"]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {_salida, 0} -> {:ok, "tepache.tar.gz"}
      {salida, status} -> {:error, "gh release download #{tag} falló (status #{status}):\n#{salida}"}
    end
  end

  @doc """
  Lista los catálogos que trae un bundle SIN extraerlo todavía (lee el
  índice del `.tar.gz`) — a partir de sus `.meta.json`, para saber
  exactamente qué se acaba de importar y así poder registrar sus permisos
  después (`priv/repo/catalogos/` puede tener OTROS `.meta.json` de
  catálogos propios de quien importa, no todo lo que hay ahí vino en este
  tepache). {:ok, [nombres]} | {:error, mensaje}
  """
  def catalogos_en_bundle(bundle_path) do
    con_ruta_relativa(bundle_path, fn ruta ->
      case System.cmd("tar", ["-tzf", ruta], stderr_to_stdout: true) do
        {salida, 0} ->
          nombres =
            salida
            |> String.split("\n", trim: true)
            |> Enum.filter(&String.ends_with?(&1, ".meta.json"))
            |> Enum.map(&(&1 |> Path.basename() |> String.replace_suffix(".meta.json", "")))

          {:ok, nombres}

        {salida, status} ->
          {:error, "tar -tzf falló (status #{status}):\n#{salida}"}
      end
    end)
  end

  @doc """
  Extrae el bundle DESDE LA RAÍZ del proyecto de quien importa — las
  rutas dentro del tar ya son relativas a `lib/`/`priv/` (mismo criterio
  que `MetaPublicador.rutas_de/1` al armarlo), así que los archivos caen
  solos en su lugar. :ok | {:error, mensaje}
  """
  def extraer(bundle_path) do
    con_ruta_relativa(bundle_path, fn ruta ->
      case System.cmd("tar", ["-xzf", ruta], stderr_to_stdout: true) do
        {_salida, 0} -> :ok
        {salida, status} -> {:error, "tar -xzf falló (status #{status}):\n#{salida}"}
      end
    end)
  end

  # En Windows, un path absoluto con letra de unidad (ej. "C:\...") hace
  # que tar lo interprete como un destino REMOTO ("usuario@host:ruta") y
  # falle con "Cannot connect to C:" -- mismo problema (y misma solución)
  # que ya resuelve MetaPublicador.armar_bundle/1 para la creación: nunca
  # pasarle a tar una ruta con ":". Acá el archivo puede venir de
  # cualquier lado (`descargar/1` siempre da uno relativo, pero un tepache
  # compartido a mano por fuera de GitHub Releases puede tener cualquier
  # ruta absoluta) -- si hace falta, se copia a un nombre relativo
  # temporal en el cwd, se opera sobre ESE, y se borra la copia al final
  # (nunca el original, que es responsabilidad de quien llamó).
  defp con_ruta_relativa(bundle_path, fun) do
    if Path.type(bundle_path) == :absolute do
      temporal = "tepache-tmp-#{System.unique_integer([:positive])}.tar.gz"
      File.cp!(bundle_path, temporal)

      try do
        fun.(temporal)
      after
        File.rm(temporal)
      end
    else
      fun.(bundle_path)
    end
  end

  @doc """
  Registra en `meta_schema_permiso` el CRUD estándar (leer/crear/editar/
  eliminar) + el nombre de cada transición real del catálogo — SIN
  concederlo a ningún rol. Sin este registro ni "administrador" podría
  ejecutar una transición recién importada (ve todo lo YA REGISTRADO, no
  es un comodín ciego — ver `Permissions.can?/3`). Ignora en silencio los
  que ya existan (idempotente, mismo criterio que `importar_meta/1`).
  """
  def registrar_permisos(nombre_catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre_catalogo) do
      nil ->
        {:error, "\"#{nombre_catalogo}\" no se encontró — ¿faltó importar_meta antes?"}

      header ->
        acciones =
          (["leer", "crear", "editar", "eliminar"] ++
             Enum.map(MetaEstadosAdmin.listar_transiciones(header.id), & &1.accion))
          |> Enum.uniq()

        Enum.each(acciones, &Permissions.crear_permiso(%{recurso: nombre_catalogo, accion: &1}))
        :ok
    end
  end
end
