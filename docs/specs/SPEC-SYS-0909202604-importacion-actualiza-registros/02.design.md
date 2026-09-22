# Design — La importación por Excel también actualiza registros existentes

## Resumen del enfoque

Toda la lógica nueva reusa mecanismos que ya existen y ya están
probados (los mismos que usa `FichaLive` para la edición manual) — esta
spec no inventa un camino nuevo de escritura, solo hace que la
importación entre por las puertas que ya existen, fila por fila, en vez
de solo por `CatalogoGenerico.crear/4`.

Piezas existentes que se reusan tal cual:

| Operación | Función que ya existe |
|---|---|
| Crear encabezado + renglones iniciales (sin cambios) | `CatalogoGenerico.crear/4` (con `opciones[:renglones]`) |
| Actualizar campos de un encabezado existente | `CatalogoGenerico.actualizar/4` |
| Actualizar campos de un renglón YA existente (junto con el encabezado, atómico) | `MetaStateEngine.ejecutar_transicion/4` (con `opciones[:renglones]`) |
| Agregar un renglón NUEVO a un encabezado ya existente | `MetadataApp.Renglones.crear_todos/3` (genérico: solo necesita un `registro_id`, sea de un encabezado nuevo o ya existente) |
| Sacar la transición "Guardar" de un catálogo | `MetaStateEngine.transicion_guardar/2` |

## 1. Modelo de datos — `PlantillaImportacion.definicion`

Un solo agregado al jsonb ya existente: cada entrada de `"detalles"`
suma `"campo_identificador"` (mismo shape que
`"campo_identificador_encabezado"`, pero a nivel de ese catálogo
detalle):

```jsonc
{
  "campos": [...],
  "campo_identificador_encabezado": "pty_x_folio",     // ya existe
  "detalles": [
    {
      "catalogo": "pty_x_renglones",
      "activo": true,
      "campos": [...],
      "campo_identificador": "pty_x_sku"               // NUEVO
    }
  ]
}
```

`nil`/ausente en cualquiera de los dos identificadores = comportamiento
100% igual al actual (R5, R7.4) — el jsonb existente en plantillas ya
guardadas sigue siendo válido sin migración de datos.

## 2. Asistente (`ImportacionConstructorLive`) — cambios de UI

