defmodule MetadataApp.Repo.Migrations.QuitarSubtipoTransaccionDePtyFolioPerfiles20260902004611 do
  use Ecto.Migration

  # No-op para instalaciones nuevas (2026-09-04, auditoría de replay desde
  # cero) -- 20260901201822_crear_pty_folio_perfiles ya fue consolidada
  # (2026-09-03) a su forma final, que nunca crea la columna
  # `subtipo_transaccion` que esta migración intenta quitar. Un sistema
  # donde la secuencia vieja sí corrió de verdad no se ve afectado.
  def change, do: :ok
end
