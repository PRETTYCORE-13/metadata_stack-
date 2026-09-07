defmodule MetadataApp.Repo.Migrations.CrearPtySubtiposTransaccion20260901231458 do
  use Ecto.Migration

  # No-op para instalaciones nuevas (2026-09-04, auditoría de replay desde
  # cero) -- duplicado real de
  # 20260901201800_crear_pty_subtipos_transaccion.exs, que se agregó a
  # propósito con timestamp ANTERIOR para satisfacer la FK dura de
  # pty_folio_perfiles (20260901201822). Un sistema donde ESTA versión ya
  # corrió (creó la tabla de verdad, con su índice) no se ve afectado --
  # Ecto marca por versión, no por contenido.
  def change, do: :ok
end
