defmodule MetadataApp.Repo.Migrations.AmpliarUltimoErrorPanelControlApp do
  use Ecto.Migration

  # ultimo_error quedó como :string (varchar(255) default de Ecto) --
  # los mensajes reales de fallo (stdout/stderr de kubectl/ssh, o el JSON
  # de error de Hostinger) fácilmente superan eso. Encontrado real:
  # Desplegador.crear_app/1 crasheaba con "value too long for type
  # character varying(255)" al intentar GUARDAR el error real, ocultando
  # cuál era -- el usuario nunca llegaba a ver el motivo verdadero del
  # fallo. :text no tiene límite de tamaño en Postgres.
  def change do
    alter table(:meta_schema_panel_control_app) do
      modify :ultimo_error, :text
    end
  end
end
