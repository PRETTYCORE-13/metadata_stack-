# Carga de códigos postales del SAT

Carga el catálogo `pty_sat_codigopostal` (SPEC-ADN-0710202602, diseño
D10 y §6.1). Se corre una vez por ambiente, después de publicar el
catálogo, y otra vez cada que el SAT publique una versión nueva.

## Origen de `codigos_postales.csv`

- Archivo del SAT: `catCFDI_V_4_20260302.xls`, de
  `http://omawww.sat.gob.mx/tramitesyservicios/Paginas/documentos/`.
- Hojas `c_CodigoPostal_Parte_1` y `c_CodigoPostal_Parte_2` (revisión 8,
  publicada el 22/01/2026), datos desde la fila 8, columnas A a G.
- 95,748 códigos postales. La columna `estimulo` viene como la publica
  el SAT: 0 = sin estímulo, 1 = región fronteriza norte, 2 = región
  fronteriza sur. El script guarda 1 y 2 como "sí".
- La última fila de la parte 1 es una nota del SAT ("Continúa en
  c_CodigoPostal_2"); el script la descarta.

## Cómo correrlo

Desde esta carpeta (el `\copy` lee el CSV de la carpeta actual):

```
psql "<conexión a la base del ambiente>" -f cargar_codigos_postales.sql
```

El script falla sin tocar nada si el catálogo todavía no está publicado
en ese ambiente. Al terminar muestra cuántos dio de alta, cuántos
actualizó y el total.

## Cuando el SAT publique una versión nueva

1. Descargar el `catCFDI_V_4_<fecha>.xls` vigente.
2. Abrirlo en Excel (sin habilitar macros) y copiar de las dos hojas de
   códigos postales, desde la fila 8, las columnas A a E y G a un CSV
   con el encabezado `clave,estado,municipio,localidad,estimulo,fin_vigencia`.
   Las claves, municipios y localidades llevan ceros a la izquierda
   (01000, 001, 01): si Excel los muestra como número, hay que
   rellenarlos.
3. Reemplazar `codigos_postales.csv`, actualizar esta sección de origen y
   volver a correr el script en cada ambiente.

El script no da de baja los códigos postales que el SAT quite: hoy
ninguno tiene fin de vigencia; si llega a pasar, se decide en ese
momento.
