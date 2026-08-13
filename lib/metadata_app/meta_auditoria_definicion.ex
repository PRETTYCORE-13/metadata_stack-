defmodule MetadataApp.MetaAuditoriaDefinicion do
  @moduledoc """
  Log de auditoría de la DEFINICIÓN de un BC hecho por ADN (roadmap #13
  — distinto del #6, que audita DATOS/registros de negocio, ver
  `MetadataApp.MetaAuditoria`). Hoy solo se llama desde
  `CatalogoGenerador.eliminar/4` y `eliminar_campo/4` (borrado de
  catálogo/campo) -- crear/actualizar quedan pendientes de enganchar.

  `contexto`: mismo mapa que ya arma `MetadataAppWeb.AuditoriaContexto`
  (`:usuario_id`/`:usuario_email`/`:empresa_id`/`:ip`/`:user_agent`).
  Sin contexto (`%{}`, default), la fila queda con esos campos en `nil`
  -- caso legítimo para mix tasks/scripts sin un usuario real detrás.
  """

  alias MetadataApp.MetaSchema.AuditoriaDefinicion
  alias MetadataApp.Repo

  @doc "`operacion`: \"crear\" | \"actualizar\" | \"eliminar\". `detalle`: mapa jsonb con qué cambió puntualmente (ej. %{\"filas_eliminadas\" => 12} o %{\"campo\" => \"nombre\"})."
  def registrar(schema_context_name, operacion, detalle, contexto \\ %{}) do
    %AuditoriaDefinicion{}
    |> AuditoriaDefinicion.changeset(%{
      schema_context_name: schema_context_name,
      operacion: operacion,
      detalle: detalle,
      usuario_id: Map.get(contexto, :usuario_id),
      usuario_email: Map.get(contexto, :usuario_email),
      empresa_id: Map.get(contexto, :empresa_id),
      ip: Map.get(contexto, :ip),
      user_agent: Map.get(contexto, :user_agent)
    })
    |> Repo.insert!()
  end
end
