defmodule MetadataApp.Repo.Migrations.CrearPtyAlyMarcas20260813230955463 do
  use Ecto.Migration

  # No-op para instalaciones nuevas (2026-09-04, auditoría de replay desde
  # cero) -- pty_aly_marcas termina borrada de verdad
  # (20260819000712_eliminar_pty_aly_marcas, 14 dígitos, DROP IF EXISTS +
  # purgar_metadata_por_nombre). En un replay desde cero ese DROP corre
  # ANTES que esta CREATE (17 dígitos -- ver el comentario de más arriba
  # sobre el bug de formato de timestamp viejo), así que no encuentra nada
  # que borrar (drop_if_exists lo tolera en silencio) y esta CREATE
  # después la deja viva para siempre -- confirmado real, la tabla NO
  # existe en dev. Un sistema donde esto ya corrió de verdad (tabla creada
  # y luego borrada en el orden correcto) no se ve afectado.
  def change, do: :ok
end
