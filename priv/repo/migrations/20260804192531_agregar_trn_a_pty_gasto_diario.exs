defmodule MetadataApp.Repo.Migrations.AgregarTrnAPtyGastoDiario do
  use Ecto.Migration

  # Backfill puntual para producción: pty_gasto_diario se marcó
  # schema_es_transaccional: true en dev (codigo_trn "GS01") DESPUÉS de
  # haber sido publicado a producción por primera vez sin ese flag —
  # publicar de nuevo no lo hubiera corregido solo (ver
  # MetaImportExport.importar_contexto/1: para un header que YA existe,
  # solo resincroniza ícono y campos nuevos, nunca schema_es_transaccional
  # ni codigo_trn). Esta migración hace a mano lo que
  # CatalogoGenerador.asegurar_trn/3 ya hace en dev cada vez que se
  # regenera el catálogo (mismo SQL, mismo criterio IF NOT EXISTS/
  # idempotente) + el UPDATE del header que ningún otro mecanismo cubre.
  #
  # Sin pérdida de datos: trn/ulid quedan NULL en las filas ya existentes
  # (no hay forma de generarles un TRN retroactivo con sentido) — la
  # garantía de "todo alta nueva tiene TRN" es de aplicación
  # (MetadataApp.TRN.asignar_si_transaccional/1 en cada create), no de
  # constraint de base, mismo criterio documentado en asegurar_trn/3.
  # Guard agregado (2026-09-04, SPEC-SYS-0309202601, auditoría de replay
  # desde cero): `pty_gasto_diario` ya no existe en el schema final --se
  # borró en algún punto posterior de la historia real-- así que un
  # sistema nuevo que reproduce las migraciones desde cero rompe acá
  # (`relation "pty_gasto_diario" does not exist`) aunque cualquier
  # sistema YA migrado (donde la tabla SÍ existía en ese momento real)
  # nunca vuelve a correr esto -- Ecto marca por versión, no por
  # contenido. Verificado real contra dev (2026-09-04):
  # `to_regclass('pty_gasto_diario')` da NULL. Sin este guard, ningún
  # sistema nuevo puede terminar de migrar.
  def up do
    if Ecto.Migration.repo().query!("SELECT to_regclass('pty_gasto_diario')").rows == [[nil]] do
      :ok
    else
      execute "ALTER TABLE pty_gasto_diario ADD COLUMN IF NOT EXISTS trn varchar(23)"
      execute "CREATE UNIQUE INDEX IF NOT EXISTS pty_gasto_diario_trn_unico_index ON pty_gasto_diario (trn) WHERE trn IS NOT NULL"

      execute "ALTER TABLE pty_gasto_diario ADD COLUMN IF NOT EXISTS ulid varchar(26)"
      execute "CREATE UNIQUE INDEX IF NOT EXISTS pty_gasto_diario_ulid_unico_index ON pty_gasto_diario (ulid) WHERE ulid IS NOT NULL"

      execute """
      UPDATE meta_schema_header
      SET schema_es_transaccional = true, codigo_trn = 'GS01'
      WHERE schema_context_name = 'pty_gasto_diario' AND schema_es_transaccional = false
      """
    end
  end

  # No hay forma segura de "adivinar" si codigo_trn/schema_es_transaccional
  # ya estaban así antes de este backfill (no versionamos ese estado
  # previo) — down intencionalmente no revierte el UPDATE del header, solo
  # las columnas, para no arriesgar pisar una configuración manual hecha
  # después de este deploy.
  def down do
    execute "DROP INDEX IF EXISTS pty_gasto_diario_ulid_unico_index"
    execute "ALTER TABLE pty_gasto_diario DROP COLUMN IF EXISTS ulid"

    execute "DROP INDEX IF EXISTS pty_gasto_diario_trn_unico_index"
    execute "ALTER TABLE pty_gasto_diario DROP COLUMN IF EXISTS trn"
  end
end
