defmodule MetadataApp.Repo.Migrations.QuitarCandadoReglasCodigo do
  use Ecto.Migration

  # El candado liviano autodeclarado (bloqueado_por/bloqueado_en) se retira
  # a pedido explícito del usuario: sin login real todavía no vale la pena
  # simular ownership — las reglas quedan siempre editables hasta que se
  # meta autenticación de verdad, momento en el que el locking se rediseña
  # desde cero (no se restaura este mecanismo).
  def change do
    alter table(:meta_schema_reglas_codigo) do
      remove :bloqueado_por, :string
      remove :bloqueado_en, :utc_datetime_usec
    end
  end
end