- **Paso 2 ("Detalles")**: el selector "Campo identificador del
  encabezado" deja de estar condicionado a `detalles != []` — se
  muestra siempre, con la etiqueta ampliada ("vincula las hojas de
  detalle y permite actualizar en vez de crear duplicados") y sigue
  siendo opcional.
- Cada detalle activado suma su propio selector "Campo identificador de
  este detalle" (opcional), poblado con `campos_disponibles(catalogo)`
  de ESE catálogo — mismo patrón que ya existe para
  `campo_identificador` de un campo tipo referencia.
- **Validación nueva** (`validar_detalles/1`): si se configura un
  identificador (de encabezado o de un detalle), ESE campo tiene que
  estar entre los campos incluidos de su propia hoja — si no, el Excel
  generado nunca tendría esa columna para leer de vuelta. Esto ya era
  una condición implícita para que el vínculo encabezado↔detalle
  funcionara; queda validada explícitamente ahora que también hace
  falta para poder buscar el registro a actualizar.

## 3. Búsqueda de un registro existente — `MetaImportacionDatos`

Dos funciones nuevas, mismo criterio de "coincidencia exacta" que ya
usa `resolver_referencia/3` en este mismo módulo — a diferencia de esa,
acá "cero coincidencias" es un resultado válido (alta), no un error:

```elixir
defp buscar_existente(modulo, campo_atom, valor) do
  case Repo.all(from r in modulo,
         where: field(r, ^campo_atom) == ^valor and is_nil(r.delete_guid)) do
    []          -> {:ok, nil}
    [registro]  -> {:ok, registro}
    _varios     -> {:error, :identificador_ambiguo}
  end
end

defp buscar_renglon_existente(modulo_detalle, encabezado_id, campo_atom, valor) do
  # mismo shape, con el WHERE adicional encabezado_id: encabezado_id
end
```

## 4. Flujo por fila de encabezado (`procesar_fila`/`procesar_filas`)

Reemplaza el `CatalogoGenerico.crear/4` incondicional de hoy por una
bifurcación, evaluada ANTES de construir nada, apenas se conoce
`valor_identificador`:

```
plantilla sin campo_identificador_encabezado
  → comportamiento actual, sin cambios (siempre alta)

plantilla CON campo_identificador_encabezado:
  buscar_existente(modulo, campo_atom, valor) ->
    {:error, :identificador_ambiguo} -> fila rechazada (R4)
    {:ok, nil}                       -> ALTA (camino actual, sin cambios)
    {:ok, registro_existente}        -> ACTUALIZACIÓN (nuevo, ver 4.1)
```

### 4.1 Camino de actualización

Primero, para CADA catálogo detalle activo, particionar sus filas
(ya agrupadas por Folio, como hoy) contra `registro_existente.id`:

```
para cada fila de detalle de ese catálogo:
  si el detalle no tiene campo_identificador -> bucket "nuevo" (R7.4)
  si lo tiene:
    buscar_renglon_existente(modulo_detalle, registro_existente.id, campo, valor) ->
      {:error, :identificador_ambiguo} -> fila de detalle rechazada (R7.5)
      {:ok, nil}                       -> bucket "nuevo"
      {:ok, renglon}                   -> bucket "editar" (guarda renglon_id)
```

Con los buckets armados, TODO lo de abajo corre dentro de un mismo
`Repo.transaction/1` (mismo criterio atómico de siempre: si algo falla,
esa fila de encabezado entera se rechaza, sin abortar las demás filas
del archivo):

- **Si el bucket "editar" de CUALQUIER detalle no está vacío:**
  primero `MetaStateEngine.transicion_guardar(catalogo, registro_existente.estado_id)`.
  - `nil` → toda la fila se rechaza: `{:error, {:renglon_sin_guardar, catalogo}}` (R10/R11).
  - transición real → `MetaStateEngine.ejecutar_transicion(registro_existente, transicion.accion, attrs_encabezado, renglones: renglones_editados)`, con `renglones_editados` en el shape que ese motor ya espera (`%{"catalogo" => [%{"renglon_id" => id, "<campo>" => valor, ...}, ...]}`). Esto actualiza encabezado Y renglones editados en un solo paso atómico — igual que hace `FichaLive.aplicar_encabezado/6` hoy. Un campo no editable en el estado actual vuelve como error de changeset (R10/R11), traducido con `MetaErrores.traducir/1` de siempre.
- **Si el bucket "editar" está vacío en todos los detalles** (solo hay campos de encabezado y/o renglones nuevos): `CatalogoGenerico.actualizar(registro_existente, scope, attrs_encabezado)` para el encabezado (si `attrs_encabezado` no está vacío) — mismo criterio de "no editable" que ya aplica a mano.
- **En cualquiera de los dos casos**, después, el bucket "nuevo" de cada detalle se resuelve con `MetadataApp.Renglones.crear_todos(catalogo_maestro, registro_existente.id, renglones_nuevos_spec)` — no depende de "Guardar" (R12).

## 5. Resultado de cada fila (previsualización y ejecución)

`procesar_filas/4` hoy devuelve `%{fila:, resultado: :ok | :error, registro:, errores:}`. Se agrega una clave `:accion` (`:crear` | `:actualizar`) a las filas `:ok`, resuelta en el paso 4 de arriba (si `buscar_existente` devolvió `nil` → `:crear`, si no → `:actualizar`). `previsualizar/3` y `ejecutar/3` siguen siendo exactamente la misma función por dentro (la única diferencia sigue siendo rollback vs commit) — ninguna lógica nueva se duplica entre las dos.

## 6. UI del modal de importación (`catalogo_live.ex`)

`resultado_importar/1` (el componente de la pantalla "Revisar") separa
el conteo único actual ("N listos para importar") en dos, usando la
nueva clave `:accion`:

```
✓ N a crear
↻ M a actualizar
⚠ E con error
```

El CTA final se ajusta a lo que corresponda ("Importar N nuevos y
actualizar M", o el texto que corresponda si alguno de los dos es 0) —
mismo criterio de un solo botón dominante que ya tiene el modal.

## 7. Mensajes de error nuevos (`mensaje_de_motivo/1`, `sugerencia_para/1`)

Dos motivos nuevos, mismo patrón que los ya agregados para Perfil de
Folio:

- `:identificador_ambiguo` → *"Hay más de un registro con ese
  identificador — no se puede determinar cuál actualizar."* Sugerencia:
  apunta a que el valor tiene que ser único para poder actualizar.
- `{:renglon_sin_guardar, catalogo}` → *"Esta fila necesita actualizar
  un renglón de '#{catalogo}' que ya existe, pero el catálogo no tiene
  configurada la transición 'Guardar' — no se puede editar un renglón
  existente sin ella."* Sugerencia: apunta al Motor de Estados del
  catálogo.
- Cualquier error de "campo no editable en el estado actual" ya sale
  traducido por `MetaErrores.traducir/1` desde el changeset que
  devuelven `CatalogoGenerico.actualizar/4` / `ejecutar_transicion/4` —
  no hace falta un caso nuevo, ya cae en la rama existente de errores
  de changeset.

## 8. Fuera de alcance (explícito)

- Borrado masivo de renglones por ausencia en el archivo (R7.3) — no
  se toca `Renglones.eliminar_todos/3` desde import en esta spec.
- Cualquier cambio a `MetaStateEngine`, `CatalogoGenerico` o
  `Renglones` — todo lo de arriba son LLAMADAS a código ya existente,
  cero modificaciones a esos módulos.
- Extender la actualización a algo que no sea filas de Excel (ej. una
  API) — queda acotado al módulo de Importación de Datos.
