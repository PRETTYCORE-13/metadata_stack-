# SPEC-SYS-0909202602 — Demo: Gestión de Perros

**Documento:** Requirements · **Fase:** 🔵 en revisión.

**Propósito**: spec de práctica — dar de alta un Business Context (BC)
nuevo con el Motor BC, de punta a punta (`requirements.md` →
`design.md` → `tasks.md` → implementación real), para ejercitar el
mecanismo completo tal como lo usaría el equipo de Lógica de Negocio:
BPB local (schema + campos) + motor de estados (vía Sysadmin) →
publicar. Sin atajos ni datos armados a mano por fuera del mecanismo
real. No es un catálogo pedido por ningún cliente — es un ejercicio.

## 1. Qué es

Un catálogo maestro **Perros**, cada registro es un perro dado de alta
con sus datos básicos, con motor de estados propio (Activo/Baja) — pero
**sin catálogos detalle** (a diferencia de, por ejemplo,
`pty_dsd_mat_material` con sus detalles de gamas/precios): un solo
nivel, ningún catálogo hijo. "Simple" se refiere a esto, no a que le
falte proceso — SÍ tiene estados y transiciones reales.

## 2. Campos

R1. EL SISTEMA DEBE requerir **Nombre** (texto) en todo alta — no puede
haber un perro sin nombre.

R2. EL SISTEMA DEBE requerir **Raza** (texto) en todo alta.

R3. EL SISTEMA DEBE permitir capturar **Edad promedio** (numérico, en
años) — opcional, un perro puede darse de alta sin edad conocida.

R4. EL SISTEMA DEBE permitir capturar **Observaciones de vacunas**
(texto largo, multilínea) — opcional, para anotar qué vacunas tiene
aplicadas o cualquier nota relevante de salud.

R5. EL SISTEMA DEBE permitir capturar **Nombre del dueño** (texto,
máximo 200 caracteres) — opcional, nombre completo de quien es
responsable del perro.

## 3. Estados y transiciones

R6. CUANDO se da de alta un perro nuevo, EL SISTEMA DEBE registrarlo en
estado **Activo**.

R7. CUANDO un usuario con permiso da de baja un perro **Activo**, EL
SISTEMA DEBE pasarlo a estado **Baja** — sin borrar el registro (queda
fuera de operación normal, pero su historial permanece).

R8. CUANDO un usuario con permiso reactiva un perro en estado **Baja**,
EL SISTEMA DEBE volverlo a estado **Activo**.

## 4. Operación (igual que cualquier catálogo maestro del sistema)

R9. CUANDO un usuario tiene permiso de "leer" sobre Perros, EL SISTEMA
DEBE mostrarle el catálogo en su menú de navegación (framework ya
documentado en `SPEC-SYS-0909202601-framework-navegacion`).

R10. CUANDO un usuario tiene permiso sobre una transición puntual (alta,
dar de baja, reactivar), EL SISTEMA DEBE permitirle ejecutarla — mismo
modelo RBAC por transición que cualquier otro catálogo con motor de
estados (no un genérico "editar", uno por transición).

## 5. Fuera de alcance

- Catálogos detalle (ej. una tabla propia de "vacunas" con fecha/tipo,
  en vez de texto libre en observaciones) — ver §1, es justo lo que
  hace a esta demo "simple". Si más adelante hace falta, es una
  extensión nueva de esta misma spec (se vuelve a `requirements.md`
  primero).
- A qué sistema(s) se publica — se queda en modo developer, no se
  publica a ningún sistema real (unstable/cliente); es una decisión
  operativa del ejercicio, no un requisito de comportamiento, se
  confirma en `tasks.md`.
