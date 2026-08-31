defmodule MetadataApp.PanelControl.RegistryInspector do
  @moduledoc """
  Lee metadata pública de una imagen Docker directo del registry (Docker
  Hub, ghcr.io, o cualquier otro que hable el Docker Registry HTTP API
  V2) -- puerto expuesto (`EXPOSE`) y variables de entorno por defecto
  (`ENV`) del propio manifiesto/config de la imagen, para autocompletar
  el formulario de "Nueva app" de Panel Control (2026-08-31) SIN tocar
  el servidor de producción -- a diferencia de "Detectar automáticamente"
  en Ambientes de Deploy (que sí SSHea, porque ahí se consulta un
  deployment que YA existe), acá la app todavía no existe en ningún
  lado, así que no hay nada que preguntarle al servidor: se lee
  directamente del registry (solo un par de JSON chicos, nunca las capas
  de la imagen -- nada de `docker pull` en el VPS chico).

  Mismo mecanismo estándar que usa `docker pull`/`docker manifest
  inspect`: intenta el manifiesto sin credenciales, y si el registry
  responde 401 con un desafío `WWW-Authenticate: Bearer realm=...`, pide
  un token anónimo a ese `realm`. Alcanza para cualquier imagen pública,
  que es el único caso que Panel Control necesita -- no hay ningún lugar
  para cargar credenciales de un registry privado acá.
  """

  @registro_docker_hub "registry-1.docker.io"

  @manifest_accept Enum.join(
                      [
                        "application/vnd.docker.distribution.manifest.v2+json",
                        "application/vnd.docker.distribution.manifest.list.v2+json",
                        "application/vnd.oci.image.manifest.v1+json",
                        "application/vnd.oci.image.index.v1+json"
                      ],
                      ", "
                    )

  # PATH está en el 100% de las imágenes (herencia de la base Linux) y
  # nunca es algo que haya que configurar a mano -- solo agregaría ruido
  # al textarea de variables de entorno.
  @variables_ignoradas ["PATH"]

  @doc """
  Devuelve `{:ok, %{puerto: integer | nil, variables: [String.t()]}}` a
  partir de una referencia de imagen tal cual la tipea el usuario
  ("nginx", "nginx:latest", "ghcr.io/org/app:tag"...).
  """
  def inspeccionar(imagen) when is_binary(imagen) and imagen != "" do
    {registro, repo, referencia} = descomponer(imagen)

    with {:ok, manifest, token} <- obtener_manifest(registro, repo, referencia, nil),
         {:ok, manifest, token} <- resolver_lista(registro, repo, manifest, token),
         {:ok, digest} <- extraer_digest_config(manifest),
         {:ok, config} <- obtener_blob(registro, repo, digest, token) do
      {:ok, extraer_puerto_y_variables(config)}
    end
  rescue
    e -> {:error, "Excepción inspeccionando la imagen: #{Exception.message(e)}"}
  end

  def inspeccionar(_), do: {:error, "Escribí primero el nombre de la imagen."}

  # --- referencia -------------------------------------------------------

  defp descomponer(imagen) do
    partes = String.split(imagen, "/")
    primero = hd(partes)
    es_registry_explicito? = String.contains?(primero, ".") or String.contains?(primero, ":") or primero == "localhost"

    {registro, resto} =
      if es_registry_explicito? and length(partes) > 1 do
        {primero, Enum.join(tl(partes), "/")}
      else
        {@registro_docker_hub, imagen}
      end

    {repo_sin_tag, tag} = separar_tag(resto)

    repo =
      if registro == @registro_docker_hub and not String.contains?(repo_sin_tag, "/") do
        "library/#{repo_sin_tag}"
      else
        repo_sin_tag
      end

    {registro, repo, tag}
  end

  defp separar_tag(resto) do
    case String.split(resto, ":") do
      [repo] ->
        {repo, "latest"}

      partes ->
        {inicio, [ultimo]} = Enum.split(partes, -1)
        # Un ":" en el ÚLTIMO segmento con "/" adentro es un puerto de
        # host ("registry:5000/team/app"), no un tag -- ya se descartó el
        # registry antes de llegar acá, pero por las dudas.
        if String.contains?(ultimo, "/") do
          {resto, "latest"}
        else
          {Enum.join(inicio, ":"), ultimo}
        end
    end
  end

  # --- manifest -----------------------------------------------------------

  defp obtener_manifest(registro, repo, referencia, token) do
    url = "https://#{registro}/v2/#{repo}/manifests/#{referencia}"
    headers = [{"accept", @manifest_accept}] ++ auth_header(token)

    case Req.get(url, headers: headers, receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body, token}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decodificado} -> {:ok, decodificado, token}
          {:error, _} -> {:error, "El registry devolvió el manifiesto en un formato que no se pudo leer."}
        end

      {:ok, %Req.Response{status: 401} = resp} when is_nil(token) ->
        with {:ok, nuevo_token} <- token_desde_desafio(resp) do
          obtener_manifest(registro, repo, referencia, nuevo_token)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "El registry respondió HTTP #{status} buscando la imagen: #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo contactar al registry: #{inspect(motivo)}"}
    end
  end

  defp auth_header(nil), do: []
  defp auth_header(token), do: [{"authorization", "Bearer #{token}"}]

  defp token_desde_desafio(resp) do
    with [desafio | _] <- Req.Response.get_header(resp, "www-authenticate"),
         %{"realm" => realm} = campos <- parsear_desafio(desafio) do
      case Req.get(realm, params: Map.delete(campos, "realm"), receive_timeout: 10_000, retry: false) do
        {:ok, %Req.Response{status: 200, body: %{"token" => token}}} -> {:ok, token}
        {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
        {:ok, resp} -> {:error, "No se pudo autenticar contra el registry: #{inspect(resp.body)}"}
        {:error, motivo} -> {:error, "No se pudo contactar el servidor de autenticación: #{inspect(motivo)}"}
      end
    else
      _ -> {:error, "La imagen requiere autenticación y no se entendió el desafío del registry (¿es un registry privado?)."}
    end
  end

  defp parsear_desafio(desafio) do
    ~r/(\w+)="([^"]*)"/
    |> Regex.scan(desafio)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  # Una imagen multi-arquitectura devuelve una LISTA de manifiestos (uno
  # por plataforma) en vez del manifiesto real -- hay que elegir uno
  # (linux/amd64 por default, el más común en un VPS) y pedir ESE de nuevo.
  defp resolver_lista(registro, repo, %{"manifests" => [_ | _] = manifiestos}, token) do
    elegido =
      Enum.find(manifiestos, hd(manifiestos), fn m ->
        get_in(m, ["platform", "os"]) == "linux" and get_in(m, ["platform", "architecture"]) == "amd64"
      end)

    obtener_manifest(registro, repo, elegido["digest"], token)
  end

  defp resolver_lista(_registro, _repo, manifest, token), do: {:ok, manifest, token}

  defp extraer_digest_config(%{"config" => %{"digest" => digest}}), do: {:ok, digest}
  defp extraer_digest_config(_), do: {:error, "No se encontró la config de la imagen en su manifiesto."}

  # El blob de config suele servirse redirigido a un CDN (CloudFront,
  # GitHub Packages...) con un content-type genérico
  # ("application/octet-stream") aunque el contenido SEA JSON -- Req solo
  # decodifica automáticamente cuando reconoce el content-type, así que
  # acá hay que decodificar a mano si todavía llegó como string crudo
  # (encontrado real probando esto contra Docker Hub/ghcr.io, 2026-08-31).
  defp obtener_blob(registro, repo, digest, token) do
    url = "https://#{registro}/v2/#{repo}/blobs/#{digest}"

    case Req.get(url, headers: auth_header(token), receive_timeout: 15_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decodificado} -> {:ok, decodificado}
          {:error, _} -> {:error, "El registry devolvió la config de la imagen en un formato que no se pudo leer."}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "El registry respondió HTTP #{status} leyendo la config de la imagen: #{inspect(body)}"}

      {:error, motivo} ->
        {:error, "No se pudo leer la config de la imagen: #{inspect(motivo)}"}
    end
  end

  # --- extracción -----------------------------------------------------------

  defp extraer_puerto_y_variables(config) do
    puertos = get_in(config, ["config", "ExposedPorts"]) || %{}
    variables = get_in(config, ["config", "Env"]) || []

    puerto =
      puertos
      |> Map.keys()
      |> Enum.map(&(&1 |> String.split("/") |> hd() |> Integer.parse()))
      |> Enum.filter(&match?({_, _}, &1))
      |> Enum.map(&elem(&1, 0))
      |> List.first()

    variables_filtradas =
      Enum.reject(variables, fn var -> Enum.member?(@variables_ignoradas, var |> String.split("=", parts: 2) |> hd()) end)

    %{puerto: puerto, variables: variables_filtradas}
  end
end
