# SDD anchored — cómo trabajamos acá

Spec-Driven Development ("anchored"): la especificación es el documento
vivo que **ancla** cada sesión de trabajo con la IA — nunca se le pide
código directo sobre una idea suelta. El flujo es siempre:

```
requirements.md  →  design.md  →  tasks.md  →  implementación
      ↑                                              │
      └──────────────── se vuelve a leer ─────────────┘
```

## Las 3 fases (nunca se saltean, nunca se mezclan)

1. **`requirements.md`** — QUÉ tiene que hacer el sistema, desde la
   perspectiva de quien lo usa. Sin mencionar tablas, módulos ni código.
   Notación EARS (fácil de leer, sin ambigüedad):
   > CUANDO `<evento/condición>` EL SISTEMA DEBE `<comportamiento>`

   Ejemplo real: "CUANDO un administrador da de baja un perfil de
   numeración, EL SISTEMA DEBE dejar de asignarlo en futuras
   solicitudes, sin borrar su historial de folios ya asignados."

2. **`design.md`** — CÓMO se resuelve lo de arriba. Acá sí entran
   decisiones técnicas: modelo de datos, módulos, algoritmos,
   diagramas. Se escribe DESPUÉS de que `requirements.md` está
   aprobado — nunca antes, nunca en paralelo ("spec pura": una fase
   cierra antes de abrir la siguiente).

3. **`tasks.md`** — la lista de pasos concretos e incrementales para
   construir el diseño, cada uno chico y verificable (compila, corre,
   un test pasa). Es el ÚNICO documento contra el que se pide código.

## Regla de oro

Cuando le pidas a la IA que implemente algo, la instrucción siempre
es: **"segui `tasks.md`, tarea N"** — no "hacé X" suelto. Si mientras
implementás aparece algo que el spec no contemplaba, se vuelve a
`requirements.md`/`design.md` primero, se actualiza, y recién después
se sigue con `tasks.md`. El código nunca es la fuente de verdad — el
spec sí. Por eso "anchored": todo se ancla ahí, nunca deriva solo.

## Convención de nombres

Cada spec vive en su propia carpeta, identificada por un código único:

```
SPEC-<ÁREA>-<DDMMAAAA><secuencia>-<slug-corto>
```

`<ÁREA>` agrupa por dominio (`SYS` = plataforma/sistema; se suman más
según haga falta). `<secuencia>` es el número de spec ABIERTA ese día
en esa área (01, 02, ...) — permite más de una por día sin colisión.

## Features documentadas acá

- [`SPEC-SYS-0109202601-administrador-folios/`](SPEC-SYS-0109202601-administrador-folios/) —
  motor de folios de negocio para documentos transaccionales
  (implementado, Grupos A-G completos).
- [`SPEC-API-0409202601-autenticacion-movil/`](SPEC-API-0409202601-autenticacion-movil/) —
  autenticación por token (access+refresh) para que la app Flutter
  autentique contra los mismos usuarios de metadata_stack, sin cookie
  de sesión web (implementado, Grupos A-G completos; `design.md` §4 es
  el contrato de API para el cliente Flutter).
