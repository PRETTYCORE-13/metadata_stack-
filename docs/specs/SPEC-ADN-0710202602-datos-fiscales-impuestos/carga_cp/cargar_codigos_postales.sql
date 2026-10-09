-- SPEC-ADN-0710202602 §6.1: carga del catálogo de códigos postales del SAT
-- (pty_sat_codigopostal) desde codigos_postales.csv.
--
-- Uso, desde esta carpeta y con el catálogo ya publicado en el ambiente:
--   psql "<conexión a la base del ambiente>" -f cargar_codigos_postales.sql
--
-- Da de alta los CP nuevos y actualiza los que cambiaron; se puede volver a
-- correr con una versión nueva del CSV. Todo o nada: una sola transacción.

\set ON_ERROR_STOP on

BEGIN;

-- 1. El catálogo y su estado Activo tienen que existir en este ambiente.
CREATE TEMP TABLE cp_estado_activo ON COMMIT DROP AS
SELECT e.id
  FROM meta_schema_estados e
  JOIN meta_schema_header h ON h.id = e.meta_schema_header_id
 WHERE h.schema_context_name = 'pty_sat_codigopostal'
   AND h.delete_guid IS NULL
   AND e.nombre = 'Activo'
   AND e.delete_guid IS NULL;

DO $$
BEGIN
  IF (SELECT count(*) FROM cp_estado_activo) <> 1 THEN
    RAISE EXCEPTION 'El catálogo pty_sat_codigopostal o su estado Activo no existen en este ambiente: publícalo antes de cargar.';
  END IF;
END
$$;

-- 2. El CSV tal cual viene del SAT (ver LEEME.md).
CREATE TEMP TABLE cp_sat (
  clave text,
  estado text,
  municipio text,
  localidad text,
  estimulo text,
  fin_vigencia text
) ON COMMIT DROP;

\copy cp_sat FROM 'codigos_postales.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- 3 y 4. Solo claves de 5 dígitos (descarta la fila de nota del SAT).
-- Estímulo: 1 = región fronteriza norte, 2 = región fronteriza sur.
WITH datos AS (
  SELECT clave,
         estado,
         NULLIF(municipio, '') AS municipio,
         NULLIF(localidad, '') AS localidad,
         estimulo IN ('1', '2') AS estimulo_frontera
    FROM cp_sat
   WHERE clave ~ '^[0-9]{5}$'
),
cargados AS (
  -- 5. Mismos datos de control que un alta del motor.
  INSERT INTO pty_sat_codigopostal AS cp (
    pty_sat_codigopostal_clave,
    pty_sat_codigopostal_estado,
    pty_sat_codigopostal_municipio,
    pty_sat_codigopostal_localidad,
    pty_sat_codigopostal_estimulo_frontera,
    insert_guid,
    estado_id,
    fecha_registro
  )
  SELECT d.clave, d.estado, d.municipio, d.localidad, d.estimulo_frontera,
         replace(gen_random_uuid()::text, '-', ''),
         (SELECT id FROM cp_estado_activo),
         date_trunc('second', now() AT TIME ZONE 'UTC')
    FROM datos d
  ON CONFLICT (pty_sat_codigopostal_clave) WHERE delete_guid IS NULL
  DO UPDATE SET
    pty_sat_codigopostal_estado = EXCLUDED.pty_sat_codigopostal_estado,
    pty_sat_codigopostal_municipio = EXCLUDED.pty_sat_codigopostal_municipio,
    pty_sat_codigopostal_localidad = EXCLUDED.pty_sat_codigopostal_localidad,
    pty_sat_codigopostal_estimulo_frontera = EXCLUDED.pty_sat_codigopostal_estimulo_frontera,
    update_guid = replace(gen_random_uuid()::text, '-', '')
  WHERE (cp.pty_sat_codigopostal_estado, cp.pty_sat_codigopostal_municipio,
         cp.pty_sat_codigopostal_localidad, cp.pty_sat_codigopostal_estimulo_frontera)
        IS DISTINCT FROM
        (EXCLUDED.pty_sat_codigopostal_estado, EXCLUDED.pty_sat_codigopostal_municipio,
         EXCLUDED.pty_sat_codigopostal_localidad, EXCLUDED.pty_sat_codigopostal_estimulo_frontera)
  RETURNING (xmax = 0) AS nuevo
)
-- 6. Resumen.
SELECT count(*) FILTER (WHERE nuevo) AS dados_de_alta,
       count(*) FILTER (WHERE NOT nuevo) AS actualizados,
       (SELECT count(*) FROM datos) AS en_el_archivo
  FROM cargados;

COMMIT;

SELECT count(*) AS total_vivos,
       count(*) FILTER (WHERE pty_sat_codigopostal_estimulo_frontera) AS con_estimulo
  FROM pty_sat_codigopostal
 WHERE delete_guid IS NULL;
