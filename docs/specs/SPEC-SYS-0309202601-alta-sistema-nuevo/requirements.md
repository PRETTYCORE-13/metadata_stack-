# SPEC-SYS-0309202601 — Alta de Sistema Nuevo

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-03).

## 1. Propósito

Hoy `metadata_stack-` despliega un único sistema en producción: namespace y
deployment fijos (`metadata-stack`/`metadata-stack-app`) hardcodeados en
`ci.yml` y `bc-deploy.yml`, una sola base Postgres, un solo dominio. Todo el
mecanismo de CI/CD, `mix motor.publicar` y `bin/setup` asume que existe
exactamente un destino.

El plan de negocio requiere alojar varios sistemas independientes (clientes)
en el mismo clúster k3s compartido — cada uno con su propia base de datos y
su propio despliegue, arrancando por un CRM. Este spec define el **mecanismo
para dar de alta un sistema nuevo y desplegarle apps** — no el contenido del
CRM en sí, que queda como spec futura y separada.

## 2. Alcance

**Incluye:**
- Mecanismo para dar de alta un sistema nuevo: base de datos + app/deployment
  en k3s + registro en el archivo de sistemas válidos.
- Simulación local de "RDS" (un Postgres con varias bases, una por sistema)
  para desarrollo y pruebas, sin tocar producción.
- `mix motor.publicar` con un flag `--sistema=` obligatorio, y
  `bc-deploy.yml`/`ci.yml` sin el namespace/deployment hardcodeado — dirigidos
  al sistema indicado.
- Ruteo por subdominio (`<sistema>.ventaenruta.com.mx`) para que cada sistema
  tenga su propia URL.
- Confirmar qué pasos del checklist de alta (branch/almacén/unidad de
  venta/folios) ya cubre el wizard de primer arranque y cuáles hace falta
  agregar al mecanismo nuevo.

**No incluye:**
- El catálogo/modelo de datos del CRM en sí — spec futura y separada, que
  usará lo que este spec construya.
- Backup/DR, alta disponibilidad del clúster, observabilidad/alertas — gaps
  reales identificados en la misma conversación, pero de otro spec.
- Migrar la producción real a AWS RDS — este spec deja el mecanismo listo
  para apuntar ahí por variable de entorno, no ejecuta esa migración de
  infraestructura.
- Revisión del historial de git del repo por posible información sensible
  expuesta mientras fue público — aparte, no bloquea esto.

## 3. Decisiones ya resueltas (de la conversación previa a este documento)

- **Postgres: una instancia con N bases, sin sharding todavía.** Validado
  con evidencia real (50 bases en una sola instancia RDS funcionando bien
  hoy en otro contexto). Partir en más instancias queda como palanca para
  cuando haga falta, no se construye de entrada.
- **Misma app para todos los sistemas.** Se replica tal cual — no hay
  mecanismo de catálogos distintos por cliente.
- **Migración de plataforma a un sistema ya en producción: manual,
  decidida por ADN.** No se automatiza un rollout a todos los sistemas a
  la vez.
- **Versión desplegada por sistema: k3s es la fuente de verdad.** Sin
  registro aparte de "qué versión tiene cada cliente" — se consulta el
  Deployment directo cuando hace falta saber qué corre.
- **Sistemas válidos: archivo versionado en el repo.** ADN no tiene acceso
  al clúster desde su máquina (todo pasa por GitHub Actions vía
  `motor.publicar`), así que un archivo en el repo (p. ej.
  `priv/sistemas.json`) es lo que valida/lista el flag `--sistema=`. Se
  actualiza como último paso del mecanismo de alta.
- **Repo privado.** El pull de producción no depende de que el paquete sea
  público — `ghcr-pull-secret` ya está configurado en el Deployment.

## 4. Requisitos funcionales (borrador — EARS)

### R1. Alta de un sistema nuevo — base de datos y app
CUANDO alguien del equipo de Desarrollo (Dev — no ADN) ejecuta el mecanismo
de alta con el nombre de un sistema nuevo, EL SISTEMA DEBE crear su base de
datos dedicada y su despliegue (app) en el clúster k3s, sin afectar los
sistemas ya existentes.

