# Onboarding de un sistema nuevo — plan

> Motivado por el bootstrap de `167.233.84.151` (2026-08-13/14): una base 100% vacía tardó varias horas de trabajo de ingeniero por SSH/RPC para quedar operativa. Con la meta de decenas o cientos de sistemas, ese camino no escala — este documento propone cómo dejarlo en un procedimiento transparente que Operaciones pueda ejecutar sin ayuda de un ingeniero.

## 1. Qué salió mal (diagnóstico, no repetir sin leerlo)

Cinco problemas distintos, cada uno descubierto por un crash o un loop, uno a la vez:

1. **Variables de entorno faltantes descubiertas de a una.** `CLOAK_KEY` faltaba → el release ni arrancaba. Se corrigió, y recién ahí apareció que `SYSADMIN_EMAIL`/`SYSADMIN_PASSWORD` también faltaban. No hay ningún paso que valide TODO de una vez.
2. **Bug real de ordenamiento de migraciones.** Las migraciones que arma el generador de catálogos usan timestamps de 17 dígitos; las escritas a mano, de 14. Ecto ordena por el entero completo, no por fecha real — un timestamp de 17 dígitos siempre ordena *después* que uno de 14, sin importar la fecha. Nunca importa en un deploy normal (la migración de creación ya corrió hace meses), pero migrar una base 100% vacía de una sola pasada sí choca.
3. **Releases de GitHub (`bc-*`) con bundles obsoletos.** Un catálogo borrado localmente puede seguir "resucitando" en cada deploy porque otro release (ej. el de una carpeta que lo incluía) todavía trae su copia vieja.
4. **No existe ningún camino para crear la primera empresa.** Sin al menos una empresa, la UI entera queda en loop (`/` → `seleccionar-empresa` → `/` …) — no hay botón, no hay ruta, nada. La única forma de salir fue una llamada RPC directa a una función interna (`Autenticacion.crear_empresa_para_usuario/2`), algo que solo alguien con acceso SSH + conocimiento del código puede hacer.
5. **No hay forma de confirmar "¿este sistema ya está listo?"** sin probar manualmente cada pieza (SMTP incluido — se validó con llamadas crudas a `:ssl`/`:gen_smtp`).

Ítems 1, 4 y 5 son el verdadero costo — son proceso, no complejidad técnica real. El ítem 2 es el único bug de código puro que hay que arreglar antes de que vuelva a morder.

## 2. Objetivo

Que **Operaciones** (sin SSH, sin `docker exec`, sin conocer Elixir) pueda llevar un servidor de "recién desplegado" a "listo para el primer usuario real" siguiendo un procedimiento escrito, sin intervención de un ingeniero — y que sea **idempotente**: correrlo de más nunca rompe nada.

## 3. Plan por fases

### Fase 0 — Arreglar el bug de ordenamiento de migraciones (prerrequisito)

Antes de construir nada nuevo encima: mientras el generador siga produciendo timestamps de 17 dígitos y convivan con migraciones escritas a mano de 14, **cualquier sistema nuevo que migre de cero puede volver a pisar esta misma trampa** con cualquier otro catálogo, no solo con `pty_gasto_diario`. Alinear el formato (o documentar + validar el orden real en un test) antes de automatizar el bootstrap sobre una base rota.

*Tamaño: chico. Riesgo: bajo. Bloqueante para todo lo demás.*

### Fase 1 — `/app/bin/setup`: un solo comando idempotente

Hoy existen `migrate`, `seed_sysadmin`, `import_meta` como comandos sueltos, y **crear la primera empresa no existe como comando en absoluto**. Fase 1 es consolidar todo en un solo release task:

1. Valida TODAS las variables de entorno requeridas de una sola pasada — si falta algo, lista todo lo que falta y para ahí, en vez de ir descubriendo una por una a fuerza de crashes.
2. Corre migraciones.
3. Corre `import_meta` (trae los catálogos `pty_*` publicados).
4. Crea el sysadmin si no existe (idempotente — no lo duplica si ya está).
5. **Si no existe ninguna empresa todavía**, crea una por default (nombre desde una variable de entorno nueva, ej. `EMPRESA_INICIAL_NOMBRE`) y la asigna al sysadmin como administrador.
6. Imprime un reporte final claro: qué se hizo, qué ya estaba, qué falló.

Este comando se engancha en el paso de deploy que ya existe (`ci.yml`) — así CADA deploy (el primero o el número 500) deja el sistema completo, sin pasos manuales, sin importar si es la primera vez o no.

*Tamaño: chico-mediano. Es reordenar piezas que ya existen, no inventar lógica nueva (salvo el paso 5, que no existe en ningún lado hoy).*

### Fase 2 — Wizard de primer arranque (la pieza que de verdad habilita a Operaciones)

Esto es lo que hacen WordPress, Odoo, y la mayoría de sistemas self-hosted: si el sistema detecta que **no existe ningún sysadmin todavía**, en vez de la pantalla normal muestra una única pantalla de bienvenida: "Configurá tu administrador" (email + contraseña) y "Nombre de tu empresa". Al enviarla, hace exactamente lo que la Fase 1 hace en los pasos 4-5, pero desde el navegador — cero SSH, cero terminal.

