defmodule MetadataApp.Purga.GhFalso do
  @moduledoc """
  `gh` en memoria para las pruebas de la purga (SPEC-ARQ-3009202601): un
  Agent con `%{tag => %{ruta => contenido}}` que atiende `api` (listado) y
  `release view/create/download/upload/delete`.
  """

  alias MetadataApp.Purga.Releases

  def iniciar(paquetes) do
    {:ok, agente} = Agent.start_link(fn -> %{releases: paquetes, siguiente_id: 1, ids: %{}} end)
    agente
  end

  def releases(agente), do: Agent.get(agente, & &1.releases)

  def funcion(agente), do: &llamar(agente, &1)

  def llamar(agente, ["api" | _]) do
    salida =
      Agent.get_and_update(agente, fn s ->
        {lineas, s} =
          Enum.map_reduce(Enum.sort(s.releases), s, fn {tag, _}, s ->
            {id, s} = id_de(s, tag)
            {Jason.encode!(%{tag: tag, asset_id: id}), s}
          end)

        {Enum.join(lineas, "\n"), s}
      end)

    {:ok, {salida, 0}}
  end

  def llamar(agente, ["release", "view", tag]) do
    if Map.has_key?(releases(agente), tag),
      do: {:ok, {"", 0}},
      else: {:ok, {"release not found", 1}}
  end

  def llamar(agente, ["release", "create", tag | _]) do
    Agent.update(agente, &put_in(&1, [:releases, tag], %{}))
    {:ok, {"", 0}}
  end

  def llamar(agente, ["release", "download", tag, "--pattern", _, "--output", path, "--clobber"]) do
    archivos = releases(agente)[tag]
    temporal = Path.join(Path.dirname(path), "arma_#{System.unique_integer([:positive])}")
    File.cp!(Releases.empaquetar(archivos, temporal), path)
    File.rm_rf!(temporal)
    {:ok, {"", 0}}
  end

  def llamar(agente, ["release", "upload", tag, path, "--clobber"]) do
    archivos = Releases.extraer(path)

    Agent.update(agente, fn s ->
      s |> put_in([:releases, tag], archivos) |> Map.update!(:ids, &Map.delete(&1, tag))
    end)

    {:ok, {"", 0}}
  end

  def llamar(agente, ["release", "delete", tag, "--yes", "--cleanup-tag"]) do
    Agent.update(agente, &Map.update!(&1, :releases, fn r -> Map.delete(r, tag) end))
    {:ok, {"", 0}}
  end

  # Un asset re-subido recibe id nuevo, igual que en GitHub.
  defp id_de(s, tag) do
    case s.ids do
      %{^tag => id} ->
        {id, s}

      _ ->
        {s.siguiente_id,
         %{s | siguiente_id: s.siguiente_id + 1, ids: Map.put(s.ids, tag, s.siguiente_id)}}
    end
  end
end
