# Product backlog — Marketplace Popayán

Fecha: 3 de noviembre de 2026. Versión: 1.0. Estado: propuesta lista para refinamiento e implementación; ninguna historia está implementada.

## 1. Objetivo del producto

Permitir que compradores encuentren productos de vendedores locales, conversen con ellos y completen pedidos desde una aplicación Flutter, con inventario, mensajes y estados de pedido sincronizados mientras la aplicación está conectada.

Stack solicitado: Cloudflare Workers + Hono + Workers KV + Flutter. La propuesta añade D1, Durable Objects y R2 para cubrir transacciones, comunicación en vivo e imágenes.

### Supuestos de partida

- Mercado inicial: Popayán, Colombia; idioma español y moneda COP. Son supuestos derivados del nombre del proyecto, ajustables.
- Aplicación Flutter para Android e iOS; Android primero para la validación piloto. La publicación en tiendas requiere cuentas y revisión de cada plataforma.
- Una cuenta puede comprar y vender. Un administrador gestiona categorías, reportes y suspensiones mediante una sección restringida de la aplicación.
- MVP: productos físicos, un vendedor por pedido y recogida acordada entre comprador y vendedor. Sin carrito entre múltiples vendedores ni logística propia.
- El piloto permite pago contraentrega o pago al recoger. El sistema registra la declaración de pago; no procesa ni custodia dinero en esta modalidad.
- Pago digital y domicilio integrado quedan para una segunda versión. La primera versión debe permitir completar compras reales con la modalidad del piloto.
- La consulta de catálogo es pública; comprar, vender, guardar favoritos y chatear requieren sesión.
- No se ha fijado presupuesto, equipo, proveedor de identidad, pasarela ni fechas de lanzamiento. Las fases expresan dependencias, no compromisos de calendario.

## 2. Alcance y reglas del MVP

Incluye registro, recuperación de acceso, perfiles, publicaciones con fotos, catálogo con búsqueda y filtros, favoritos, chat individual, pedidos, reserva de existencias, notificaciones, moderación y operación del servicio.

Reglas de negocio:

1. Cada publicación pertenece a un vendedor y tiene precio, moneda, cantidad disponible, categoría y estado. Los importes se guardan como enteros en unidades menores; nunca como números flotantes.
2. Crear un pedido reserva existencias por 30 minutos. Si el vendedor acepta dentro del plazo, la reserva se convierte en asignación al pedido. Si rechaza, vence o cancela antes de la entrega, se libera una sola vez.
3. Dos compradores no pueden reservar la misma última unidad. La disponibilidad y el precio se validan en el servidor, incluso si la pantalla muestra información anterior.
4. El vendedor acepta o rechaza. Tras aceptar, puede marcar listo para recoger; el comprador confirma recepción. El administrador puede resolver casos abiertos con motivo y registro de auditoría.
5. Estados: pendiente de aceptación → aceptado → listo para recoger → completado. Desde pendiente se permite rechazado, vencido o cancelado; desde aceptado/listo se permite cancelado según la política inicial. Completado es terminal; devoluciones se incorporan en V1.
6. El comprador puede cancelar antes de completar; el vendedor también puede cancelar con motivo. El servidor valida cada transición y restituye existencias cuando corresponde.
7. El pedido conserva una copia de título, precio, cantidad y condiciones al comprar. Editar un producto no modifica pedidos existentes.
8. Las publicaciones suspendidas o de vendedores suspendidos no admiten nuevas compras. Los pedidos existentes conservan trazabilidad y acceso a soporte.
9. Las acciones repetidas por reintento deben producir un único pedido, mensaje o cambio de estado mediante claves de idempotencia.
10. El punto de recogida y los datos de contacto privados se muestran únicamente a participantes autorizados; no se publica la dirección residencial por defecto.

## 3. Arquitectura propuesta

