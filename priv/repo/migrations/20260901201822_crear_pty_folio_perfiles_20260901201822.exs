defmodule MetadataApp.Repo.Migrations.CrearPtyFolioPerfiles20260901201822 do
  use Ecto.Migration

  # Consolidada (2026-09-03) para un checkout limpio -- crea la tabla
  # directo en su forma FINAL actual, sin replayar la secuencia histórica
  # real (crear con `subtipo_transaccion` suelto -> quitarla -> agregar
  # `pty_folio_perfiles_subtipos_transaccion` como referencia real, vía
  # Field Designer 2026-09-02). Esas 2 migraciones intermedias nunca se
  # comitearon (mismo motivo `pty_*` de siempre) y esta tampoco se había
  # comiteado nunca antes -- no hay ambiente real que ya la haya corrido
  # con el shape viejo, así que reescribir su contenido acá es seguro
  # (un ambiente que YA tiene la tabla -- ej. producción, armada a mano
  # con el Motor BC -- no vuelve a correr esta migración, Ecto la marca
  # aplicada por versión, no por contenido).
  def change do
    create table(:pty_folio_perfiles) do
      add :documento, references(:meta_schema_header), null: false
      add :pty_folio_perfiles_subtipos_transaccion, references(:pty_subtipos_transaccion), null: true
      add :sucursal, references(:meta_schema_branch), null: true
      add :serie, :string, size: 4, null: false
      add :numero_inicial, :integer, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

      # design.md §6 / tasks.md tarea 7: contador interno, fuera de
      # `@campos` -- el generado Ficha/CRUD nunca lo ve, solo
      # IdentificadoresTransaccionales vía su propio schema Ecto
      # liviano (FolioPerfil) sobre la misma tabla.
      add :numero_actual, :integer, null: false, default: 0
    end

    create unique_index(:pty_folio_perfiles, [:documento, :pty_folio_perfiles_subtipos_transaccion, :sucursal, :serie, :numero_inicial],
             name: :pty_folio_perfiles_unico_index
           )
  end
end
