defmodule MetadataApp.Repo.Migrations.QuitarFiltroFechaDefaultDeConsulta do
  use Ecto.Migration

  # Reemplazado por el mecanismo de "parámetros estándar" por campo (ver
  # Consulta.campos -- cada campo puede llevar "parametro" => "fecha" +
  # su propio modo/valor/valor_hasta ahí mismo) -- permite VARIAS
  # columnas de fecha con su propio rango, en vez de una sola por
  # Consulta como este par de columnas (agregadas hace unas horas,
  # 20260826182124, nunca llegó a usarse en producción). Migración hacia
  # adelante, no un rollback -- ver nota en el mensaje de commit/sesión
  # sobre por qué (versionado no estándar de migraciones pty_ en esta
  # base hace que "mix ecto.rollback" sea inseguro acá).
  def change do
    alter table(:meta_schema_consulta) do
      remove :filtro_fecha_catalogo, :string
      remove :filtro_fecha_campo, :string
    end
  end
end