### R2. Postgres compartido antes de AWS RDS (corregido 2026-09-04)
CUANDO un sistema se da de alta antes de que exista una instancia de AWS
RDS real, EL SISTEMA DEBE poder crear su base en un servidor Postgres
compartido con varias bases (una por sistema), intercambiable por la
instancia real de AWS RDS solo cambiando variables de entorno, sin cambios
de código. **Corrección real (2026-09-04)**: originalmente se planteó como
un Postgres LOCAL por developer (docker-compose individual) — al ejecutar
se decidió que fuera un único servidor compartido corriendo dentro del
mismo clúster k3s (`aws-postgres`, ver `design.md` §2), más fiel al modelo
real de "un servidor, N bases" que una copia distinta por persona.

### R3. Bootstrap del sistema recién creado
CUANDO el mecanismo de alta termina de crear la base y el despliegue de un
sistema nuevo, EL SISTEMA DEBE dejarlo en el mismo estado que hoy deja un
despliegue nuevo (tablas `meta_*` migradas, listo para el wizard de primer
arranque) — reusando `bin/setup`, sin duplicar esa lógica.

### R4. Registro del sistema nuevo
CUANDO el mecanismo de alta termina exitosamente, EL SISTEMA DEBE agregar el
sistema nuevo al archivo de sistemas válidos (`sistemas.json` o equivalente)
como último paso — un sistema dado de alta pero no registrado ahí se
considera una alta incompleta.

### R5. Publicar una app a un sistema específico
CUANDO alguien de ADN corre `mix motor.publicar` para desplegar un catálogo,
EL SISTEMA DEBE exigir que indique a qué sistema va dirigido (`--sistema=`),
sin ningún valor por default — y rechazar el comando si el sistema indicado
no está en el registro de sistemas válidos.

### R6. Despliegue dirigido, no hardcodeado
CUANDO `bc-deploy.yml` o `ci.yml` despliegan una imagen, EL SISTEMA DEBE
actualizar el namespace/deployment del sistema indicado — nunca uno fijo —
de modo que publicar a un sistema no pueda afectar accidentalmente a otro.
Este requisito asume que el sistema ya existe (dado de alta vía R1) — R6
nunca crea un sistema nuevo, solo apunta a uno existente; el rechazo por
sistema no registrado ya es responsabilidad de R5, no se repite acá.

### R7. Acceso por subdominio propio, siempre HTTPS
CUANDO un sistema queda dado de alta, EL SISTEMA DEBE quedar accesible en su
propio subdominio (`<sistema>.ventaenruta.com.mx`) exclusivamente por
HTTPS — sin interferir con el acceso a los demás sistemas del mismo
clúster, y sin exponer HTTP plano en ningún momento.

### R8. Consulta de versión desplegada
CUANDO alguien necesita saber qué versión de una app corre en un sistema
dado, EL SISTEMA DEBE permitir consultarlo directo contra el clúster (k3s),
sin depender de un registro separado que se pueda desincronizar.

### R9. Configuración mínima de negocio al alta
CUANDO el mecanismo de alta termina de crear un sistema nuevo, EL SISTEMA
DEBE dejarlo con una Sucursal, un Almacén y una Unidad de Venta por default
(valores genéricos, editables después desde la UI), y con las tablas de
transacciones, subtipos y perfiles de folio ya creadas — listas para
configurarse, sin necesitar una publicación aparte. Verificado (2026-09-03):
hoy nada de esto lo cubre el wizard de primer arranque (`primer_arranque.ex`
+ `Autenticacion.crear_empresa_para_usuario/2`) — solo crea sysadmin,
empresa y rol administrador.

## 5. Preguntas abiertas

Ninguna pendiente — las 2 que estaban acá se resolvieron (2026-09-03):

- **Ruteo por subdominio: un Ingress por sistema** (no uno único que
  multiplexe). El mecanismo de alta crea la configuración de ruteo del
  sistema nuevo como parte de R1 — el detalle técnico se especifica en
  `design.md`.
- **Certificado TLS: wildcard** (`*.ventaenruta.com.mx`), no uno por
  sistema — cualquier subdominio nuevo queda cubierto automáticamente, sin
  pedir un certificado aparte en cada alta.
