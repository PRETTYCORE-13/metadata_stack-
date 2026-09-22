defmodule MetadataApp.PropagacionContext do
  @moduledoc """
  Fuente de datos de `/sysadmin/propagacion` (SPEC-SYS-1809202603 R9-R9b)
  -- Elixir puro, sin LiveView, mismo criterio que cualquier Context de
  este proyecto. Todo sale EN VIVO de git + k3s (vía `MotorAlta.Estado`)
  + el historial de runs de GitHub Actions (R9a) -- nunca de una tabla
  propia (mismo principio ya aprobado en R8/§3 de
  `SPEC-SYS-0309202601-alta-sistema-nuevo`).
  """

  alias MetadataApp.MotorAlta.Estado

  # OJO: "metadata_stack-" CON el guion final -- es el nombre real del
  # repositorio de GitHub (confirmado con "gh repo view"), distinto del
  # nombre de la imagen Docker ("metadata_stack", sin el guion -- ci.yml
  # lo recorta al armar el tag: `repo="${repo%[-._]}"`). Usar el nombre
  # de la imagen acá da 404 en la API de GitHub (encontrado real,
  # 2026-09-22, verificación en vivo de este mismo cambio).
  @repo "PRETTYCORE-13/metadata_stack-"

  @doc """
  Línea de tiempo de los últimos `limite` commits de `origin/main`, cada
  uno con: hash completo/corto, mensaje, autor (git), fecha, la lista de
  runs de `actualizar-sistema.yml` que apuntan a ESE commit (R9b: actor
  del run, distinto del autor del commit) y qué canales/sistemas están
  parados ahí ahora mismo (vía `ambiente`, R9-R9a).

  `{:ok, [commit]} | {:error, mensaje}` (R9c, 2026-09-22) -- consulta la
  API HTTP de GitHub, nunca shellea `git`/`gh` (esta pantalla también se
  abre directo contra un pod ya desplegado, que no los tiene instalados,
  ver SPEC-SYS-1809202603 §5.3). `{:error, ...}` cubre tanto "falta el
  token" como cualquier falla de red/API -- nunca una lista vacía
  silenciosa que un admin pueda confundir con "no hay commits".
  """
  def linea_de_tiempo(ambiente, limite \\ 30) do
    case github_token() do
      nil ->
        {:error, "Falta configurar GITHUB_TOKEN_LECTURA en este ambiente -- sin él, esta pantalla no puede consultar la API de GitHub (SPEC-SYS-1809202603 R9c)."}

      token ->
        with {:ok, commits} <- commits_recientes(token, limite),
             {:ok, runs_por_hash} <- runs_actualizar_sistema(token) do
          posiciones_por_hash = posiciones_por_hash(ambiente)

          {:ok,
           Enum.map(commits, fn commit ->
             commit
             |> Map.put(:runs, Map.get(runs_por_hash, commit.hash, []))
             |> Map.put(:posiciones, Map.get(posiciones_por_hash, commit.hash, []))
           end)}
        end
    end
  end

  defp github_token, do: Application.get_env(:metadata_app, :github_token_lectura)

  defp commits_recientes(token, limite) do
    case Req.get(api_url("/commits"), headers: api_headers(token), params: [sha: "main", per_page: limite]) do
      {:ok, %{status: 200, body: body}} -> {:ok, Enum.map(body, &parsear_commit/1)}
      {:ok, %{status: status, body: body}} -> {:error, "GitHub API (/commits) respondió #{status}: #{inspect(body)}"}
      {:error, exception} -> {:error, "No se pudo consultar GitHub (/commits): #{Exception.message(exception)}"}
    end
  end

  defp parsear_commit(%{
         "sha" => hash,
         "commit" => %{"message" => mensaje, "author" => %{"name" => autor, "date" => fecha_iso}}
       }) do
    {:ok, fecha, _offset} = DateTime.from_iso8601(fecha_iso)
    primera_linea = mensaje |> String.split("\n", parts: 2) |> hd()

    %{hash: hash, hash_corto: String.slice(hash, 0, 7), mensaje: primera_linea, autor: autor, fecha: fecha}
  end

  # %{hash_completo => [%{estado:, creado_en:, terminado_en:, titulo:}]}
  # -- lista (no un solo run) porque un mismo commit puede haberse
  # propagado más de una vez (ej. reintento, o a distintos destinos).
  # per_page=100 (máximo de la API por página) en vez del --limit 200 de
  # la versión con `gh` -- alcanza para calzar contra los últimos 30
  # commits que muestra la pantalla por default.
  defp runs_actualizar_sistema(token) do
    url = api_url("/actions/workflows/actualizar-sistema.yml/runs")

    case Req.get(url, headers: api_headers(token), params: [per_page: 100]) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} ->
        {:ok,
         Enum.group_by(runs, & &1["head_sha"], fn run ->
           %{
             estado: run["conclusion"] || run["status"],
             titulo: run["display_title"],
             creado_en: run["created_at"],
             terminado_en: run["updated_at"]
           }
         end)}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub API (/actions/workflows/.../runs) respondió #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, "No se pudo consultar GitHub (/actions/workflows/.../runs): #{Exception.message(exception)}"}
    end
  end

  defp api_url(path), do: "https://api.github.com/repos/#{@repo}#{path}"

  defp api_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end

  # "Nunca saltar Testing" (Grupo F, confirmado con el usuario) --
  # reinterpretado para un commit puntual sin "origen" explícito: cada
  # destino candidato solo se ofrece si su predecesor YA está parado en
  # ESE commit. `testing`/`stable` son los únicos candidatos de canal
  # (unstable se autoactualiza, nunca es un destino elegible acá);
  # cualquier otro nombre se trata como cliente (`priv/sistemas.json`),
  # ofrecible solo si `stable` ya está ahí -- mismo gate que ya impone
  # `actualizar-sistema.yml` del lado servidor (R6/R8 de
  # SPEC-SYS-0309202601), ofrecerlo antes evita un disparo que el
  # workflow rechazaría igual, con menos contexto.
  @canales_candidatos ~w(testing stable)

  def destino_ofrecible?(commit, "testing"), do: "unstable" in commit.posiciones
  def destino_ofrecible?(commit, "stable"), do: "testing" in commit.posiciones
  def destino_ofrecible?(commit, _cliente), do: "stable" in commit.posiciones

  @doc "Destinos (canal o cliente) que se le pueden ofrecer a `commit` para propagar/rollback -- ver destino_ofrecible?/2."
  def destinos_ofrecibles(commit, clientes) do
    Enum.filter(@canales_candidatos ++ clientes, &destino_ofrecible?(commit, &1))
  end

  @doc "El commit inmediatamente anterior (más viejo) a `hash` dentro de `commits` -- mismo orden que `linea_de_tiempo/2` (más reciente primero). `nil` si `hash` no está en la lista, o si es el más viejo cargado."
  def commit_anterior(commits, hash) do
    case Enum.find_index(commits, &(&1.hash == hash)) do
      nil -> nil
      idx -> Enum.at(commits, idx + 1)
    end
  end

  @doc """
  Rutas (relativas, tal como viven en el working tree local) de las
  migraciones agregadas entre `commit_viejo` (exclusive) y
  `commit_nuevo` (inclusive) -- exactamente las que hay que revertir
  para que la base quede consistente con un rollback de código de
  `commit_nuevo` a `commit_viejo` (Grupo H, R10a/R10b).

  `--diff-filter=A` -- solo archivos AGREGADOS en ese rango, nunca
  modificados/renombrados (una migración ya aplicada no debería
  reescribirse después, y si pasara, igual no es "agregar" una
  reversión nueva). `--format=` vacío para que la salida sea SOLO
  nombres de archivo, sin encabezados de commit mezclados.
  """
  def migraciones_entre(commit_viejo, commit_nuevo) do
    args = [
      "log",
      "--diff-filter=A",
      "--name-only",
      "--format=",
      "#{commit_viejo}..#{commit_nuevo}",
      "--",
      "priv/repo/migrations/"
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {salida, 0} -> salida |> String.split("\n", trim: true) |> Enum.uniq()
      {_salida, _status} -> []
    end
  rescue
    ErlangError -> []
  end

  # %{hash_completo => ["unstable", "ennova", ...]}
  defp posiciones_por_hash(ambiente) do
    ambiente
    |> Estado.consultar_todo()
    |> Enum.reduce(%{}, fn
      %{destino: destino, resultado: {:ok, imagen}}, acc ->
        hash = imagen |> String.split(":") |> List.last()
        Map.update(acc, hash, [destino], &[destino | &1])

      %{resultado: {:error, _}}, acc ->
        acc
    end)
  end
end
