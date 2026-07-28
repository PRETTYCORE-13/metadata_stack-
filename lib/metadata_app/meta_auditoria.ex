defmodule MetadataApp.MetaAuditoria do
  @moduledoc """
  Log de auditoría de DATOS (roadmap #6 — distinto del #13, que audita la
  DEFINICIÓN de un BC hecho por ADN, no sus registros). Un solo choke
  point (`BusinessProcessBuilder.CatalogoGenerico.crear/actualizar/eliminar`)
  llama a `registrar/6` justo después de cada alta/edición/baja real.

  `contexto` (Fase 2 del roadmap #6, todavía no threadeado desde los call
  sites reales — `CatalogoController`/`CatalogoLive`/`FichaLive`): mapa
  opcional con `:usuario_id`/`:usuario_email`/`:empresa_id`/`:ip`/
  `:user_agent`. Sin contexto (`%{}`, default), la fila queda con esos
  campos en `nil` — caso legítimo para import/restore/mix tasks disparados
  sin un usuario real detrás, NO un error.
  """

  alias MetadataApp.MetaSchema.Auditoria
  alias MetadataApp.Repo

  @doc """
  `operacion`: "alta" | "edicion" | "baja" | "transicion:<accion>" (para
  que auditar quién aprobó/rechazó algo no quede genérico en "edicion").
  `datos`: %{"antes" => mapa | nil, "despues" => mapa | nil} — ya
  serializado (ver `CatalogoGenerico.serializar/1`), listo para jsonb.
  """
  def registrar(catalogo, operacion, guid, registro, datos, contexto \\ %{}) do
    %Auditoria{}
    |> Auditoria.changeset(%{
      bc: catalogo,
      operacion: operacion,
      guid: guid,
      trn: Map.get(registro, :trn),
      entidad_id: registro.id,
      datos: datos,
      usuario_id: Map.get(contexto, :usuario_id),
      usuario_email: Map.get(contexto, :usuario_email),
      empresa_id: Map.get(contexto, :empresa_id),
      ip: Map.get(contexto, :ip),
      user_agent: Map.get(contexto, :user_agent)
    })
    |> Repo.insert!()
  end
end