| Componente | Responsabilidad |
|---|---|
| Flutter | Interfaz, sesión, estado local, reconexión y caché de lectura |
| Workers + Hono | API HTTP versionada, autenticación, permisos, validaciones y reglas de negocio |
| D1 | Fuente de verdad de usuarios, productos, inventario, pedidos, mensajes y auditoría; cambios relacionados mediante operaciones atómicas |
| KV | Caché de categorías, configuración pública y proyecciones de lectura con TTL; nunca fuente autoritativa de stock, permisos o pedidos |
| Durable Objects + WebSockets | Canales autenticados por usuario/conversación, distribución de eventos y control de suscripciones |
| R2 | Fotografías con acceso y límites de carga controlados |
| Proveedor de identidad | Registro, verificación y recuperación; selección en PB-02 |
| Servicio push | Avisos cuando la app está en segundo plano; integración con las plataformas móviles |
| Tareas programadas y procesamiento asíncrono | Vencimiento de reservas, reintentos y entrega de eventos pendientes |

La consistencia eventual de KV impide tratarlo como un sistema de transacciones de inventario. Hono admite Workers y Durable Objects ofrece WebSockets. Estas capacidades sustentan la propuesta; la combinación concreta anterior es una decisión de diseño del proyecto.

### Contrato de tiempo real

- Objetivo inicial: el 95 % de los cambios confirmados se refleja en los clientes conectados en un máximo de 2 segundos, bajo la carga piloto definida en PB-33. Es una meta por validar, no una garantía de la plataforma.
- Cada evento incluye `eventId`, `type`, `entityId`, `entityVersion`, `occurredAt` y datos autorizados. El cliente deduplica y descarta versiones anteriores.
- Eventos mínimos: `product.updated`, `inventory.changed`, `message.created`, `message.read`, `order.updated` y `notification.created`.
- El servidor confirma el cambio persistente antes de emitir. Un registro de eventos pendientes se escribe junto con el cambio de negocio y se reintenta si falla la distribución; la entrega puede repetirse.
- Al reconectar, el cliente recupera eventos desde un cursor. Si el historial ya venció, solicita una instantánea actualizada. Ninguna conexión WebSocket es el único lugar donde vive un dato de negocio.
- Ante desconexión, la app muestra estado de conexión y última actualización; permite consultar información guardada, pero necesita confirmación del servidor para compras y cambios de inventario.
- Las notificaciones push son avisos de entrega eventual. Al abrirlas, se consulta el estado vigente del servidor; no sustituyen el canal en vivo.

## 4. Convenciones del backlog

P0: obligatorio para lanzar el piloto. P1: siguiente versión. P2: evolución posterior. Todas las historias parten en estado **Pendiente**.

Los puntos son estimaciones relativas preliminares: 3 pequeña, 5 mediana, 8 grande, 13 muy grande. No representan días. Las historias de 13 puntos deben dividirse en tareas antes de entrar a una iteración. Cada fila expresa una historia y condiciones observables para aceptarla.

## 5. Historias priorizadas del MVP

### Épica A — Fundamentos y acceso

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-01 | Como equipo, quiero entornos reproducibles para desarrollar y publicar sin mezclar datos. | P0 / 5 | — | Backend Hono y app Flutter ejecutan localmente; desarrollo, pruebas y producción tienen recursos separados; configuración y secretos están documentados; endpoint de salud disponible. |
| PB-02 | Como usuario, quiero crear y verificar mi cuenta para operar con una identidad válida. | P0 / 8 | PB-01 | Se elige y documenta el proveedor de identidad; registro por correo, verificación y acceso funcionan de extremo a extremo; correos duplicados y entradas inválidas se resuelven con mensajes claros; se registran aceptación y versión de condiciones. |
| PB-03 | Como usuario, quiero recuperar acceso y cerrar sesiones de forma segura. | P0 / 5 | PB-02 | Recuperación con enlace de un solo uso y vencimiento; renovación de sesión; cierre revoca la sesión y sus canales privados; respuesta de recuperación no revela si existe una cuenta. |
| PB-04 | Como usuario, quiero gestionar mi perfil y activar ventas. | P0 / 5 | PB-02 | Nombre, avatar y zona editables; comprador puede activar perfil vendedor; campos públicos y privados separados; solo el titular o una operación administrativa autorizada puede modificarlos. |
| PB-05 | Como operador, quiero controlar permisos y abuso de la API. | P0 / 8 | PB-02 | Matriz comprador/vendedor/administrador aplicada en servidor; acceso a objetos de terceros rechazado; límites de frecuencia; validación de entradas; cuentas suspendidas pierden capacidad de mutación; pruebas de acceso cruzado pasan. |

