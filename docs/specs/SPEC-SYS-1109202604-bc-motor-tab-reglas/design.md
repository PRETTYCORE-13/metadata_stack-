# SPEC-SYS-1109202604 — BC Motor: Tab Reglas

**Documento:** Design · **Fase:** ✅ aprobada (2026-09-11).

Documentación retroactiva — `panel_reglas/1` + `bloque_regla/1`
(`bc_motor_live.ex:3122-3213`), `handle_event("reglas_compilar", ...)`
+ `validar_guardar_y_compilar/3` (`bc_motor_live.ex:1569-1603`),
`lib/metadata_app/meta_reglas_codigo.ex` (contexto) y el hook
`AvisoReglasSinGuardar` (`assets/js/app.js:779-815`).

## 1. Disponibilidad (R1-R2)

`compilar_disponible?/0` = `Application.get_env(:metadata_app,
:generar_catalogos_en_caliente, false)` — mismo flag que gatea la
generación de catálogos en caliente en general, no uno propio de
Reglas. `bloque_regla/1` usa `readonly={!@compilar_disponible}` sobre
el `<textarea>` y `panel_reglas/1` oculta el botón "Compilar" por
completo (no solo deshabilitado) cuando el flag es falso, mostrando
en su lugar el texto explicativo de R2.

## 2. Origen del código mostrado (R3-R5)

`@reglas` = `%{"pre" => MetaReglasCodigo.obtener(header.id, "pre"),
"post" => MetaReglasCodigo.obtener(header.id, "post")}`, calculado en
`cargar_motor/1` (mismo assign que se recarga después de cualquier
cambio). `bloque_regla/1` resuelve el código a mostrar:

```elixir
codigo = if fila, do: fila.codigo_fuente, else: MetaReglasCodigo.generar_stub(assigns.header, assigns.tipo)
pendiente = String.contains?(codigo, MetaReglasCodigo.marcador_stub())
```

`generar_stub/2` (`meta_reglas_codigo.ex:156-` en adelante) arma el
módulo completo con el nombre por convención
(`Reglas.modulo_pre/1`/`modulo_post/1`) y el `@behaviour` correcto
(`MetaStateEngine.ReglaPre`/`ReglaPost`) ya declarado — el usuario
nunca arranca de un archivo vacío, arranca de un esqueleto que ya
compila. `marcador_stub/0` es un string fijo (ej.
`"#ESCRIBA SU CODIGO AQUÍ"`) que el stub incluye — `pendiente` se
recalcula sobre CUALQUIER código actual (guardado o stub), así que si
alguien guarda código real pero deja el marcador pegado por error,
sigue avisando.

## 3. Guardar y compilar — todo o nada, por bloque (R6-R9)

`handle_event("reglas_compilar", params, socket)` recibe
`codigo_pre`/`codigo_post` del mismo submit y procesa cada tipo por
separado con `validar_guardar_y_compilar/3`:

```elixir
defp validar_guardar_y_compilar(socket, tipo, codigo) do
  with :ok <- MetaReglasCodigo.validar_sintaxis(codigo),
       {:ok, _fila} <- MetaReglasCodigo.guardar(socket.assigns.header, tipo, codigo) do
    socket = push_event(socket, "regla_guardada", %{tipo: tipo})

    case MetaReglasCodigo.compilar(socket.assigns.header, tipo) do
      {:ok, modulo} -> {put_reglas_mensaje(socket, tipo, {:info, "Guardado y compilado: #{inspect(modulo)}."}), true}
      {:error, motivo} -> {put_reglas_mensaje(socket, tipo, {:error, "Se guardó, pero no compiló: #{motivo}"}), true}
    end
  else
    {:error, motivo} -> {put_reglas_mensaje(socket, tipo, {:error, "Error de sintaxis: #{motivo}"}), false}
  end
end
```

`MetaReglasCodigo.validar_sintaxis/1` = `Code.string_to_quoted/1` —
valida que el texto sea Elixir SINTÁCTICAMENTE válido, sin cargarlo
ni ejecutarlo (R7: un error acá NUNCA persiste nada, `with` corta
antes de `guardar/4`). `guardar/4` SIEMPRE persiste si la sintaxis es
válida, incluso si la compilación posterior falla (R8) — son dos
pasos independientes con su propio resultado reportado.

`push_event(socket, "regla_guardada", %{tipo: tipo})` se dispara
ANTES de mirar el resultado de `compilar/2` (comentario explícito en
el código) — el aviso de "cambios sin guardar" del lado cliente tiene
que bajar apenas el texto quedó persistido, no recién si además
compiló limpio.

`Enum.reduce(~w(pre post), {socket, false}, ...)` en el `handle_event`
principal acumula un flag `recargar?` — si CUALQUIERA de los dos
bloques se guardó, `cargar_motor(socket)` recarga TODOS los assigns
al final (no solo `@reglas`) una sola vez, no una recarga por bloque.

## 4. Sincronía guardado vs. compilado (R10)

`MetaReglasCodigo.sincronizado?/2` (`meta_reglas_codigo.ex:265-`)
compara el `codigo_fuente` guardado en base contra el contenido del
archivo `.ex` real en disco (`ruta_disco/2`) — si no coincide (se
guardó pero todavía no se compiló, o el archivo en disco es de una
versión anterior), `bloque_regla/1` calcula `sin_compilar =
@compilar_disponible and not sincronizado?` y muestra el aviso
correspondiente. `nil` (sin fila guardada todavía, sigue siendo el
stub) se considera `true` (sincronizado) — no hay nada guardado que
pueda estar desincronizado.

## 5. Aviso de cambios sin guardar (R11-R12)

`AvisoReglasSinGuardar` (hook por textarea, `data-tipo` = "pre" o
"post"):

- `this.original` arranca en el valor inicial del textarea al montar.
- `beforeunload` — si `this.el.value !== this.original`, cancela el
  cierre/recarga nativo del navegador (`e.preventDefault()` +
  `e.returnValue = ""`, API estándar para forzar el diálogo de
  confirmación del navegador).
- `click` en fase de CAPTURA sobre `document` — si el clic fue sobre
  un link/botón de navegación (`[data-phx-link], [phx-click="change_page"]`)
  que NO está dentro de este mismo textarea, y hay cambios sin
  guardar, pide `window.confirm/1`; si el usuario cancela,
  `stopImmediatePropagation()` frena el evento antes de que LiveView
  o el router lo procesen — la navegación simplemente no ocurre.
- `handleEvent("regla_guardada", ({tipo}) => ...)` — SOLO el hook
  cuyo `data-tipo` coincide con el `tipo` del evento actualiza
  `this.original`; el otro bloque (si seguía con cambios propios sin
  guardar) no se ve afectado por el guardado del primero.

## 6. Utilidad (R13)

Botón "Copiar" — hook genérico `CopiarTextarea` (`data-target` =
id del textarea), reusado tal cual, sin lógica propia de Reglas.

## 7. Fuera de alcance

Igual que `requirements.md` §8.
