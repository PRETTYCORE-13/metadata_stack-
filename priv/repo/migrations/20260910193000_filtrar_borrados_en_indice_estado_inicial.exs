defmodule MetadataApp.Repo.Migrations.FiltrarBorradosEnIndiceEstadoInicial do
  use Ecto.Migration

  # Bug real (2026-09-10, catálogo "Perfiles de Folio"): el índice único
  # "a lo sumo un estado inicial por catálogo" (ver
  # 20260707221308_crear_meta_schema_estados.exs) solo filtraba
  # `es_inicial = true`, sin `delete_guid IS NULL` -- mismo patrón ya
  # corregido para meta_schema_header_schema_context_name_unico_index
  # (20260909210000). Un estado inicial borrado lógicamente (invisible en
  # la lista de Estados de BC Motor, que sí filtra por delete_guid) seguía
  # bloqueando la creación de uno NUEVO con "ya existe un estado inicial
  # para este catálogo" -- inconsistencia real: la UI decía "todavía no
  # tiene estados" pero el guardado fallaba igual.
  def change do
    drop unique_index(:meta_schema_estados, [:meta_schema_header_id],
           name: :meta_schema_estados_un_inicial_index
         )

    create unique_index(:meta_schema_estados, [:meta_schema_header_id],
             name: :meta_schema_estados_un_inicial_index,
             where: "es_inicial = true AND delete_guid IS NULL"
           )

    # Mismo problema, mismo arreglo: el índice de nombre único por
    # catálogo tampoco filtraba delete_guid -- un estado borrado
    # lógicamente iba a bloquear volver a crear uno con el MISMO nombre
    # (ej. recrear "alta" después de haberlo borrado), aunque no haya
    # pasado todavía en producción (solo hay un estado borrado hoy, ver
    # comentario de arriba).
    drop unique_index(:meta_schema_estados, [:meta_schema_header_id, :nombre],
           name: :meta_schema_estados_unico_index
         )

    create unique_index(:meta_schema_estados, [:meta_schema_header_id, :nombre],
             name: :meta_schema_estados_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
