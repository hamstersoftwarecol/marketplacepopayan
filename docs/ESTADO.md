# Estado de implementación

Actualizado: 3 de noviembre de 2026.

## Entrega disponible

- API desplegada: https://marketplace-popayan-staging.business-alejandrolopezmurillo.workers.dev
- Vista de revisión Flutter: https://marketplace-popayan-app.business-alejandrolopezmurillo.workers.dev
- Cloudflare staging tiene D1, KV, R2, Durable Objects y una tarea programada cada minuto. No se han creado recursos de producción.
- Registro público bloqueado hasta establecer `MAIL_FROM` y el secreto `RESEND_API_KEY`. El usuario eligió Resend; dominio pendiente.
- Desarrollo local permite verificar cuentas y recuperar acceso sin proveedor de correo. La API solo devuelve esos códigos si `APP_ENV=development`.

## Funciona de extremo a extremo en desarrollo

Registro, verificación, acceso, recuperación, revocación y renovación de sesiones; perfil comprador/vendedor; categorías; publicación con fotografías; catálogo, búsqueda por texto y categoría y paginación; detalle; pausar/activar; favoritos; conversación privada con mensajes persistentes, lectura, bloqueo y reconexión; compra de un producto con cantidad, reserva atómica, aceptación, rechazo, recogida, confirmación y cancelación; recuperación de eventos y canal en vivo.

Los pedidos son de una publicación por operación en esta entrega; aún no existe un carrito de varias publicaciones del mismo vendedor. El pago es al recibir y la plataforma no recauda dinero.

## Avance frente al backlog

| Área | Estado y límite |
|---|---|
| PB-01–05 Base y acceso | Implementación funcional; staging publicado, producción sin recursos. Sin auditoría externa de seguridad. Resend pendiente de dominio/clave. |
| PB-06 Categorías | Lectura/cache y categorías iniciales; CRUD administrativo pendiente. |
| PB-07 Fotografías | R2, carga hasta 8, validación JPEG, eliminación de metadatos, limpieza de cargas huérfanas. Compresión en Flutter. Falta probar cámaras/formatos en dispositivos físicos. |
| PB-08–09 Publicaciones | Alta, detalle, activación/pausa/archivo en API. Edición completa, borradores y gestión avanzada de stock pendientes. La UI exige foto; la API aún admite publicaciones sin foto. |
| PB-10–12 Descubrimiento | Texto, categoría, paginación y favoritos; filtros por precio/zona y cambio de orden pendientes. |
| PB-13–15 Tiempo real | Canales públicos/privados, tickets, reconexión, cursor y outbox transaccional. Meta p95 de 2 s pendiente de prueba de carga. Reintento de socket cada 5 s; espera progresiva con variación pendiente. |
| PB-16–17 Chat | Conversaciones, texto, paginación, persistencia, deduplicación y leído; indicador de entrega al dispositivo y contador en todos los escenarios multi-dispositivo pendientes. |
| PB-18 Avisos | Cambios de pedido/chat llegan en primer plano. Centro de notificaciones y push móvil pendientes. |
| PB-19–24 Compras | Flujo de pedido de una publicación; reserva, transiciones y devolución de stock transaccionales. Carrito, motivo/historial detallado, declaración de pago y panel de métricas pendientes. |
| PB-25–26 Confianza | Reportes desde producto y bloqueo desde chat. API administrativa con rol y auditoría; interfaz administrativa y pruebas específicas de moderación pendientes. |
| PB-27 Privacidad | Separación de datos y aceptación versionada; condiciones de desarrollo disponibles. Exportación/eliminación y textos para operación comercial pendientes. |
| PB-28–29 Experiencia | Español, COP, estados de error/carga y reconexión. Caché local sin conexión, borradores duraderos y auditoría completa de accesibilidad pendientes. |
| PB-30–31 Operación | Logs sin credenciales/cuerpo del chat y observabilidad activada. Alertas de consumo, copias, restauración y simulacro pendientes. |
| PB-32–34 Lanzamiento | Integración local comprobada y vista web publicada. No se ha validado compra física, carga de 100 sesiones, soporte ni distribución en tiendas. |
| PB-35–43 V1 y expansión | Pendientes conforme al backlog aprobado. |

**Ninguna épica completa debe darse por aceptada únicamente por esta tabla.** El backlog original conserva sus criterios; esta entrega es un avance verificable y no sustituye la aceptación del piloto.

## Verificación

- TypeScript: `npm run check`.
- Integración: 13 escenarios y la prueba contenedora, 14 pruebas reportadas por Node; D1, KV, R2 y Durable Objects emulados en un estado temporal aislado.
- Incluye carrera de dos compradores por una unidad, cancelación concurrente, reintento de compra/mensaje, aislamiento de pedidos y chat, bloqueo y revocación al recuperar contraseña.
- Flutter: análisis sin incidencias, pruebas de interfaz y formato de COP, compilación web.
- Android: APK de depuración generado. iOS: compilación para dispositivo correcta sin firma; necesita firma antes de instalar. No se han ejecutado los flujos en dispositivos físicos.

## Para seguir

1. Verificar dominio en Resend, establecer remitente y guardar la clave mediante Wrangler; comprobar correo real y recuperación en staging.
2. Probar los flujos en dos dispositivos físicos; completar edición, carrito e historial antes del piloto.
3. Completar administración, privacidad, notificaciones y operación según P0.
4. Medir carga, ensayar restauración y aceptar criterios del piloto antes de abrirlo comercialmente.
