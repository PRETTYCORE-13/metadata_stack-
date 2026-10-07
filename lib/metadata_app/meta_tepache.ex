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
  alias MetadataApp.{MetaEstadosAdmin, MetaImportExport, MetaPlantillas, MetaPublicador, Permissions}

  @doc """
  Orquesta el export completo — valida, exige que no falte ninguna
  dependencia por seleccionar, re-sincroniza schemas, exporta
  metadata+autómata, arma el bundle y lo publica como `TEPACHE-NNNNNN`.
  Mismo flujo que `mix motor.tepache`, compartido con el LiveView (mismo
  criterio que `MetadataApp.MetaPublicador`, compartido entre CLI y
  wizard).

  `descripcion` es texto libre de quien publica (motivo/impacto/notas) —
  va primero en las notas del release, antes del resumen automático.

  Si el cierre de dependencias de `nombres` (`MetaPublicador.validar/1`)
  incluye algún catálogo que no fue seleccionado explícitamente, rechaza
  con `{:error, mensaje}` sin tocar disco ni GitHub — nunca agrega esa
  dependencia a la selección en silencio (SPEC-SYS-0710202601 R9).

  `opts[:progreso]` (opcional) es una función de 1 argumento que se
  llama al INICIAR cada etapa, con su número: 1 validar, 2 regenerar
  schemas, 3 exportar metadata, 4 armar el paquete, 5 publicar en
  GitHub (SPEC-SYS-0710202601 R20). Solo emite el número; el texto de
  cada etapa es de quien la muestra.

  {:ok, %{tag:, catalogos:, problemas:}} | {:error, mensaje}
  """
  def exportar(nombres, descripcion \\ "", opts \\ []) do
    progreso = Keyword.get(opts, :progreso, fn _etapa -> :ok end)
    progreso.(1)

    case MetaPublicador.validar(nombres) do
      {:error, _} = error ->
        error

      {:ok, %{catalogos: catalogos, problemas: problemas}} ->
        case catalogos -- nombres do
          [] ->
            progreso.(2)
            regenerar_schemas()
            progreso.(3)
            exportar_metadata()
            armar_y_publicar(nombres, catalogos, problemas, descripcion, progreso)

          faltantes ->
            {:error, mensaje_dependencias_faltantes(faltantes)}
        end
    end
  end

  defp mensaje_dependencias_faltantes(faltantes) do
    "Faltan agregar estas dependencias antes de exportar: #{Enum.join(faltantes, ", ")} — agrégalas a tu selección e intenta de nuevo."
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
    Enum.each(headers, &MetaPlantillas.exportar_header(&1, "priv/repo/catalogos"))
  end

  defp armar_y_publicar(nombres, catalogos, problemas, descripcion, progreso) do
    progreso.(4)

    case MetaPublicador.armar_bundle(catalogos) do
      {:error, _} = error ->
        error

      {:ok, bundle_path} ->
        notas = armar_notas(descripcion, nombres, problemas)
        progreso.(5)

        case publicar(bundle_path, notas) do
          {:ok, tag} ->
            File.rm(bundle_path)
            {:ok, %{tag: tag, catalogos: catalogos, problemas: problemas}}

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

  `opts[:progreso]` (opcional): mismo contrato que en `exportar/3`.
  Emite las etapas 1 (descargar) y 2 (revisar contenido); las 3-6 las
  emite `aplicar_import/2`, para que las dos fases formen una sola
  barra (SPEC-SYS-0710202601 R22).

  {:ok, %{bundle_path:, nombres:, campos_removidos: %{catalogo => [campos]}}} | {:error, mensaje}
  """
  def preparar_import(tag, opts \\ []) do
    progreso = Keyword.get(opts, :progreso, fn _etapa -> :ok end)
    progreso.(1)

    with {:ok, bundle_path} <- descargar(tag),
         _ = progreso.(2),
         {:ok, nombres} <- catalogos_en_bundle(bundle_path) do
      campos_removidos = detectar_campos_removidos(bundle_path, nombres)
      {:ok, %{bundle_path: bundle_path, nombres: nombres, campos_removidos: campos_removidos}}
    end
  end

  @doc """
  Paso 2 del import: recibe el resultado de `preparar_import/1` (o uno
  con `campos_removidos` ya filtrado/confirmado por un humano) y aplica
  de verdad — extrae, migra (sin Mix, mismo mecanismo que
  `MetadataApp.Release.migrate/0`), importa metadata+autómata solo de
  los catálogos del bundle, borra
  (soft-delete) los campos confirmados en `campos_removidos`, y registra
  permisos de cada catálogo. Borra el bundle temporal al terminar.

  `opts[:progreso]` (opcional): emite las etapas 3 (extraer), 4
  (migrar), 5 (importar metadata) y 6 (registrar permisos) — ver
  `preparar_import/2`.

  Si falla después de empezar a extraer, deshace lo que hizo ESTE
  intento — archivos y migraciones — y devuelve `{:error, mensaje}` con
  el paso, la causa y el resultado de la reversión; nunca lanza por una
  migración que truena (SPEC-SYS-0710202601 R21). Metadata, soft-delete
  de campos y permisos van en una sola transacción (todo o nada).

  `opts[:raiz]` y `opts[:dir_migraciones]` existen para probarlo sin
  tocar el proyecto real; `opts[:importar]` reemplaza los pasos 5-6
  (solo para forzar una falla en tests).

  {:ok, %{catalogos:, mensajes:, campos_removidos:}} | {:error, mensaje}
  """
  def aplicar_import(%{bundle_path: bundle_path, nombres: nombres, campos_removidos: campos_removidos}, opts \\ []) do
    progreso = Keyword.get(opts, :progreso, fn _etapa -> :ok end)
    raiz = Keyword.get(opts, :raiz, ".")
    # Path.expand/1 normaliza a "/": en Windows una ruta con "\" hace que
    # Path.wildcard/1 (y Ecto.Migrator, que lo usa) no encuentre nada.
    dir_migraciones =
      opts |> Keyword.get(:dir_migraciones, Application.app_dir(:metadata_app, "priv/repo/migrations")) |> Path.expand()
    importar = Keyword.get(opts, :importar, &importar_y_registrar(&1, &2, raiz, progreso))
    progreso.(3)

    case entradas_del_bundle(bundle_path) do
      {:error, _} = error ->
        File.rm(bundle_path)
        error

      {:ok, entradas} ->
        respaldo = respaldar(entradas, raiz)
        resultado = extraer_migrar_e_importar(bundle_path, raiz, dir_migraciones, nombres, campos_removidos, importar, progreso)
        File.rm(bundle_path)

        case resultado do
          {:ok, mensajes} ->
            File.rm_rf(respaldo.dir)
            {:ok, %{catalogos: nombres, mensajes: mensajes, campos_removidos: campos_removidos}}

          {:fallo, paso, causa, aplicadas} ->
            reversion = revertir(respaldo, aplicadas, dir_migraciones, raiz)
            {:error, mensaje_falla(paso, causa, reversion)}
        end
    end
  end

  defp extraer_migrar_e_importar(bundle_path, raiz, dir_migraciones, nombres, campos_removidos, importar, progreso) do
    case extraer(bundle_path, raiz) do
      {:error, causa} ->
        {:fallo, "extraer los archivos", causa, []}

      :ok ->
        progreso.(4)
        pendientes = versiones_con_estado(dir_migraciones, :down)

        case migrar(dir_migraciones) do
          {:error, causa} ->
            {:fallo, "migrar tu base", causa_de_migracion(causa, pendientes, dir_migraciones),
             aplicadas_en_este_intento(pendientes, dir_migraciones)}

          :ok ->
            progreso.(5)

            case en_transaccion(fn -> importar.(nombres, campos_removidos) end) do
              {:ok, mensajes} ->
                {:ok, mensajes}

              {:error, causa} ->
                {:fallo, "importar metadata y permisos", causa, aplicadas_en_este_intento(pendientes, dir_migraciones)}
            end
        end
    end
  end

  defp importar_y_registrar(nombres, campos_removidos, raiz, progreso) do
    mensajes = importar_catalogos(nombres, Path.join(raiz, "priv/repo/catalogos"))

    Enum.each(campos_removidos, fn {nombre, campos} ->
      Enum.each(campos, &eliminar_campo_local(nombre, &1))
    end)

    progreso.(6)
    Enum.each(nombres, &Permissions.registrar_permisos_catalogo/1)
    mensajes
  end

  ## Reversión de un import fallido (SPEC-SYS-0710202601 R21, design §11)

  # Antes de extraer: copia lo que el bundle va a sobrescribir y anota lo
  # que va a crear (archivos y directorios), para poder dejarlo igual.
  defp respaldar(entradas, raiz) do
    dir = Path.join(System.tmp_dir!(), "tepache_respaldo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    archivos = Enum.reject(entradas, &String.ends_with?(&1, "/"))

    {respaldados, nuevos} = Enum.split_with(archivos, &File.regular?(Path.join(raiz, &1)))

    Enum.each(respaldados, fn entrada ->
      destino = Path.join(dir, entrada)
      File.mkdir_p!(Path.dirname(destino))
      File.cp!(Path.join(raiz, entrada), destino)
    end)

    dirs_nuevos =
      nuevos
      |> Enum.flat_map(&ancestros/1)
      |> Enum.uniq()
      |> Enum.reject(&File.dir?(Path.join(raiz, &1)))

    %{dir: dir, respaldados: respaldados, nuevos: nuevos, dirs_nuevos: dirs_nuevos}
  end

  defp ancestros(entrada) do
    entrada
    |> Path.dirname()
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reject(&(&1 == "."))
  end

  defp versiones_con_estado(dir_migraciones, estado) do
    MetadataApp.Repo
    |> Ecto.Migrator.migrations([dir_migraciones])
    |> Enum.filter(fn {e, _version, _nombre} -> e == estado end)
    |> MapSet.new(fn {_e, version, _nombre} -> version end)
  end

  defp migrar(dir_migraciones) do
    Ecto.Migrator.run(MetadataApp.Repo, [dir_migraciones], :up, all: true)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, motivo -> {:error, inspect(motivo)}
  end

  # La migración que tronó es la de versión más baja que sigue pendiente
  # (Ecto las corre en orden y la que falla se revierte sola).
  defp causa_de_migracion(causa, pendientes, dir_migraciones) do
    case pendientes |> MapSet.intersection(versiones_con_estado(dir_migraciones, :down)) |> Enum.min(fn -> nil end) do
      nil -> causa
      version -> "#{causa} (migración #{archivo_de_version(dir_migraciones, version)})"
    end
  end

  # Las que estaban pendientes justo antes de migrar y ahora están
  # aplicadas, de la más nueva a la más vieja (orden para revertir).
  defp aplicadas_en_este_intento(pendientes, dir_migraciones) do
    dir_migraciones
    |> versiones_con_estado(:up)
    |> MapSet.intersection(pendientes)
    |> Enum.sort(:desc)
    |> Enum.map(&archivo_de_version(dir_migraciones, &1))
  end

  defp archivo_de_version(dir_migraciones, version) do
    case Path.wildcard(Path.join(dir_migraciones, "#{version}_*.exs")) do
      [ruta | _] -> Path.basename(ruta)
      [] -> "#{version}"
    end
  end

  # 25P02 / {:error, :rollback} solo dicen que la transacción ya estaba
  # abortada: la causa real fue un error anterior que alguien atrapó.
  @pista_transaccion_abortada "— un paso anterior dentro de la transacción falló y la abortó; el primer error está en el log del servidor"

  # Todo o nada para metadata + soft-delete + permisos (R21.3). Cualquier
  # forma de no confirmar (excepción, {:error, _}, transacción abortada)
  # es falla del paso.
  @doc false
  def en_transaccion(fun) do
    case MetadataApp.Repo.transaction(fun) do
      {:ok, valor} -> {:ok, valor}
      {:error, motivo} -> {:error, "la transacción no se confirmó (#{inspect(motivo)}) #{@pista_transaccion_abortada}"}
    end
  rescue
    e in Postgrex.Error ->
      case e.postgres do
        %{code: :in_failed_sql_transaction} -> {:error, "#{Exception.message(e)} #{@pista_transaccion_abortada}"}
        _ -> {:error, Exception.message(e)}
      end

    e ->
      {:error, Exception.message(e)}
  catch
    :exit, motivo -> {:error, inspect(motivo)}
  end

  defp revertir(respaldo, aplicadas, dir_migraciones, raiz) do
    case Enum.filter(aplicadas, &crea_si_no_existe?(Path.join(dir_migraciones, &1))) do
      [] ->
        case revertir_migraciones(aplicadas, dir_migraciones) do
          {:ok, revertidas} ->
            case restaurar_archivos(respaldo, raiz) do
              :ok ->
                File.rm_rf(respaldo.dir)
                {:revertido, revertidas, length(respaldo.respaldados) + length(respaldo.nuevos)}

              {:error, causa} ->
                {:archivos_sin_restaurar, revertidas, causa, respaldo.dir}
            end

          {:error, revertidas, fallida, causa, restantes} ->
            {:migracion_sin_revertir, revertidas, fallida, causa, restantes, respaldo.dir}
        end

      peligrosas ->
        {:sin_revertir, peligrosas, aplicadas, respaldo.dir}
    end
  end

  # R21.4(a): revertir una migración "crear si no existe" podría borrar
  # una tabla que ya existía con datos.
  defp crea_si_no_existe?(ruta) do
    case File.read(ruta) do
      {:ok, codigo} -> Regex.match?(~r/if_not_exists|if\s+not\s+exists/i, codigo)
      {:error, _} -> false
    end
  end

  # Mismo mecanismo que MetadataApp.Release.rollback/2 (compilar el .exs
  # y Ecto.Migrator.down/4 por versión exacta), pero con el directorio
  # como parámetro y parando en la primera que falle (R21.4(b)).
  defp revertir_migraciones(aplicadas, dir_migraciones) do
    Enum.reduce_while(aplicadas, {:ok, []}, fn nombre, {:ok, revertidas} ->
      case revertir_migracion(nombre, dir_migraciones) do
        :ok ->
          {:cont, {:ok, revertidas ++ [nombre]}}

        {:error, causa} ->
          {:halt, {:error, revertidas, nombre, causa, aplicadas -- revertidas}}
      end
    end)
  end

  defp revertir_migracion(nombre, dir_migraciones) do
    [{modulo, _bin} | _] = Code.compile_file(Path.join(dir_migraciones, nombre))
    version = nombre |> String.split("_", parts: 2) |> hd() |> String.to_integer()
    Ecto.Migrator.down(MetadataApp.Repo, version, modulo, log: false)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, motivo -> {:error, inspect(motivo)}
  end

  defp restaurar_archivos(respaldo, raiz) do
    Enum.each(respaldo.nuevos, &File.rm(Path.join(raiz, &1)))
    Enum.each(respaldo.respaldados, &File.cp!(Path.join(respaldo.dir, &1), Path.join(raiz, &1)))

    respaldo.dirs_nuevos
    |> Enum.sort_by(&length(Path.split(&1)), :desc)
    |> Enum.each(&File.rmdir(Path.join(raiz, &1)))

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp mensaje_falla(paso, causa, reversion) do
    "El import falló al #{paso}: #{causa}. " <> describir_reversion(reversion)
  end

  defp describir_reversion({:revertido, revertidas, archivos}) do
    "No se aplicó nada: se revirtieron #{length(revertidas)} migraciones y se restauraron #{archivos} archivos." <>
      aviso_columnas(revertidas)
  end

  defp describir_reversion({:sin_revertir, peligrosas, aplicadas, dir_respaldo}) do
    "No se revirtió nada automáticamente: estas migraciones usan \"crear si no existe\" y revertirlas podría borrar una tabla que ya tenías: " <>
      "#{Enum.join(peligrosas, ", ")}. Quedaron aplicadas: #{Enum.join(aplicadas, ", ")}. " <>
      "Los archivos extraídos siguen en tu proyecto; las copias de los que se sobrescribieron están en #{dir_respaldo}."
  end

  defp describir_reversion({:migracion_sin_revertir, revertidas, fallida, causa, restantes, dir_respaldo}) do
    "Se revirtieron: #{lista_o_ninguna(revertidas)}. No se pudo revertir #{fallida} (#{causa}); " <>
      "quedaron aplicadas: #{Enum.join(restantes, ", ")}. No se tocaron los archivos extraídos; " <>
      "las copias de los que se sobrescribieron están en #{dir_respaldo}." <> aviso_columnas(revertidas)
  end

  defp describir_reversion({:archivos_sin_restaurar, revertidas, causa, dir_respaldo}) do
    "Se revirtieron #{length(revertidas)} migraciones, pero no se pudieron restaurar los archivos (#{causa}); " <>
      "las copias están en #{dir_respaldo}." <> aviso_columnas(revertidas)
  end

  defp lista_o_ninguna([]), do: "ninguna"
  defp lista_o_ninguna(lista), do: Enum.join(lista, ", ")

  # R21.5: una migración que quitó columnas ya perdió esos datos al migrar.
  defp aviso_columnas(revertidas) do
    case Enum.filter(revertidas, &String.contains?(&1, "quitar_")) do
      [] -> ""
      quitaban -> " Ojo: #{Enum.join(quitaban, ", ")} quitaba columnas; al revertir se vuelven a crear vacías — sus datos se perdieron al migrar."
    end
  end

  # Importa metadata+autómata+plantillas SOLO de `nombres` (los del
  # bundle), nunca de toda la carpeta: el checkout local puede tener
  # .json de otros catálogos que no coinciden con la base, y no deben
  # aplicarse por importar un tepache (SPEC-SYS-0710202601 R14.1). Mismo
  # patrón que MetadataApp.Release.import_meta/0 -- copiar a un
  # directorio temporal e importar desde ahí, sin tocar MetaImportExport.
  @doc false
  def importar_catalogos(nombres, dir \\ "priv/repo/catalogos") do
    dir_tmp = Path.join(System.tmp_dir!(), "tepache_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir_tmp)

    try do
      for nombre <- nombres,
          sufijo <- [".meta.json", ".motor.json", ".plantillas.json"],
          origen = Path.join(dir, nombre <> sufijo),
          File.regular?(origen),
          do: File.cp!(origen, Path.join(dir_tmp, nombre <> sufijo))

      MetaImportExport.importar_meta(dir_tmp) ++
        MetaImportExport.importar_motor(dir_tmp) ++
        MetaImportExport.importar_plantillas(dir_tmp)
    after
      File.rm_rf(dir_tmp)
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
      case ejecutar("tar", ["-xzOf", ruta, ruta_interna]) do
        {:ok, {salida, 0}} -> Jason.decode(salida)
        {:ok, {salida, status}} -> {:error, "tar -xzOf falló (status #{status}):\n#{salida}"}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Próximo tag `TEPACHE-NNNNNN` — lista los releases existentes con ese
  prefijo y le suma 1 al mayor consecutivo encontrado (0 si no hay
  ninguno todavía). {:ok, tag} | {:error, mensaje}

  `--limit 1000` explícito -- bug real (2026-09-29): `gh release list`
  sin límite trae solo los 30 más recientes por default. Con cientos de
  releases `bc-*` ya publicados, los TEPACHE-* viejos quedan fuera de
  esos 30, así que este cálculo los ignoraba y volvía a proponer
  "TEPACHE-000001", chocando con el que ya existía.
  """
  def siguiente_tag do
    case ejecutar("gh", ["release", "list", "--json", "tagName", "--limit", "1000"]) do
      {:ok, {salida, 0}} ->
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

      {:ok, {salida, status}} ->
        {:error, "gh release list falló (status #{status}):\n#{salida}"}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Notas del release en Markdown: la descripción libre de quien publica
  primero (si la puso), después catálogos incluidos (ya es el paquete
  completo — R9 exige que coincida con lo seleccionado, nunca hay nada
  "agregado automático" que aclarar acá) y las advertencias del
  validador — mismos datos que ya muestra el wizard de BC List, para que
  quien reciba el tepache sepa qué trae y por qué sin tener que abrirlo.
  """
  def armar_notas(descripcion, seleccionados, problemas) do
    """
    #{seccion_descripcion(descripcion)}**Catálogos incluidos:** #{Enum.join(seleccionados, ", ")}
    #{seccion_problemas(problemas)}
    """
    |> String.trim_trailing()
  end

  defp seccion_descripcion(nil), do: ""
  defp seccion_descripcion(""), do: ""
  defp seccion_descripcion(texto), do: "#{String.trim(texto)}\n\n"

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
      case ejecutar("gh", ["release", "create", tag, "--title", tag, "--notes", notas]) do
        {:ok, {_salida, 0}} ->
          case ejecutar("gh", ["release", "upload", tag, destino_local]) do
            {:ok, {_salida, 0}} -> {:ok, tag}
            {:ok, {salida, status}} -> {:error, "gh release upload falló (status #{status}):\n#{salida}"}
            {:error, _} = error -> error
          end

        {:ok, {salida, status}} ->
          {:error, "gh release create falló (status #{status}):\n#{salida}"}

        {:error, _} = error ->
          error
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

    case ejecutar("gh", args) do
      {:ok, {_salida, 0}} -> {:ok, "tepache.tar.gz"}
      {:ok, {salida, status}} -> {:error, "gh release download #{tag} falló (status #{status}):\n#{salida}"}
      {:error, _} = error -> error
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
    with {:ok, entradas} <- entradas_del_bundle(bundle_path) do
      nombres =
        entradas
        |> Enum.filter(&String.ends_with?(&1, ".meta.json"))
        |> Enum.map(&(&1 |> Path.basename() |> String.replace_suffix(".meta.json", "")))

      {:ok, nombres}
    end
  end

  # Índice completo del tar (archivos y directorios), sin extraerlo.
  defp entradas_del_bundle(bundle_path) do
    con_ruta_relativa(bundle_path, fn ruta ->
      case ejecutar("tar", ["-tzf", ruta]) do
        {:ok, {salida, 0}} ->
          # El tar.exe nativo de Windows termina cada línea de "-tzf" en
          # "\r\n" -- separar solo por "\n" deja un "\r" colgando al final
          # de cada entrada, así que "String.ends_with?(&1, ".meta.json")"
          # nunca matchea nada (visto real: nombres volvía [] y
          # aplicar_import/1 corría sin registrar_permisos ni detectar
          # campos removidos). String.trim/1 por línea lo resuelve sin
          # importar el line ending del tar que se esté usando.
          {:ok, salida |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}

        {:ok, {salida, status}} ->
          {:error, "tar -tzf falló (status #{status}):\n#{salida}"}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Extrae el bundle DESDE LA RAÍZ del proyecto de quien importa — las
  rutas dentro del tar ya son relativas a `lib/`/`priv/` (mismo criterio
  que `MetaPublicador.rutas_de/1` al armarlo), así que los archivos caen
  solos en su lugar. `raiz` cambia el destino (para tests).
  :ok | {:error, mensaje}
  """
  def extraer(bundle_path, raiz \\ ".") do
    con_ruta_relativa(bundle_path, fn ruta ->
      case ejecutar("tar", ["-xzf", ruta, "-C", raiz]) do
        {:ok, {_salida, 0}} -> :ok
        {:ok, {salida, status}} -> {:error, "tar -xzf falló (status #{status}):\n#{salida}"}
        {:error, _} = error -> error
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
  # System.cmd lanza ErlangError (:enoent) si el ejecutable no está en el
  # PATH de quien corre el servidor -- sin esto, tirar un tepache import
  # con "gh" no instalado/no en PATH mataba todo el proceso LiveView
  # (visto real: reporte de Lizbeth, GenServer terminating con :enoent).
  # Envuelve el resultado en {:ok, {salida, status}} | {:error, mensaje}
  # para que cada call site siga decidiendo con el mismo patrón de antes.
  defp ejecutar(programa, args) do
    {:ok, System.cmd(programa, args, stderr_to_stdout: true)}
  rescue
    e in ErlangError ->
      {:error, "No se pudo ejecutar \"#{programa}\" -- ¿está instalado y en el PATH de este proceso? (#{Exception.message(e)})"}
  end

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

end