### Épica B — Publicaciones y descubrimiento

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-06 | Como administrador, quiero gestionar categorías y zonas. | P0 / 3 | PB-05 | Alta, edición y desactivación; identificadores estables; una categoría con publicaciones no se elimina físicamente; caché KV con TTL documentado y versión para actualización. |
| PB-07 | Como vendedor, quiero cargar fotografías para mostrar mis productos. | P0 / 5 | PB-04, PB-05 | Entre 1 y 8 fotos por publicación, máximo inicial de 5 MB por foto; tipo y contenido validados en servidor; se eliminan metadatos de ubicación; carga fallida puede reintentarse; usuarios no pueden sobrescribir archivos ajenos. |
| PB-08 | Como vendedor, quiero publicar un producto con precio y existencias. | P0 / 8 | PB-06, PB-07 | Borrador y publicación; título, descripción, categoría, COP, precio positivo, cantidad entera y zona obligatorios; solo productos válidos aparecen en catálogo; servidor asigna propietario. |
| PB-09 | Como vendedor, quiero editar, pausar o archivar mis publicaciones. | P0 / 5 | PB-08, PB-15 | Cambios persistidos y emitidos a suscriptores; edición concurrente detectada por versión; no se reduce stock por debajo de lo reservado/asignado; pausar impide nuevos pedidos sin alterar los anteriores. |
| PB-10 | Como comprador, quiero explorar y buscar productos disponibles. | P0 / 8 | PB-08 | Búsqueda inicial por título y descripción; filtros por categoría, rango de precio y zona; orden por fecha/precio con desempate estable; paginación; estados de carga, vacío y error; las publicaciones bloqueadas se excluyen. |
| PB-11 | Como comprador, quiero ver el detalle y la disponibilidad actual de un producto. | P0 / 5 | PB-10, PB-15 | Muestra fotos, vendedor, precio, zona y disponibilidad; cambios recibidos sin recargar; producto agotado o pausado impide comprar; al reconectar consulta estado autoritativo. |
| PB-12 | Como comprador, quiero guardar favoritos para volver a ellos. | P0 / 3 | PB-02, PB-08 | Guardar/quitar sin duplicados; lista persistente entre sesiones; productos eliminados o pausados muestran condición adecuada; solo el titular accede a su lista. |

### Épica C — Comunicación y sincronización

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-13 | Como cliente conectado, quiero recibir solo los eventos que puedo consultar. | P0 / 8 | PB-05 | WebSocket autenticado con credencial temporal; canales de usuario, conversación y producto; autorización por suscripción y revocación ante bloqueo/cierre de sesión; límites de conexiones y mensajes. |
| PB-14 | Como usuario, quiero recuperar cambios después de perder conexión. | P0 / 8 | PB-13 | Cursor persistido, reconexión con espera progresiva y variación aleatoria, deduplicación y orden por versión; historial vencido activa resincronización; prueba de desconexión no pierde mensajes ni estados confirmados. |
| PB-15 | Como usuario, quiero que los cambios confirmados lleguen aunque falle una emisión. | P0 / 8 | PB-01, PB-13 | Mutación y evento pendiente se persisten atómicamente; proceso reintenta con límite y registro de fallos; duplicados son inocuos; una caída entre confirmación y emisión se recupera sin inventar un cambio. |
| PB-16 | Como comprador, quiero conversar con el vendedor sobre un producto. | P0 / 8 | PB-08, PB-14, PB-15 | Conversación vinculada al producto; mensajes de texto persistentes, paginados y en vivo; solo participantes autorizados acceden; reintento con mismo identificador no duplica; bloqueo impide nuevos mensajes. |
| PB-17 | Como participante, quiero saber qué mensajes están entregados y leídos. | P0 / 5 | PB-16 | Estados enviado/entregado/leído con definición documentada; lectura se actualiza al visualizar; contador de no leídos consistente al abrir desde dos dispositivos; desconexión no se presenta como entrega exitosa. |
| PB-18 | Como usuario, quiero recibir avisos de mensajes y pedidos. | P0 / 8 | PB-16, PB-22 | Centro de notificaciones persistente y push móvil; permiso rechazado no rompe la app; tokens renovados o inválidos se gestionan; abrir un aviso conduce al recurso autorizado; contenido privado no aparece en el aviso por defecto. |

