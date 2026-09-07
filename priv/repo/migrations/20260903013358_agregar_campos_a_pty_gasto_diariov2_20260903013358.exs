defmodule MetadataApp.Repo.Migrations.AgregarPtyGastoDiariov2ValorPagadoAPtyGastoDiariov220260903013358 do
  use Ecto.Migration

  # No-op para instalaciones nuevas (2026-09-04, auditoría de replay desde
  # cero) -- la columna se movió a
  # 20260812235934081_crear_pty_gasto_diariov2 (17 dígitos, corre después
  # de esta en un replay desde cero por el bug de formato de timestamp
  # viejo -- ver el comentario ahí). Un sistema donde ESTA versión ya
  # agregó la columna de verdad no se ve afectado.
  def change, do: :ok
end
