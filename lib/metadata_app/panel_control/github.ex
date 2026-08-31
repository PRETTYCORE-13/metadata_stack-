defmodule MetadataApp.PanelControl.Github do
  @moduledoc """
  Panel Control > "Generar imagen desde repositorio" (2026-08-31) -- dado
  un repo de GitHub de un proyecto Phoenix/Elixir, arma (si hace falta)
  Dockerfile + `.github/workflows/ci.yml` + los overlays de release
  (`MetadataApp.PanelControl.PlantillasPhoenix`), los commitea en `main`,
  carga los 3 secrets que el job "deploy" del CI necesita, y espera a
  que esa corrida termine -- así una app nueva llega a tener una imagen
  publicada en `ghcr.io` sin que quien la pide sepa nada de Docker (ver
  memoria del proyecto/conversación 2026-08-31 sobre por qué existe esto).

  A propósito **solo repos Phoenix/Elixir** (100% de lo que este equipo
  construye) -- detectar/soportar otros lenguajes queda fuera de esta v1.
  Tampoco aprovisiona una base de datos: eso sigue siendo una variable de
  entorno que se completa a mano en el formulario de "Nueva app", igual
  que hoy.

  Usa la Git Data API (no la Contents API) para el commit del scaffolding
  -- es la única forma de fijar el bit de ejecución (100755) en
  `rel/overlays/bin/{server,migrate}` directo en el commit, sin pasar por
  ningún checkout local. Ver `PlantillasPhoenix` para el porqué de esto.
  """

  require Logger
  alias MetadataApp.Integraciones
  alias MetadataApp.PanelControl.{DeploySsh, PlantillasPhoenix}

  # :enacl solo se compila en :prod (ver mix.exs, esta máquina de dev no
  # tiene compilador de C) -- sin esto, "mix compile --warning-as-errors"
  # local (el alias "precommit") rompería SIEMPRE acá aunque el resto del
  # módulo esté bien, por una llamada que nunca corre en dev/test.
  @compile {:no_warn_undefined, {:enacl, :box_seal, 2}}

  @api "https://api.github.com"

  @doc """
  Punto de entrada: `repo` es "owner/repo" (o una URL completa de
  github.com, se le saca el owner/repo solo). `ambiente` es el
  `MetadataApp.Ambientes.Ambiente` de destino -- ahí se agrega la
  pública de la llave de deploy compartida si todavía no está.

  `k8s_deployment` es el nombre que va a tener el Deployment/Service en
  k3s (namespace fijo `panel-control`) -- normalmente el subdominio que
  la futura App va a usar en Panel Control.

  Devuelve `{:ok, "ghcr.io/owner/repo:latest"}` si el build terminó bien,
  o `{:error, motivo}` en cualquier paso.
  """
  def generar_imagen(repo, ambiente, k8s_deployment) do
    with {:ok, {owner, nombre_repo}} <- parsear_repo(repo),
         {:ok, token} <- token(),
         {:ok, app_snake} <- detectar_phoenix(owner, nombre_repo, token),
         {:ok, privada} <- DeploySsh.obtener_o_generar_privada(),
         :ok <- asegurar_llave_en_ambiente(ambiente, privada),
         {:ok, ya_scaffoldeado?} <- archivos_existentes?(owner, nombre_repo, token),
         {:ok, head_sha} <- asegurar_scaffold(owner, nombre_repo, app_snake, k8s_deployment, ya_scaffoldeado?, token),
         :ok <- configurar_secrets(owner, nombre_repo, ambiente, privada, token),
         {:ok, "success"} <- esperar_run(owner, nombre_repo, head_sha, token) do
      {:ok, "ghcr.io/#{String.downcase(owner)}/#{String.downcase(nombre_repo)}:latest"}
    end
  rescue
    e -> {:error, "Excepción generando la imagen: #{Exception.message(e)}"}
  end

  # --- repo / credencial ---------------------------------------------------

  defp parsear_repo(repo) do
    partes =
      repo
      |> String.trim()
      |> String.trim_leading("https://github.com/")
      |> String.trim_leading("github.com/")
      |> String.trim_trailing(".git")
      |> String.trim_trailing("/")
      |> String.split("/")

    case partes do
      [owner, nombre_repo] when owner != "" and nombre_repo != "" -> {:ok, {owner, nombre_repo}}
      _ -> {:error, "\"#{repo}\" no parece un repo de GitHub válido -- esperaba \"owner/repo\" o la URL completa."}
    end
  end

  defp token do
    case Integraciones.obtener_credencial_por_sistema("github") do
      nil -> {:error, "No hay ninguna credencial de GitHub configurada -- creá una en /sysadmin/credenciales con sistema_externo \"github\" (Personal Access Token con scopes repo + workflow)."}
      %{api_key: token} -> {:ok, token}
    end
  end

  defp headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  # --- detección de proyecto -------------------------------------------------

  defp detectar_phoenix(owner, repo, token) do
    with {:ok, contenido} <- contenido_archivo(owner, repo, "mix.exs", token) do
      cond do
        not (contenido =~ ~r/:phoenix\s*,/) ->
          {:error, "\"#{owner}/#{repo}\" no parece un proyecto Phoenix (no se encontró :phoenix entre las dependencias de mix.exs) -- esta función todavía no soporta otros stacks."}

        match = Regex.run(~r/app:\s*:(\w+)/, contenido) ->
          [_, app_snake] = match
          {:ok, app_snake}

        true ->
          {:error, "No se pudo determinar el nombre de la app (\"app: :...\") en el mix.exs de \"#{owner}/#{repo}\"."}
      end
    end
  end

  defp contenido_archivo(owner, repo, ruta, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/contents/#{ruta}"

    case Req.get(url, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"content" => base64, "encoding" => "base64"}}} ->
        {:ok, base64 |> String.replace("\n", "") |> Base.decode64!() }

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_existe}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "GitHub devolvió HTTP #{status} leyendo #{ruta}: #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  defp archivo_existe?(owner, repo, ruta, token) do
    case contenido_archivo(owner, repo, ruta, token) do
      {:ok, _} -> {:ok, true}
      {:error, :no_existe} -> {:ok, false}
      {:error, motivo} -> {:error, motivo}
    end
  end

  defp archivos_existentes?(owner, repo, token) do
    with {:ok, dockerfile?} <- archivo_existe?(owner, repo, "Dockerfile", token),
         {:ok, ci?} <- archivo_existe?(owner, repo, ".github/workflows/ci.yml", token) do
      {:ok, dockerfile? and ci?}
    end
  end

  # --- llave SSH en el Ambiente ----------------------------------------------

  defp asegurar_llave_en_ambiente(ambiente, privada) do
    with {:ok, publica} <- DeploySsh.clave_publica(privada) do
      comando =
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " <>
          "grep -qxF \"#{publica}\" ~/.ssh/authorized_keys 2>/dev/null || echo \"#{publica}\" >> ~/.ssh/authorized_keys; " <>
          "chmod 600 ~/.ssh/authorized_keys"

      case MetadataApp.Ssh.ejecutar(ambiente, comando) do
        {:ok, 0, _salida} -> :ok
        {:ok, codigo, salida} -> {:error, "No se pudo agregar la llave de deploy al servidor (código #{codigo}): #{salida}"}
        {:error, motivo} -> {:error, "No se pudo conectar al servidor para agregar la llave de deploy: #{motivo}"}
      end
    end
  end

  # --- scaffold (Git Data API) -----------------------------------------------

  defp asegurar_scaffold(_owner, repo, _app_snake, _k8s_deployment, true, _token) do
    Logger.info("#{repo} ya tiene Dockerfile + ci.yml -- no se toca el scaffolding, solo se refrescan los secrets.")
    {:ok, :ya_existia}
  end

  defp asegurar_scaffold(owner, repo, app_snake, k8s_deployment, false, token) do
    app_camel = Macro.camelize(app_snake)

    archivos = [
      {"Dockerfile", "100644", PlantillasPhoenix.dockerfile(app_snake)},
      {".dockerignore", "100644", PlantillasPhoenix.dockerignore()},
      {"rel/overlays/bin/server", "100755", PlantillasPhoenix.overlay_server(app_snake)},
      {"rel/overlays/bin/migrate", "100755", PlantillasPhoenix.overlay_migrate(app_camel, app_snake)},
      {"lib/#{app_snake}/release.ex", "100644", PlantillasPhoenix.release_ex(app_camel, app_snake)},
      {".github/workflows/ci.yml", "100644", PlantillasPhoenix.ci_yml(app_snake, k8s_deployment)}
    ]

    with {:ok, sha_ref} <- obtener_ref(owner, repo, token),
         {:ok, sha_tree} <- crear_tree(owner, repo, sha_ref, archivos, token),
         {:ok, sha_commit} <- crear_commit(owner, repo, sha_tree, sha_ref, token),
         :ok <- actualizar_ref(owner, repo, sha_commit, token) do
      {:ok, sha_commit}
    end
  end

  defp obtener_ref(owner, repo, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/git/ref/heads/main"

    case Req.get(url, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"object" => %{"sha" => sha}}}} -> {:ok, sha}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, "No se pudo leer la rama main (HTTP #{status}): #{inspect(body)}"}
      {:error, motivo} -> {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  defp crear_tree(owner, repo, base_sha, archivos, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/git/trees"

    tree =
      Enum.map(archivos, fn {path, mode, contenido} ->
        %{path: path, mode: mode, type: "blob", content: contenido}
      end)

    body = %{base_tree: base_sha, tree: tree}

    case Req.post(url, json: body, headers: headers(token), receive_timeout: 20_000, retry: false) do
      {:ok, %Req.Response{status: 201, body: %{"sha" => sha}}} -> {:ok, sha}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, "No se pudo crear el árbol de archivos (HTTP #{status}): #{inspect(body)}"}
      {:error, motivo} -> {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  defp crear_commit(owner, repo, sha_tree, sha_padre, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/git/commits"

    mensaje = """
    Feature: Dockerfile + CI para publicar y desplegar la imagen sola

    Generado por Panel Control ("Generar imagen desde repositorio") --
    arma la imagen con mix phx.gen.release --docker, la publica en
    ghcr.io en cada push a main, y redepliega sola contra k3s.
    """

    body = %{message: mensaje, tree: sha_tree, parents: [sha_padre]}

    case Req.post(url, json: body, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 201, body: %{"sha" => sha}}} -> {:ok, sha}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, "No se pudo crear el commit (HTTP #{status}): #{inspect(body)}"}
      {:error, motivo} -> {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  defp actualizar_ref(owner, repo, sha_commit, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/git/refs/heads/main"
    body = %{sha: sha_commit, force: false}

    case Req.patch(url, json: body, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, "No se pudo actualizar main (HTTP #{status}): #{inspect(body)} -- ¿alguien pusheó al mismo tiempo?"}
      {:error, motivo} -> {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  # --- secrets (libsodium sealed box) ----------------------------------------

  defp configurar_secrets(owner, repo, ambiente, privada, token) do
    with {:ok, {key_id, clave_publica}} <- clave_publica_secrets(owner, repo, token),
         :ok <- set_secret(owner, repo, "DEPLOY_HOST", ambiente.host, key_id, clave_publica, token),
         :ok <- set_secret(owner, repo, "DEPLOY_USER", ambiente.ssh_usuario, key_id, clave_publica, token),
         :ok <- set_secret(owner, repo, "DEPLOY_SSH_KEY", privada, key_id, clave_publica, token) do
      :ok
    end
  end

  defp clave_publica_secrets(owner, repo, token) do
    url = "#{@api}/repos/#{owner}/#{repo}/actions/secrets/public-key"

    case Req.get(url, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"key_id" => key_id, "key" => key}}} ->
        {:ok, {key_id, Base.decode64!(key)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "No se pudo leer la clave pública de secrets del repo (HTTP #{status}): #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  # :enacl.box_seal/2 (crypto_box_seal de libsodium) -- único mecanismo que
  # la API de Actions acepta para mandar un secret. Solo se compila en
  # :prod (ver mix.exs) -- esta rama nunca corre en dev/test local.
  defp set_secret(owner, repo, nombre, valor, key_id, clave_publica, token) do
    cifrado = valor |> :enacl.box_seal(clave_publica) |> Base.encode64()

    url = "#{@api}/repos/#{owner}/#{repo}/actions/secrets/#{nombre}"
    body = %{encrypted_value: cifrado, key_id: key_id}

    case Req.put(url, json: body, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: status}} when status in [201, 204] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, "No se pudo cargar el secret #{nombre} (HTTP #{status}): #{inspect(body)}"}
      {:error, motivo} -> {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end

  # --- esperar el run ---------------------------------------------------------

  @doc "Poll de `actions/runs?head_sha=...` hasta que la corrida termine -- devuelve {:ok, conclusion} o {:error, motivo}."
  def esperar_run(owner, repo, head_sha, token, intentos \\ 60)

  def esperar_run(_owner, _repo, :ya_existia, _token, _intentos) do
    # Si el scaffold ya existía, no se disparó ninguna corrida nueva desde
    # acá -- alcanza con haber refrescado los secrets, no hay nada que
    # esperar.
    {:ok, "success"}
  end

  def esperar_run(_owner, _repo, _head_sha, _token, 0) do
    {:error, "El build no terminó después de varios minutos -- revisá el estado directo en GitHub Actions."}
  end

  def esperar_run(owner, repo, head_sha, token, intentos) do
    url = "#{@api}/repos/#{owner}/#{repo}/actions/runs?head_sha=#{head_sha}&event=push"

    case Req.get(url, headers: headers(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"workflow_runs" => [run | _]}}} ->
        case run do
          %{"status" => "completed", "conclusion" => conclusion} ->
            {:ok, conclusion}

          _en_progreso ->
            Process.sleep(10_000)
            esperar_run(owner, repo, head_sha, token, intentos - 1)
        end

      {:ok, %Req.Response{status: 200, body: %{"workflow_runs" => []}}} ->
        # GitHub todavía no registró la corrida que disparó el commit -- normal
        # en los primeros segundos.
        Process.sleep(3_000)
        esperar_run(owner, repo, head_sha, token, intentos - 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "No se pudo consultar el estado del build (HTTP #{status}): #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo contactar a GitHub: #{inspect(motivo)}"}
    end
  end
end
