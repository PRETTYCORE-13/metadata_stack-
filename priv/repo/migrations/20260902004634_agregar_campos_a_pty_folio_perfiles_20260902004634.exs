defmodule MetadataApp.Repo.Migrations.AgregarPtyFolioPerfilesSubtiposTransaccionAPtyFolioPerfiles20260902004634 do
  use Ecto.Migration

  # No-op para instalaciones nuevas (2026-09-04, auditoría de replay desde
  # cero) -- mismo motivo que 20260902004611: la consolidación de
  # 20260901201822_crear_pty_folio_perfiles ya agrega esta columna directo
  # en la creación.
  def change, do: :ok
end
