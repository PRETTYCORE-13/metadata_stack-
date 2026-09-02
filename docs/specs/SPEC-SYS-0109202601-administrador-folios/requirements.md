# SPEC-SYS-0109202601 — Administrador de Folios de Transacciones

**Documento:** Requirements · **Fase:** ✅ aprobada (2026-09-01) — ver
`design.md` para la siguiente fase.

## 1. Propósito

Toda operación transaccional del sistema (factura, pedido, orden de
compra, vale de almacén, contrato, etc.) necesita una referencia única
— **Serie + Folio** — equivalente digital del foliado físico con sello
que se usaba antes en papel. Esa referencia es lo que el usuario final
usa para identificar un documento puntual ("la factura serie AA folio
123"), sin ella habría que referirse a un documento por cliente+fecha+
monto+sucursal, ambiguo y poco práctico. Además es la base de cualquier
control/auditoría de consecutivos: detectar documentos apócrifos y
hacer compulsas (verificar el papel físico impreso contra el registro
digital).

**Actores:**
- **Administrador funcional** — configura, por tipo/subtipo de
  transacción, qué serie(s)/folio maneja, si el foliado es único en
  todo el sistema o por sucursal, y en qué número arranca.
- **Usuario final** — da de alta el documento y recibe el folio ya
  asignado; nunca lo elige ni lo escribe a mano.
- **Sistema (automatización interna)** — integraciones externas,
  agentes, scripts, o reglas/procesos internos que crean una
  transacción foliada como efecto de otra (ej. confirmar un Pedido
  auto-genera una Factura) — sin humano al mando directo en ese
  instante. Pide folio igual que cualquier alta (ver R5).

## 2. Alcance

**Incluye:**
- Configuración de Serie/Folio por tipo y subtipo de transacción (ej. Factura → Nota de Crédito, Nota de Cargo)
- Granularidad configurable por tipo de transacción: folio único en todo el sistema, o independiente por Sucursal (Branch, la entidad que ya existe en el sistema) — solo esas dos opciones
- Número inicial configurable al arrancar a foliar (por defecto 1)
- Asignación automática e inmediata del folio al usuario final al dar de alta — nunca lo elige a mano
- El folio nace en la MISMA transacción que crea el documento en la base de datos — nunca hay un estado "borrador"/temporal previo
- Una vez asignado, el folio es intransferible y permanente: el documento puede cambiar de estado (ej. cancelarse) pero el folio nunca se libera ni se reasigna a otro documento
- Consulta histórica del folio y a qué documento pertenece, disponible en cualquier momento (para compulsas)
- Debe poder invocarse desde cualquier canal (frontend web, integración, app externa, agente, API) con la misma garantía de consecutivo — no es exclusivo de la UI

**No incluye (explícitamente fuera de esta feature):**
- El diseño/formato del documento impreso en sí (plantilla de la factura, del vale, etc.) — esto solo genera y entrega la referencia
- Cualquier otra granularidad que no sea "global" o "por Sucursal" (ej. por caja, por usuario, por almacén)
- Reimpresión como funcionalidad de documento (generar el PDF/papel de nuevo) — lo que sí entra es que el folio siga siendo consultable para que ESA feature (fuera de este spec) pueda reimprimir
- Política de reinicio automático (ej. "cada año vuelve a 1") — no existe como mecanismo del sistema; cuando un cliente necesita reiniciar (evento raro), el administrador da de alta una Serie nueva a mano con el número inicial que corresponda (ya cubierto por R1). No se construye ningún automatismo de reinicio.
- Carga de folios "externos"/continuar una numeración migrada de otro sistema (ej. `MAX()+1` sobre históricos) — reconocido como una necesidad real que han resuelto antes, pero **fuera de esta implementación** a pedido explícito. El diseño no debe hacerlo imposible a futuro, pero no se construye ahora.

## 3. Glosario

<!-- Términos del dominio, para que vos y la IA usen SIEMPRE la misma
palabra para lo mismo — evita que "perfil" en un requirement termine
siendo "configuración" en el código. -->

| Término | Significado |
|---|---|
| Serie | Código que agrupa/identifica un tipo o subtipo de documento. **Siempre exactamente 4 caracteres, string alfanumérico** (letras y/o números) — no hay largo variable. Si el administrador quiere un código conceptualmente más corto (ej. "AA"), lo completa él mismo hasta 4 (ej. "00AA"); el sistema no rellena/auto-completa, solo valida que la longitud sea 4. |
| Folio | Número consecutivo dentro de una Serie — entero simple, sin relleno de ceros ni ancho fijo, crece según el tipo `integer` (1, 2, 3... 99999, 100000...). |
| Serie + Folio | La referencia completa que identifica un documento ante el usuario (ej. "00AA-123"). |
| Transacción / Tipo de transacción | La operación de negocio que necesita foliado (ej. Factura, Pedido, Orden de Compra). |
| Subtipo | Variante de una transacción que puede llevar su propia Serie (ej. Nota de Crédito y Nota de Cargo son subtipos de Factura). |
| Documento apócrifo | Documento fraudulento o no autorizado — el control de consecutivos ayuda a detectarlo. |
| Compulsa | Verificación cruzada entre el documento físico impreso y el registro digital (¿coincide la Serie+Folio?). |
| Administrador funcional | Rol que configura el foliado (no necesariamente un sysadmin técnico — alguien del negocio con ese permiso). |

## 4. Requisitos funcionales

<!-- Notación EARS — un requisito por bloque, numerado, cada uno
verificable por sí solo (se puede convertir en un test).

  CUANDO <evento/condición>
  EL SISTEMA DEBE <comportamiento observable>

Ejemplo:
  R1. CUANDO un usuario con permiso de alta crea un documento de un
      tipo que tiene folio configurado, EL SISTEMA DEBE asignarle un
      folio único siguiendo la configuración de esa serie. -->

### R1. Configuración del foliado
CUANDO un administrador funcional configura un tipo o subtipo de transacción para que use folio, EL SISTEMA DEBE permitir definir su Serie, la granularidad (global o por Sucursal) y el número inicial de folio.

### R1a. Formato de la Serie
CUANDO un administrador funcional define o edita una Serie, EL SISTEMA DEBE validar que sea un string de exactamente 4 caracteres alfanuméricos — ni más corto ni más largo. El sistema no completa/rellena el valor por su cuenta; si el administrador necesita un código conceptualmente más corto, es su responsabilidad escribirlo ya completado a 4 caracteres (ej. "00AA").

### R2. Asignación automática al dar de alta
CUANDO se da de alta una transacción de un tipo que tiene folio configurado, EL SISTEMA DEBE asignarle automáticamente el siguiente folio consecutivo de su Serie correspondiente, en la misma operación que crea la transacción — nunca en un paso posterior ni en un estado "borrador".

### R3. Unicidad bajo concurrencia
CUANDO dos o más solicitudes de folio para la misma Serie llegan al mismo tiempo, EL SISTEMA DEBE garantizar que cada una reciba un folio distinto y consecutivo, sin duplicados.

### R4. El folio es permanente
CUANDO una transacción con folio asignado cambia de estado (por ejemplo, se cancela), EL SISTEMA DEBE conservar su folio tal cual — nunca liberarlo ni reasignarlo a otra transacción.

### R5. Agnóstico del canal de origen
CUANDO cualquier canal (frontend web, integración, API externa, agente, script) solicita un folio, EL SISTEMA DEBE aplicar las mismas garantías de unicidad y consecutivo, sin importar el origen de la solicitud.

### R6. Trazabilidad histórica
CUANDO se consulta el historial de folios de un tipo de transacción, EL SISTEMA DEBE poder mostrar qué folio se asignó, a qué transacción, y cuándo — sin límite de tiempo hacia atrás.

### R7. Atomicidad folio-transacción
CUANDO la creación de una transacción falla después de haberse generado su folio, EL SISTEMA DEBE revertir ambos juntos (folio y transacción) como una sola operación — no debe quedar un folio asignado a una transacción que no llegó a completarse. Excepción: si un error de programación no contemplado deja una transacción incompleta persistida de todas formas, su folio permanece ligado a ella y tampoco se libera ni se reutiliza (ver R4).

### R8. Subtipo dado de baja no folía (agregado 2026-09-01, a pedido explícito)
CUANDO se pide un folio para una transacción cuyo Subtipo está dado de baja, EL SISTEMA DEBE rechazar la asignación — sin importar el canal (R5) ni si existe un perfil configurado para ese subtipo. Depende del catálogo "Subtipos de Transacción" (glosario, dependencia asumida en design.md §2), que nace junto con esta regla: cada subtipo tiene su propio ciclo de vida (Activo/Baja), independiente del estado de la transacción que lo usa.

## 5. Requisitos no funcionales

<!-- Concurrencia, seguridad, rendimiento, auditoría -- lo que no es
"una acción del usuario" pero igual es innegociable. -->

- **Atomicidad**: la asignación de un folio es una operación atómica — no puede quedar a medias ni asignarse dos veces el mismo folio.
- **Alta concurrencia**: múltiples solicitudes simultáneas del mismo tipo/serie deben resolverse sin duplicados ni folios perdidos, sin importar cuántas lleguen al mismo tiempo.
- **Multi-canal / agnóstico del caller**: la garantía de consecutivo se sostiene sin importar quién pida el folio (frontend web, integración, app externa, agente, script) — el motor no puede confiar en que "solo lo llama la UI".

## 6. Preguntas abiertas

<!-- Todo lo que todavía no está decidido. No se pasa a design.md
con preguntas abiertas sin resolver. -->

Ninguna pendiente — las 3 que estaban acá se resolvieron y ya están
incorporadas: atomicidad folio-transacción (R7), reinicio vía Serie
nueva a mano (Alcance §2, no incluye reinicio automático), y carga de
folios externos explícitamente fuera de alcance (Alcance §2).
