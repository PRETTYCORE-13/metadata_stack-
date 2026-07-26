defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaRbac do
  use Ecto.Migration

  # Mismo patrón que meta_schema_estados/meta_schema_transiciones: solo GUID
  # de auditoría (insert_guid obligatorio, update_guid/delete_guid
  # opcionales), sin timestamps() — son tablas de configuración del core,
  # no catálogos de negocio.
  def change do
    # "recurso" es el schema_context_name del catálogo (el mismo string de
    # /api/:tabla, resuelto en runtime por MetaSchemaContext.modulo_por_nombre/1)
    # — no hay seed automático: se da de alta a mano por catálogo.
    create table(:meta_schema_permiso) do
      add :recurso, :string, size: 100, null: false
      add :accion, :string, size: 50, null: false
      add :descripcion, :string, size: 255

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32
      add :delete_guid, :string, size: 32
    end

    create unique_index(:meta_schema_permiso, [:recurso, :accion])

    # empresa_id NULL = rol de sistema (administrador/consulta), disponible
    # para cualquier empresa. empresa_id seteado = rol propio de una empresa.
    create table(:meta_schema_rol) do
      add :empresa_id, references(:meta_schema_empresa, on_delete: :delete_all)
      add :nombre, :string, size: 100, null: false
      add :descripcion, :string, size: 255
      add :es_sistema, :boolean, null: false, default: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32
      add :delete_guid, :string, size: 32
    end

    create unique_index(:meta_schema_rol, [:empresa_id, :nombre])

    # Único por nombre entre los roles de sistema (empresa_id IS NULL no
    # cuenta como "igual" a otro NULL en un unique_index compuesto normal —
    # mismo motivo que el índice parcial de es_inicial en meta_schema_estados).
    create unique_index(:meta_schema_rol, [:nombre],
             name: :meta_schema_rol_sistema_unico_index,
             where: "empresa_id IS NULL"
           )

    create table(:meta_schema_rol_permiso) do
      add :rol_id, references(:meta_schema_rol, on_delete: :delete_all), null: false
      add :permiso_id, references(:meta_schema_permiso, on_delete: :delete_all), null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32
      add :delete_guid, :string, size: 32
    end

    create unique_index(:meta_schema_rol_permiso, [:rol_id, :permiso_id])

    # empresa_id siempre presente acá (a diferencia de meta_schema_rol): un
    # usuario tiene el rol asignado DENTRO de una empresa puntual, aunque el
    # rol en sí sea de sistema (compartido). Que empresa_id coincida con el
    # empresa_id del rol (cuando el rol no es de sistema) se valida en el
    # contexto, no acá — mismo criterio que el "al menos un estado inicial"
    # de meta_schema_estados.
    create table(:meta_schema_usuario_rol) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :rol_id, references(:meta_schema_rol, on_delete: :delete_all), null: false
      add :empresa_id, references(:meta_schema_empresa, on_delete: :delete_all), null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32
      add :delete_guid, :string, size: 32
    end

    create unique_index(:meta_schema_usuario_rol, [:usuario_id, :rol_id, :empresa_id])
  end
end
