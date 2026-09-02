defmodule MetadataApp.IdentificadoresTransaccionales.FolioPerfil do
  use Ecto.Schema

  # Schema Ecto LIVIANO e INTERNO sobre la misma tabla física
  # `pty_folio_perfiles` que ya administra el BC generado
  # (`MetadataApp.MetaBusinessProcess.Catalogos.PtyFolioPerfiles`) — ver
  # design.md §6 y tasks.md Grupo B tarea 7. A propósito, DOS schemas
  # para la MISMA tabla, cada uno con el subconjunto de columnas que le
  # toca: el generado (Ficha/CRUD genérico) nunca ve `numero_actual`;
  # este, que usa el motor para el `SELECT ... FOR UPDATE` de design.md
  # §3.2, sí. Ningún cast/changeset acá — el único camino para tocar
  # `numero_actual` es `IdentificadoresTransaccionales` vía
  # `Repo.update_all`, nunca un changeset genérico.
  #
  # Nombres de columna tal cual los generó el field designer del BC
  # (sin sufijo `_id`): `documento` (FK a meta_schema_header),
  # `sucursal` (FK a meta_schema_branch), `subtipo_transaccion` (id
  # simple, ver dependencia asumida en design.md §2).
  schema "pty_folio_perfiles" do
    field :documento, :integer
    # Columna física renombrada por el usuario (2026-09-02) vía Field
    # Designer, de `subtipo_transaccion` (integer suelto) a
    # `pty_folio_perfiles_subtipos_transaccion` (referencia real →
    # pty_subtipos_transaccion, con FK) -- se mapea acá con `source:`
    # para que el resto del motor (buscar_perfiles/4, filtrar_subtipo/2)
    # siga usando el nombre corto `subtipo_transaccion` sin tocar más
    # código. NO confundir con el `subtipo_transaccion` del REGISTRO
    # transaccional (ese es un campo distinto, en otra tabla, y su
    # nombre físico SÍ tiene que ser literal `subtipo_transaccion` --
    # ver design.md §2/§3.1 -- ese no cambió acá).
    field :subtipo_transaccion, :integer, source: :pty_folio_perfiles_subtipos_transaccion
    field :sucursal, :integer
    field :serie, :string
    field :numero_inicial, :integer
    field :numero_actual, :integer
    field :delete_guid, :string
  end
end