### Épica D — Compra, inventario y pedidos

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-19 | Como comprador, quiero preparar una compra de un vendedor. | P0 / 5 | PB-11 | Resumen con artículos, cantidades, precio total y recogida; un solo vendedor por pedido; servidor recalcula valores y solicita aceptación si cambia el precio; no permite comprarse a sí mismo. |
| PB-20 | Como comprador, quiero reservar productos sin sobreventa. | P0 / 13 | PB-19, PB-15 | Creación del pedido y reserva de todas sus líneas en una operación atómica; si falta una línea no se reserva ninguna; dos solicitudes por la última unidad producen un único éxito; clave idempotente devuelve el mismo resultado; vencimiento fijado por servidor. |
| PB-21 | Como vendedor, quiero aceptar o rechazar pedidos pendientes. | P0 / 8 | PB-20 | Solo vendedor propietario opera; aceptación antes del vencimiento asigna stock; rechazo libera una vez; carrera entre aceptación y vencimiento tiene un único resultado válido; comprador recibe el evento. |
| PB-22 | Como comprador y vendedor, quiero seguir y completar la entrega. | P0 / 8 | PB-21 | Lista y detalle con historial; transiciones siguen las reglas del apartado 2; vendedor marca listo, comprador confirma recepción; método y declaración de pago quedan registrados sin simular un cobro digital. |
| PB-23 | Como comprador o vendedor, quiero cancelar y liberar existencias correctamente. | P0 / 8 | PB-22 | Cancelación con motivo y validación de estado; tarea vence pendientes a partir de su plazo con retraso objetivo menor a 60 s; cancelación y vencimiento concurrentes restituyen una sola vez; reintentos no duplican movimientos. |
| PB-24 | Como vendedor, quiero consultar mis ventas y movimientos de inventario. | P0 / 5 | PB-23 | Filtro por estado y fechas; cantidades vendidas, reservadas y disponibles separadas; movimientos enlazados al pedido; totales excluyen cancelados y no confunden ventas contraentrega con dinero cobrado por la plataforma. |

### Épica E — Confianza y administración

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-25 | Como usuario, quiero reportar publicaciones o personas y bloquear contactos. | P0 / 5 | PB-05, PB-16 | Motivo, referencia y estado del reporte persistidos; bloquear impide nuevos mensajes; pedidos existentes conservan consulta y vía de soporte; no se revela al denunciado la identidad del reportante. |
| PB-26 | Como administrador, quiero resolver reportes y suspender abusos. | P0 / 8 | PB-25 | Cola de reportes, detalle, motivo y resolución; pausar publicación o suspender cuenta invalida acceso pertinente; auditoría de actor, momento y motivo; privilegios de administrador no pueden autoasignarse. |
| PB-27 | Como usuario, quiero conocer las condiciones y gestionar mis datos. | P0 / 5 | PB-04, PB-22 | Condiciones, privacidad, reglas de productos y contacto de soporte accesibles; solicitud de exportación/eliminación; eliminación desactiva cuenta y respeta la política documentada de conservación de pedidos; textos y plazos requieren validación del responsable antes del lanzamiento. |

