# Roadmap — PrettyCore / BPB

Lista de funcionalidades pedidas por el usuario para más adelante — **ninguna está diseñada ni iniciada todavía**. No es un compromiso de orden ni de fecha, es el backlog para no perder de vista qué falta cuando se retome cada tema. Cada entrada dice qué se pidió, qué relación tiene con lo que ya existe (si la hay), y qué queda por decidir antes de poder empezar.

Agregado 2026-07-23.

## 1 — Módulo/script para que cada dev limpie su propia base local

Un mix task o módulo para que cada desarrollador (Liz, Jesus, Uriel) pueda dejar su Postgres local en un estado limpio antes de arrancar a trabajar — crear la base si no existe, crear solo las tablas core `meta_schema_*` (BPB), y parametrizar host/usuario/contraseña/nombre de base para "modo Developer". Surgió porque `git pull` limpia el repo de `pty_*` (ver [[#7]] y la limpieza de Git/CI-CD de esta sesión), pero **no** la base de datos local de cada uno — si alguien tiene tablas `pty_*` de pruebas viejas en su Postgres, `git pull` no las toca. Mismo pendiente que ya está anotado en la memoria de proyecto `project_modulo_setup_dev_db` — no iniciar hasta que se pida explícitamente.

## 2 — Motor de roles y permisos (RBAC)

**Norte**: cuando se construya esto, tiene que ser un **RBAC** real (Role-Based Access Control) — roles con permisos asignados, usuarios con uno o más roles, chequeo de "¿este usuario puede hacer X?" resuelto por rol, no por usuario suelto ni hardcodeado por catálogo.

Hoy existe solo un stub mínimo: `MetadataApp.MetaPermissions.can?/3`, que chequea `requiere_rol` contra `contexto["rol"]`/`["roles"]` pasado a mano en cada request — no hay sesión, usuario autenticado, ni tabla de roles/permisos real detrás. Ya estaba marcado como fuera de alcance explícito en `docs/compliance-pty.md`. Depende de que exista primero [[#3]] (no hay "rol de quién" sin login).

**Ya preparado para ese día** (agregado 2026-07-23, sin esperar a este ítem): `MetaPermissions.can?/3` es a propósito el ÚNICO punto de integración que usa el motor — el día que exista RBAC real, se reemplaza esa implementación sin tocar nada más. Además, `{:error, :sin_permiso, mensaje}` (ver `MetadataApp.MetaStateEngine.ReglaPre`) ya es un mecanismo genérico de "ocultar por completo, no solo deshabilitar" — la regla `requiere_rol` ya lo usa hoy con el rol genérico de `contexto`, y cualquier chequeo de RBAC futuro (por permiso, no solo por rol) puede devolver la misma forma sin cambiar el motor de estados.

## 3 — Tenancy, Login y password de la plataforma

No existe ningún mecanismo de autenticación ni de multi-tenant todavía — toda la plataforma se opera hoy sin sesión (Postman/API directa, o LiveView sin usuario identificado). Es la base de la que dependen [[#2]] y [[#6]].

## 4 — BC de tipo Kardex, tablas tipo datamart, tablas temporales

Hoy el generador (`CatalogoGenerador`) solo conoce dos formas de catálogo: genérico simple y maestro-detalle (ver `docs/catalogo-maestro-detalle-requerimientos.md`). Estos son arquetipos nuevos de Business Context, con semántica propia:
- **Kardex**: tabla de movimientos tipo libro mayor/inventario (saldo corrido, nunca se edita un renglón ya escrito, solo se agregan movimientos).
- **Datamart**: tablas analíticas/agregadas, pensadas para lectura y reporting, no para el ciclo transaccional normal.
- **Tablas temporales**: de trabajo/staging, con ciclo de vida corto, no pensadas para persistir como el resto de los catálogos.

Falta decidir si cada uno es un modo nuevo del mismo generador o un generador aparte.

## 5 — Jobs

Procesamiento en background — falta decidir la herramienta "lo más nativo que convenga para Elixir" (candidato natural dado que el stack ya corre sobre Postgres: algo tipo Oban, respaldado en la misma base, sin infraestructura nueva que mantener — pero es una decisión a evaluar, no tomada todavía).

## 6 — Log detallado de auditoría (quién/cuándo/desde dónde)

Hoy cada catálogo generado graba `insert_guid`/`update_guid`/`delete_guid` (un GUID por operación, ver `docs/arquitectura-bpb.md`), pero **no** quién la hizo. Se pide una tabla de auditoría (`record` o similar) que capture, por cada GUID: usuario, hora, IP, MAC, nombre de la PC, sesión. Depende de [[#3]] — sin login no hay "usuario" que registrar.

## 7 — Deploy de BC hechos por ADN ✅ implementado (2026-07-23)

`mix motor.publicar <catalogo>` ya no commitea a git — dispara `.github/workflows/bc-deploy.yml`, un workflow dedicado que arma la imagen de producción con el BC embebido y la despliega, **sin que `origin/main` se entere de que ese BC existió** (ni un `git add`, ni commit, ni push en ningún paso). Detalle técnico completo en `docs/ci-cd-deploy.md`.

Elegido sobre la alternativa de hot code loading (compilar en la laptop de ADN y cargar los `.beam` directo en el nodo BEAM vivo, sin rebuild) por seguridad (imagen inmutable con SHA vs. carga de código sin artefacto auditable), escalabilidad (Swarm con más de una réplica no necesita nada especial) y simplicidad (reusa el 95% del pipeline de CI ya construido y probado).

## 8 — Campos calculados y campos estéticos en formularios ABC

Para las pantallas de alta/baja/cambio (Frontend, equipo de Liz): dos tipos de campo nuevos que hoy no existen en `schema_context_properties`:
- **Calculados**: su valor se deriva de otros campos, no se captura directo (ej. total = cantidad × precio).
- **Estéticos**: no son datos del catálogo — separadores, texto de ayuda, agrupadores visuales — solo ayudan a organizar el formulario.

## 9 — Campos estéticos o de acompañamiento en el GET

Mismo concepto que [[#8]] pero para el lado de lectura: campos que acompañan la respuesta de `GET /api/:tabla` sin ser columnas reales de la tabla (ej. una etiqueta formateada, un nombre resuelto de una referencia) — parecido a lo que ya hace `estado_nombre` (agregado por `CatalogoGenerico.serializar/2`, ver memoria de proyecto `project_motor_bc_design`) pero como mecanismo general configurable, no un caso especial hardcodeado.

## 10 — Log de errores del sistema

Log técnico de excepciones/errores a nivel plataforma — distinto del log de auditoría de [[#6]] (que es de negocio: quién cambió qué). Sin diseñar todavía: alcance (solo backend o también errores de cliente/LiveView), retención, dónde vive.

## 11 — `MetaErrores`: permitir configurar los mensajes de error

Hoy `MetadataApp.MetaErrores` (agregado 2026-07-23, ver `lib/metadata_app/meta_errores.ex`) centraliza en un solo lugar la traducción de errores de `Ecto.Changeset` a texto — antes esta lógica estaba duplicada en 6 archivos (`fallback_controller`, `catalogo_live`, `bc_list_live`, `bc_nuevo_completo_live`, `bc_motor_live`), cada uno con su propia copia. De paso se corrigió un bug real: `validate_inclusion` (campos `enum`) manda una lista en el dato del error, y `to_string/1` no sabe convertir una lista — antes tiraba `Protocol.UndefinedError` (un 500 real) en vez de mostrar el 422 de siempre.

Los mensajes en español de cada validación (`"no puede quedar vacío"`, `"no es un valor permitido"`, etc., ver `meta_catalogo_generico.ex`) están **hardcodeados** — están bien para el caso de hoy, pero a futuro el usuario quiere poder **exponerlos/tunearlos** (ej. una pantalla admin donde ADN pueda ajustar la redacción de cada mensaje por catálogo o por campo, sin tocar código). Sin diseñar todavía: si es configuración global por tipo de validación, por catálogo, o por campo individual; dónde se guarda (¿tabla nueva, o una propiedad más en `schema_context_properties`?); si un catálogo sin configurar sigue usando los mensajes default de `MetaErrores` (probablemente sí, para no romper nada existente).

## 12 — Transiciones ocultas para el Frontend (uso interno vía reglas)

Poder marcar una transición como **"no mostrar al usuario final"** — sigue siendo una transición real y ejecutable (otra regla POST, propia o de otro catálogo, la puede disparar vía `MetaBcCliente.ejecutar_transicion`), pero no tiene que aparecer como botón/opción en ninguna pantalla de Frontend. Caso de uso: una transición "plomería" que solo existe para que la dispare la regla de OTRA transición (o de la misma), nunca pensada para que un humano la clickee directo.

**Ya existe un mecanismo parecido, distinto en el motivo**: `{:error, :sin_permiso, mensaje}` (agregado 2026-07-23, ver ítem 2 de este roadmap) ya oculta una transición del descubrimiento (`MetaStateEngine.transiciones_disponibles/2`) — pero es una ocultación *condicional*, evaluada en cada request según el `contexto` (falla de rol/permiso). Esto es distinto: una marca **fija** en la transición misma (ej. un campo nuevo en `meta_schema_transiciones`, algo como `solo_interna: boolean`), sin depender de evaluar nada — se oculta siempre del descubrimiento, para cualquiera.

Sin diseñar todavía: si además de ocultarla del descubrimiento (`GET .../transiciones`) hay que bloquear también el `POST .../transiciones/:accion` directo desde afuera (para que la única forma de dispararla sea vía regla, nunca por un cliente HTTP que se sepa el nombre de la acción) — son dos decisiones distintas (visibilidad vs. quién puede ejecutarla).

## 13 — Log de quién crea/modifica/borra la DEFINICIÓN de cada motor (BC) hecho por ADN

Distinto del ítem 6 (que es sobre **datos** — quién cambió un registro de negocio): esto es sobre la **definición** del catálogo mismo — campos, estados, transiciones, reglas. Por cada motor que arma ADN con el BPB, un log con: GUID, usuario que lo creó, usuario que lo actualizó (y cuándo), usuario que lo borró (y cuándo), fecha de cada cambio, y qué cambió puntualmente. Depende de [[#3]] — sin login no hay "usuario de ADN" que registrar, mismo motivo que el ítem 6.
