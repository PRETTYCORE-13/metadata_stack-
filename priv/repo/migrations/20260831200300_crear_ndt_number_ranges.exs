defmodule MetadataApp.Repo.Migrations.CrearNdtNumberRanges do
  use Ecto.Migration

  # Contador vivo, separado del perfil (`pty_ndt_configuracion` — BC real,
  # ver docs de MetadataApp.NDT.Numbering, 2026-08-31: reemplaza la tabla
  # `ndt_numbering_profiles` hecha a mano de la Fase 1, administrada ahora
  # vía el motor de catálogos normal, con su propio autómata Activo/
  # Cancelado) a propósito: con politica_reinicio distinto de "nunca", UN
  # perfil tiene VARIOS contadores a lo largo del tiempo (uno por año/mes/
  # día) — cada reinicio es una fila NUEVA acá, nunca una mutación del
  # perfil. Esto también es la unidad de lock real de la concurrencia
  # (NDT.Numbering.next/1 hace SELECT ... FOR UPDATE sobre ESTA fila,
  # nunca sobre el perfil) — dos períodos/dos perfiles distintos jamás
  # contienden entre sí, solo dos solicitudes para el MISMO perfil+período
  # serializan.
  #
  # `periodo` nunca es NULL (columna con default "" para politica "nunca")
  # a propósito — NULL en una unique_index de Postgres no colisiona nunca
  # consigo mismo, así que dos filas "sin período" para el mismo perfil
  # quedarían permitidas si periodo fuera nullable. "" como centinela
  # evita ese problema sin un índice parcial aparte.
  def change do
    create table(:ndt_number_ranges) do
      add :pty_ndt_configuracion_id, references(:pty_ndt_configuracion, on_delete: :restrict), null: false
      add :periodo, :string, size: 10, null: false, default: ""
      add :numero_actual, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ndt_number_ranges, [:pty_ndt_configuracion_id, :periodo], name: :ndt_number_ranges_perfil_periodo_unico_index)
    create constraint(:ndt_number_ranges, :ndt_number_ranges_numero_actual_no_negativo, check: "numero_actual >= 0")
  end
end