### Épica F — Calidad, operación y lanzamiento

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-28 | Como usuario móvil, quiero una aplicación usable con conexión inestable. | P0 / 8 | PB-10, PB-14, PB-22 | Catálogo guardado identificable como anterior; formularios conservan borrador; acciones pendientes tienen estado visible; no se comunica una compra exitosa sin confirmación; navegación y errores permiten recuperar la tarea. |
| PB-29 | Como usuario, quiero una interfaz accesible y coherente en español. | P0 / 5 | PB-28 | Textos en español, COP y horarios locales; lectores de pantalla en tareas principales; tamaño de texto ampliado sin bloquear acciones; controles táctiles adecuados y errores asociados al campo correspondiente. |
| PB-30 | Como equipo, quiero detectar fallos y controlar consumo. | P0 / 5 | PB-01, PB-15 | Logs estructurados sin secretos ni texto privado del chat; identificador de solicitud; métricas de errores, latencia, conexiones y eventos pendientes; alertas y umbrales de consumo configurados para el piloto; procedimiento de diagnóstico documentado. |
| PB-31 | Como operador, quiero recuperar el servicio y sus datos. | P0 / 5 | PB-01, PB-30 | Copias/exportaciones y restauración verificadas en pruebas; objetivo inicial de pérdida máxima de datos 24 h y recuperación 4 h validado con un simulacro; migraciones y reversión del despliegue documentadas. |
| PB-32 | Como equipo, quiero comprobar los flujos completos antes de entregar. | P0 / 8 | PB-03, PB-12, PB-17, PB-18, PB-23, PB-26, PB-28 | Pruebas con comprador, vendedor y administrador: registro → publicación → chat → compra → recogida → cierre; rechazo, vencimiento, agotado y cancelación; ejecución en dos dispositivos y validación de permisos cruzados. |
| PB-33 | Como operador, quiero validar capacidad y tiempo real bajo carga. | P0 / 8 | PB-20, PB-30, PB-32 | Escenario inicial: 100 sesiones en vivo, 20 mensajes/s y 10 intentos de compra/s durante 15 min; actualizaciones p95 ≤2 s y lecturas API p95 ≤800 ms, excluyendo subida de fotos; sin sobreventa, eventos confirmados perdidos ni fuga de datos; resultados y límites publicados. |
| PB-34 | Como responsable, quiero desplegar un piloto instalable y operable. | P0 / 5 | PB-27, PB-29, PB-31, PB-33 | Backend en entorno productivo, app Android distribuida a participantes, build iOS validado según acceso a dispositivos/cuentas; secretos externos al repositorio; soporte y recuperación disponibles; prueba real de compra y entrega registrada. |

## 6. Backlog posterior al piloto

| ID | Historia | Prioridad / puntos | Dependencias | Criterios de aceptación |
|---|---|---|---|---|
| PB-35 | Como comprador, quiero pagar digitalmente. | P1 / 13 | PB-34; proveedor y modelo de recaudo definidos | Integración en entorno de pruebas y producción; firma de webhooks verificada; pago duplicado/fallido/pendiente resuelto; conciliación e idempotencia; nunca marcar pagado por respuesta del cliente. |
| PB-36 | Como comprador, quiero solicitar devoluciones y reembolsos. | P1 / 13 | PB-35 | Política definida, solicitud con evidencia, resolución auditada, reembolso confirmado por proveedor; actualización de existencias solo si corresponde y sin duplicados. |
| PB-37 | Como comprador, quiero elegir envío a domicilio. | P1 / 13 | PB-34; operación logística definida | Cobertura, coste, dirección privada, asignación y seguimiento; prueba de entrega; cancelación y entrega fallida con reglas explícitas. |
| PB-38 | Como comprador, quiero calificar una compra completada. | P1 / 5 | PB-34 | Una reseña por compra y autor; solo pedidos completados; moderación y agregados consistentes; vendedor puede responder sin editar la reseña. |
| PB-39 | Como usuario, quiero mejores resultados de búsqueda. | P1 / 8 | PB-10; métricas del piloto | Acentos y errores comunes, orden por relevancia, filtros combinados; evaluación con consultas de referencia; decidir motor según volumen observado. |
| PB-40 | Como vendedor, quiero medir el rendimiento de mis productos. | P1 / 5 | PB-24, PB-30 | Visitas, consultas y conversión por periodo; deduplicación básica; cada vendedor ve únicamente sus métricas y la definición de cada indicador. |
| PB-41 | Como comprador, quiero comprar a varios vendedores en una operación. | P2 / 13 | PB-35, PB-36, PB-37 | Subpedidos por vendedor, totales desglosados, fallos parciales compensados y liquidación definida; no implementar antes de resolver reglas de recaudo. |
| PB-42 | Como responsable, quiero expandir el marketplace a otras ciudades. | P2 / 8 | PB-34; demanda validada | Zonas y cobertura configurables, catálogo por ubicación, métricas por ciudad; datos privados y permisos conservan aislamiento. |
| PB-43 | Como vendedor, quiero promociones y publicaciones destacadas. | P2 / 8 | PB-35, PB-40 | Precio, vigencia y elegibilidad claros; contenido patrocinado identificado; cobro y vencimiento consistentes; métricas verificables. |

## 7. Orden de entrega

