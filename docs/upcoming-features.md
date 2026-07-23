# Upcoming Features — roadmap de PrettyCore / BPB

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

## 7 — Deploy de BC hechos por ADN

Mismo pendiente ya abierto en la limpieza de Git/CI-CD de hoy — ver memoria de proyecto `project_git_cicd_pty_cleanup` (equivalente a `docs/ci-cd-deploy.md` + esta sesión): falta el mecanismo real para que un BC construido localmente por ADN con el BPB llegue a Linux Trixie (producción simulada) **sin** pasar por el repo git compartido. Candidato a explorar: adaptar `mix motor.publicar` (hoy publica el JSON de un catálogo a git) hacia un flujo de publicación directa a producción en vez de a git.

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
