defmodule MetadataApp.StateEngine.Reglas.Post do
  @moduledoc """
  Postcondiciones del vocabulario del Motor de Estados (spec sección 5).
  Contrato: (registro, contexto, params, repo) -> {:ok, cambios} | {:error, razon}.

  `estampar_valor` y `mutar_relacionados` son transaccionales (corren dentro
  del `Ecto.Multi` del ciclo, ver `MetadataApp.StateEngine`). `notificar` es
  de cortesía (Paso 5b, después del commit) — acá solo es un placeholder que
  loguea; no hay todavía un pipeline real de notificaciones al que enganchar.
  """

  require Logger
  import Ecto.Query

  # estampar_valor: {campo, valor} — valor puede ser "ahora" (fecha de hoy), un literal, o null.
  def ejecutar("estampar_valor", registro, _contexto, %{"campo" => campo, "valor" => valor}, repo) do
    campo_atom = String.to_existing_atom(campo)
    valor_final = resolver_valor(valor)
    modulo = registro.__struct__

    {1, _} =
      repo.update_all(from(t in modulo, where: t.id == ^registro.id),
        set: [{campo_atom, valor_final}]
      )

    {:ok, %{campo => valor_final}}
  end

  # mutar_relacionados: {entidad, campo_relacion, cambio: {campo, valor}} — ej.
  # desasignar rutas del cliente (poner el campo de asignación en null).
  def ejecutar("mutar_relacionados", registro, _contexto, params, repo) do
    entidad = Map.fetch!(params, "entidad")
    campo_relacion = Map.fetch!(params, "campo_relacion")
    %{"campo" => campo, "valor" => valor} = Map.fetch!(params, "cambio")
    # Mismo motivo que en Reglas.Pre.evaluar/4 ("sin_relacionados"): asegura
    # que el módulo de `entidad` esté cargado para que sus átomos existan.
    MetadataApp.MetaSchemaContext.modulo_por_nombre(entidad)

    {n, _} =
      from(t in entidad,
        where: field(t, ^String.to_existing_atom(campo_relacion)) == ^registro.id
      )
      |> repo.update_all(set: [{String.to_existing_atom(campo), valor}])

    {:ok, %{filas: n}}
  end

  # notificar: {destinatario, plantilla} — placeholder, solo loguea (no hay pipeline de notificaciones real todavía).
  def ejecutar("notificar", registro, _contexto, params, _repo) do
    destinatario = Map.get(params, "destinatario")
    plantilla = Map.get(params, "plantilla")

    Logger.info(
      "[StateEngine] notificar (placeholder): destinatario=#{inspect(destinatario)} " <>
        "plantilla=#{inspect(plantilla)} registro_id=#{registro.id}"
    )

    {:ok, %{destinatario: destinatario, plantilla: plantilla}}
  end

  # Pública (no privada) porque es pura y se testea directo, sin pasar por
  # una columna real — ningún catálogo hoy tiene un campo :date para probar
  # "ahora" de punta a punta contra la base.
  def resolver_valor("ahora"), do: Date.utc_today()
  def resolver_valor(valor), do: valor
end
