defmodule MetadataApp.Repo.Migrations.CrearAlcancePorCatalogo do
  use Ecto.Migration

  def change do
    # Fase 3 del modelo de Alcance de Datos (2026-08-11) -- default false:
    # todo catálogo YA existente sigue sin ningún filtro nuevo hasta que un
    # admin lo prenda a mano en BcMotorLive (Fase 6), mismo criterio que
    # mostrar_id_en_tabla/etc conservó el comportamiento de siempre al
    # agregarse.
    alter table(:meta_schema_header) do
      add :alcance_habilitado, :boolean, null: false, default: false
    end

    # El "QUÉ TIPO" es por (rol, catálogo), no global del rol -- un mismo
    # rol puede necesitar :propio en un catálogo y :empresa en otro (ver
    # moduledoc de MetadataApp.Autenticacion.Scope). Mismo patrón que
    # meta_schema_rol_permiso: fila = concesión puntual, deny-by-default si
    # no existe.
    create table(:meta_schema_rol_alcance) do
      add :rol_id, references(:meta_schema_rol, on_delete: :delete_all), null: false
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all), null: false
      add :alcance_tipo, :string, null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string
    end

    create unique_index(:meta_schema_rol_alcance, [:rol_id, :meta_schema_header_id])
  end
end
