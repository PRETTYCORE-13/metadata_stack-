# Arquitectura del motor — árbol de carpetas

Este documento explica **dónde vive cada cosa** dentro de `lib/metadata_app/` y por qué, para poder confirmar de un vistazo que un cambio quedó en el lugar correcto. Es la referencia rápida cuando dudás "¿esto va en BPB o en MetaBusinessProcess?".

## Las tres carpetas que importan

Hay tres dominios separados, cada uno con su propio prefijo de módulo. No se mezclan entre sí:

```
lib/metadata_app/
│
├── business_process_builder/        Namespace: MetadataApp.BusinessProcessBuilder.*
│                                     "BPB" — la HERRAMIENTA que arma catálogos.
│                                     Solo se usa en tiempo de desarrollo (Fase 1).
│                                     Nunca corre en producción: en prod el usuario
│                                     final usa binarios ya armados por el equipo de
│                                     Lógica de Negocio, no esta herramienta.
│
├── meta_business_process/           Namespace: MetadataApp.MetaBusinessProcess.*
│                                     El PRODUCTO — todo lo que el BPB generó o que
│                                     el equipo de negocio construyó dinámicamente
│                                     usándolo: catálogos ya generados, reglas de
│                                     negocio (plugins). Esto es lo que sí termina
│                                     en el binario de producción.
│
└── meta_state_engine.ex             Namespace: MetadataApp.MetaStateEngine.*
    meta_state_engine/               El Motor de Estados y Transiciones — un motor
    meta_estados_admin.ex            aparte, independiente del BPB. No genera código:
    meta_bc_cliente.ex               opera sobre datos (meta_schema_estados/
    meta_permissions.ex              transiciones/transicion_reglas), tanto en dev
                                      como en producción.
```

**Regla mental simple:** si un archivo genera o define OTRO catálogo (código Elixir nuevo) → `business_process_builder/`. Si un archivo ES el resultado de esa generación → `meta_business_process/`. Si un archivo mueve un registro de un estado a otro → `meta_state_engine*`/`meta_estados_admin.ex`/`meta_bc_cliente.ex`/`meta_permissions.ex`.

## 1. `business_process_builder/` — la herramienta (BPB)

```
lib/metadata_app/business_process_builder/
├── catalogo_generador.ex        MetadataApp.BusinessProcessBuilder.CatalogoGenerador
│                                 Arma migración + escribe el .ex del catálogo nuevo
│                                 en meta_business_process/catalogos/, corre la migración.
├── catalogo_generico.ex         MetadataApp.BusinessProcessBuilder.CatalogoGenerico
│                                 CRUD genérico (listar/crear/actualizar/eliminar)
│                                 que sirve para CUALQUIER catálogo ya generado.
├── meta_catalogo_generico.ex    MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico
│                                 La macro `use`-able que arma el schema Ecto +
│                                 changeset de cada catálogo generado.
├── meta_schema_context.ex       MetadataApp.BusinessProcessBuilder.MetaSchemaContext
│                                 Acceso a Header/Detail: listar, crear, resolver
│                                 el módulo Ecto de un catálogo por su nombre.
└── meta_schema/
    ├── header.ex                MetadataApp.BusinessProcessBuilder.MetaSchema.Header
    │                             Un registro = un Business Context (catálogo).
    └── detail.ex                MetadataApp.BusinessProcessBuilder.MetaSchema.Detail
                                  Un registro = un campo de ese catálogo.
```

Sus controllers web viven en `lib/metadata_app_web/controllers/business_process_builder/`:
`catalogo_controller.ex`, `catalogo_admin_controller.ex`, `meta_schema_header_controller.ex`.

## 2. `meta_business_process/` — lo que se construyó con el BPB