| Fase | Historias | Resultado revisable |
|---|---|---|
| 0 — Base | PB-01 a PB-05 | Acceso real, perfiles, permisos y entornos listos. |
| 1 — Catálogo conectado | PB-06 a PB-15, respetando dependencias internas | Vendedor publica; comprador busca y ve cambios en dos dispositivos. PB-13/PB-15 preceden a PB-09/PB-11. |
| 2 — Conversación y compra | PB-16, PB-17, PB-19 a PB-24 | Chat persistente y ciclo completo de pedido con pruebas de concurrencia. |
| 3 — Piloto operable | PB-18, PB-25 a PB-34 | Notificaciones, moderación, recuperación y validación completa; primera compra real. |
| 4 — V1 | PB-35 a PB-40, según datos y decisiones del piloto | Pagos digitales, posventa y servicios adicionales. |
| 5 — Expansión | PB-41 a PB-43 | Compra entre vendedores, otras ciudades y monetización. |

La prioridad dentro de cada fase sigue las dependencias. Operación, seguridad y accesibilidad deben incorporarse durante la construcción, aunque sus verificaciones finales estén agrupadas en la fase 3.

## 8. Criterio de terminado y salida del piloto

Una historia termina cuando cumple sus criterios, funciona entre app y backend con persistencia real, valida permisos en servidor, resuelve estados de carga/error/reconexión pertinentes y tiene verificaciones proporcionales al riesgo. No se aceptan respuestas simuladas en el flujo entregado.

Para lanzar el piloto:

- Todas las historias P0 aceptadas; sin defectos abiertos que impidan comprar, vender, acceder o proteger datos.
- Compra completa demostrada entre dos cuentas y dos dispositivos, incluida entrega física y registro de modalidad de pago.
- Competencia por la última unidad, vencimiento, cancelación repetida y reconexión probados sin sobreventa ni duplicación.
- Metas PB-33 medidas y documentadas; si no se alcanzan, se corrige capacidad o se acuerda un alcance piloto revisado antes de lanzar.
- Restauración ensayada, alertas activas, soporte asignado y condiciones publicadas.
- Credenciales, cuentas de tiendas y servicios externos disponibles para la distribución elegida.

Métricas de producto desde el piloto: publicaciones activas, compradores que crean un pedido, pedidos aceptados/completados/cancelados, tiempo hasta respuesta del vendedor y usuarios que repiten compra. Las metas comerciales se fijan tras obtener una línea base, sin inventar objetivos de demanda.

## 9. Decisiones que deben cerrarse al refinar

| Decisión | Propuesta inicial | Momento límite |
|---|---|---|
| Mercado y distribución | Popayán; Android piloto, iOS siguiente validación | Antes de PB-29/PB-34 |
| Identidad | Proveedor compatible con Flutter y verificación de tokens en Workers | PB-02 |
| Modalidad comercial | Recogida, contraentrega, sin comisión en piloto | Antes de PB-19 |
| Aceptación de pedidos | Reserva de 30 min; medir si es suficiente para vendedores locales | Antes de PB-20 |
| Servicio push | Proveedor que cubra Android e iOS y política de privacidad acordada | PB-18 |
| Moderación y soporte | Responsable designado, categorías prohibidas y tiempos de respuesta publicados | Antes de PB-26/PB-34 |
| Presupuesto y carga | Definir techo de gasto y verificar el escenario inicial de 100 sesiones | Antes de PB-30/PB-33 |
| Pagos digitales | Proveedor, comisiones, recaudo, liquidación y devoluciones | Antes de PB-35 |
| Conservación de datos | Responsable valida plazos y textos aplicables al negocio | Antes de PB-27/PB-34 |

Estas decisiones no bloquean la creación de la base técnica; sí deben quedar documentadas antes de sus historias dependientes.

## 10. Referencias técnicas

Documentación consultada al preparar el backlog:

- [Cloudflare: funcionamiento y consistencia de KV](https://developers.cloudflare.com/kv/concepts/how-kv-works/).
- [Cloudflare: WebSockets con Durable Objects](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).
- [Hono: despliegue en Cloudflare Workers](https://hono.dev/docs/getting-started/cloudflare-workers).

Las estimaciones, arquitectura, reglas comerciales y metas de rendimiento de este documento son propuestas del proyecto, pendientes de validación mediante implementación y pruebas.
