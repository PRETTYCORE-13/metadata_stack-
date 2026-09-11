# SPEC-SYS-1109202604 — BC Motor: Tab Reglas

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-11) — documentación retroactiva, sin cambios de código.

**Alcance de esta spec**: documentar (retroactivo, ya implementado)
el tab **"Reglas"** de `BcMotorLive` — edición del código fuente
Elixir de las reglas de negocio PRE (antes de aplicar una transición)
y POST (después de aplicarla) de un catálogo, con guardado +
compilación en caliente en dev/test. Cuarta spec del módulo BC Motor
(mismo prefijo "BC Motor", ver `SPEC-SYS-1109202601`).

## 1. Disponibilidad según ambiente

R1. EL SISTEMA DEBE ofrecer edición real (textarea editable + botón
"Compilar") únicamente cuando `compilar_disponible?/0`
(`generar_catalogos_en_caliente`) está activo — en la práctica,
solo dev/test.

R2. CUANDO la edición no está disponible (producción), EL SISTEMA
DEBE mostrar el código guardado en modo SOLO LECTURA, con el texto
"Edición solo disponible en dev/test — en producción se llega a
través de git + release, no desde esta pantalla" — nunca un tab
vacío ni un error.

## 2. PRE y POST como dos bloques independientes

R3. EL SISTEMA DEBE mostrar PRE ("antes de aplicar la transición, el
primer error frena todo") y POST ("después de aplicar la transición,
si falla se deshace todo") como dos sub-tabs propios dentro de
Reglas, cada uno con su propio textarea — un solo `<form>` los
envuelve a los dos, pero se editan y guardan de forma independiente.

## 3. Código inicial (stub)

R4. CUANDO un catálogo todavía no tiene código PRE (o POST) guardado,
EL SISTEMA DEBE mostrar un stub generado automáticamente (módulo con
el nombre por convención correcto, comportamiento neutro) en vez de
un textarea vacío — punto de partida ejecutable, no una plantilla en
blanco.

R5. CUANDO el código actual (guardado o el stub) todavía contiene el
marcador de "sin completar", EL SISTEMA DEBE avisarlo en texto
visible junto al textarea — señal de que ese bloque nunca fue tocado
de verdad, no que ya está listo para producción.

## 4. Guardar y compilar (una sola acción)

R6. EL SISTEMA DEBE ofrecer un único botón "Compilar" que aplica a
PRE y POST juntos en el mismo submit — no hay acciones separadas de
"Validar sintaxis"/"Guardar"/"Publicar": compilar YA incluye validar
y guardar.

R7. CUANDO el código de un bloque tiene un error de sintaxis, EL
SISTEMA DEBE rechazar ese bloque SIN persistir nada (ni guardar ni
compilar) y mostrar el error de sintaxis con su línea — el otro
bloque (PRE si falló POST, o viceversa) se procesa de forma
completamente independiente, un error en uno no bloquea al otro.

R8. CUANDO el código de un bloque pasa la validación de sintaxis, EL
SISTEMA DEBE guardarlo SIEMPRE (persistido en base), y a continuación
intentar compilarlo — si la compilación falla (error semántico, no
de sintaxis), el mensaje aclara explícitamente "se guardó, pero no
compiló" en vez de dar a entender que nada pasó.

R9. "Publicar" (el commit real de las reglas hacia otros ambientes)
NO es una acción de este tab — corre por `mix motor.publicar
<catalogo>` (que ya incluye la carpeta de reglas completa) o el flujo
normal de git + CI/CD.

## 5. Sincronía guardado vs. compilado

R10. CUANDO el código guardado en base es distinto del que está
compilado y cargado en el BEAM ahora mismo, EL SISTEMA DEBE avisarlo
("Guardado sin compilar — el motor corre la versión anterior") — un
`Repo.update` exitoso no implica que la lógica de negocio ya cambió
en producción real.

## 6. Aviso de cambios sin guardar

R11. CUANDO un usuario editó un textarea de regla y todavía no lo
guardó (valor actual ≠ último valor confirmado por el servidor como
guardado), EL SISTEMA DEBE advertir antes de perder ese cambio en dos
situaciones: intentar cerrar/recargar la pestaña del navegador, o
hacer clic en cualquier link/botón de navegación dentro de la propia
app (cambiar de página vía `change_page` o cualquier link con
`data-phx-link`) — en ambos casos, cancelable por el usuario.

R12. EL "último valor confirmado como guardado" (R11) DEBE
actualizarse recién cuando el servidor confirma que ESE tipo (pre o
post) se guardó de verdad — un intento que falló por error de
sintaxis nunca cuenta como guardado, sigue marcado como pendiente
aunque el usuario haya hecho clic en "Compilar".

## 7. Utilidad

R13. EL SISTEMA DEBE ofrecer un botón "Copiar" junto a cada textarea
que copia el código completo de ese bloque al portapapeles.

## 8. Fuera de alcance de esta spec

- El mecanismo de convención de nombres de módulo
  (`Reglas.modulo_pre/1`/`modulo_post/1`) y cómo el motor de estados
  despacha a estas reglas en cada transición real — comportamiento
  del motor, no de este tab de edición.
- El botón "Compila Todo" de la cabecera del BC Motor (recompila
  tabla + reglas de una) — acción global del LiveView, no específica
  de este tab.