```
lib/metadata_app/meta_business_process/
├── catalogos/                   MetadataApp.MetaBusinessProcess.Catalogos.*
│   ├── pty_clientes.ex          Un archivo por catálogo, autogenerado por
│   ├── pty_canal.ex             CatalogoGenerador — nunca se edita a mano.
│   ├── pty_subcanal.ex
│   ├── pty_aly_marcas.ex
│   └── pty_equipos_nfl.ex       ← acá aterrizó el catálogo del ejemplo NFL
│
└── reglas/                      MetadataApp.MetaBusinessProcess.Reglas.*
    └── pty_aly_marcas/          Un namespace por catálogo — reglas de negocio
        ├── no_cocacola.ex       (PRE/POST) escritas a mano por el equipo de
        └── pepsi_es_lo_de_hoy.ex Lógica de Negocio, sin tocar el motor.
```

Esta es la carpeta que un catálogo nuevo puede tocar: cada vez que armás un Business Context (como `pty_equipos_nfl`), el `.ex` generado aparece acá adentro, no en `business_process_builder/`.

## 3. El Motor de Estados — namespace `Meta*`, aparte del BPB

```
lib/metadata_app/
├── meta_state_engine.ex             MetadataApp.MetaStateEngine
│                                     ejecutar_transicion/3, transiciones_disponibles/2,
│                                     campos_editables/2 — el ciclo de 5 pasos.
├── meta_state_engine/
│   ├── regla_pre.ex                 MetadataApp.MetaStateEngine.ReglaPre (contrato)
│   ├── regla_post.ex                MetadataApp.MetaStateEngine.ReglaPost (contrato)
│   ├── reglas.ex                    MetadataApp.MetaStateEngine.Reglas (despacho)
│   └── reglas/
│       ├── pre.ex                   MetadataApp.MetaStateEngine.Reglas.Pre (8 reglas)
│       └── post.ex                  MetadataApp.MetaStateEngine.Reglas.Post (8 reglas)
├── meta_estados_admin.ex            MetadataApp.MetaEstadosAdmin
│                                     CRUD admin de estados/transiciones/reglas
│                                     (arma el autómata paso a paso desde la API).
├── meta_bc_cliente.ex               MetadataApp.MetaBcCliente
│                                     Puerta única para que una regla toque OTRO
│                                     catálogo (cross-BC).
└── meta_permissions.ex              MetadataApp.MetaPermissions
                                      Stub de RBAC usado por la regla requiere_rol.
```

Los schemas Ecto de las tablas del motor (`meta_schema_estados/transiciones/transicion_eventos/transicion_reglas`) viven en `lib/metadata_app/meta_schema/` — **ojo, esta carpeta es distinta de** `business_process_builder/meta_schema/` (que solo tiene `header.ex`/`detail.ex`). Mismo nombre de carpeta, dos ubicaciones distintas — no confundir.

Sus controllers web viven sueltos en `lib/metadata_app_web/controllers/` (no en una subcarpeta, a diferencia de BPB): `meta_estado_controller.ex`, `meta_transicion_controller.ex`, `meta_transicion_admin_controller.ex`, `meta_transicion_regla_controller.ex`.

## Cómo validar que un catálogo nuevo quedó bien ordenado

Cuando armes un Business Context nuevo (como `pty_equipos_nfl`), estos son los únicos dos lugares donde el BPB debería haber escrito código:

1. `lib/metadata_app/meta_business_process/catalogos/<tabla>.ex` — el schema Ecto del catálogo.
2. Si el equipo de negocio le suma reglas propias: `lib/metadata_app/meta_business_process/reglas/<tabla>/<regla>.ex`.

Si aparece algo tuyo dentro de `business_process_builder/` o de `meta_state_engine*`, algo salió mal — esas carpetas son del motor, no se tocan por catálogo.

## Historial de este ordenamiento

- **2026-07-10** — separación inicial: `business_process_builder/` (BPB, la herramienta) vs. `meta_business_process/` (el producto), sacando los catálogos generados y las reglas de negocio de donde vivían sueltos antes.
- **2026-07-10** (mismo día, segunda pasada) — extensión del prefijo `meta_` al Motor de Estados: `state_engine.ex` → `meta_state_engine.ex`, `motor_estados_admin.ex` → `meta_estados_admin.ex`, `bc_cliente.ex` → `meta_bc_cliente.ex`, `permissions.ex` → `meta_permissions.ex`, y los 4 controllers del motor.