Una vez que existe un sysadmin, esa pantalla desaparece para siempre (no se puede volver a usar para crear un segundo sysadmin colado).

Con esto, Operaciones abre la URL del sistema nuevo, completa un formulario, y ya está — el resto (variables de entorno de infraestructura) sigue siendo un paso previo de Fase 3, pero todo lo de la aplicación se vuelve apuntar-y-hacer-clic.

*Tamaño: mediano. Es una feature real (una LiveView nueva + la lógica de "solo se puede usar una vez").*

### Fase 3 — Escalar a ~100 sistemas: plantilla + registro + runbook

Esto ya no es código, es proceso:

- **Plantilla de variables de entorno** (`.env.example` o `docs/plantilla.env`) con cada variable requerida y una línea explicando qué es — una sola fuente de verdad, en vez de conocimiento tribal descubierto a crashes (como pasó hoy con `CLOAK_KEY`/`SYSADMIN_EMAIL`/`SMTP_*`).
- **Registro de sistemas** (aunque sea una planilla al principio): nombre, URL, qué cuenta SMTP usa, dónde vive su `CLOAK_KEY` (nunca el valor en el registro — solo dónde está guardado, ej. gestor de contraseñas), fecha de alta, quién es dueño.
- **Runbook escrito** (`docs/nuevo-servidor.md`, mismo estilo que `docs/ci-cd-deploy.md` ya existente): provisionar → variables desde la plantilla → deploy → confirmar que la Fase 1 corrió limpia → abrir la URL → completar el wizard de Fase 2 → listo. Esto es el "procedimiento transparente" pedido.

*Tamaño: trabajo continuo de proceso/documentación, no un sprint de ingeniería.*

## 4. Decisión tomada: 100 aplicativos dockerizados independientes

Confirmado (2026-08-14): son **100 aplicativos separados**, no una plataforma multi-tenant — cada uno con su propia base de datos, su propio `CLOAK_KEY`, su propio ciclo de vida. Esto hace que la Fase 3 (plantilla + registro + runbook) sea necesaria completa, no opcional.

Queda una segunda decisión, más chica pero con impacto operativo real en cómo se arma la Fase 3:

**¿Los 100 aplicativos corren en 100 servidores/VMs separados, o son 100 *servicios* de Docker Swarm compartiendo un clúster más chico (2-3 hosts)?**

Docker Swarm (lo que ya usamos) está pensado justo para el segundo caso: muchos servicios aislados entre sí (contenedores, redes, volúmenes propios de cada uno) corriendo sobre infraestructura compartida — no hace falta una VM nueva por aplicativo para tener aislamiento real. La diferencia es puramente operativa:

- **100 servidores separados**: cada uno con su propio SO que mantener, parchear, monitorear — 100x el trabajo de infraestructura, aunque cada aplicativo esté más aislado a nivel físico.
- **Clúster compartido, 100 servicios**: un solo `docker service create` (templado, ver Fase 3) por aplicativo nuevo, un solo lugar donde parchear el SO, y todavía cada aplicativo tiene su propio contenedor/red/volumen — el mismo aislamiento de datos y de proceso que tendría en su propio servidor, sin la carga de mantener 100 SO.

Si no hay un motivo de compliance/contrato que obligue a servidores físicos separados por cliente, la opción de clúster compartido es la que escala de verdad a 100 sin que el equipo de Operaciones se ahogue en mantenimiento de infraestructura.

**Confirmado (2026-08-14): clúster compartido, Docker Swarm por ahora — con migración a Kubernetes planeada a corto plazo (no inmediata).** Esto agrega un criterio de diseño importante para la Fase 3: no conviene invertir en automatización elaborada específica de Swarm (scripts complejos de `docker service create`, orquestación custom) si en poco tiempo hay que rehacerla para K8s (Helm charts / manifiestos). La Fase 3, mientras dure Swarm, debería quedar deliberadamente liviana — plantilla + runbook manual, no una herramienta interna sofisticada.

En cambio, las **Fases 0-2 son la inversión de verdad**: viven *adentro* de la aplicación (validación de variables, el comando `/app/bin/setup`, el wizard web), no dependen de qué orquestador las corre. Eso significa que sobreviven intactas al pasar de Swarm a Kubernetes — el día de la migración, cada pod nuevo sigue arrancando, corriendo `setup`, y mostrando el mismo wizard, sin tocar una línea de esa lógica. Es la razón de más peso para priorizar 0-2 ahora y dejar la automatización pesada de infraestructura (Terraform/Ansible/Helm) para después de migrar, en vez de construirla dos veces.

## 5. Fuera de alcance (por ahora)

- Automatizar el aprovisionamiento de infraestructura (Terraform/Ansible para los hosts de Docker Swarm) — vale la pena recién cuando el patrón de las Fases 1-3 esté probado en varios sistemas reales.
- UI de facturación/gestión de clientes — es un problema aparte de "dejar el sistema operativo".
