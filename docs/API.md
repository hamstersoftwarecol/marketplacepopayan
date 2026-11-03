# Contrato HTTP de la primera entrega

Base: `/api`. JSON en UTF-8. Sesiones: `Authorization: Bearer <token>`. Todas las rutas de datos privados validan la sesión en D1; KV no decide permisos. Los errores incluyen `error`, y en validación pueden incluir `details`.

| Método y ruta | Acceso | Uso |
|---|---|---|
| GET `/health` (fuera de `/api`) | Público | Estado del servicio |
| POST `/auth/register` | Público con límites | `email`, `password` (12–128 caracteres), `name`, `termsAccepted: true` |
| POST `/auth/verify` | Público con límites | `code` de 64 caracteres, válido 30 minutos, de un solo uso |
| POST `/auth/login` | Público con límites | Devuelve token opaco de 7 días; solo cuentas verificadas |
| POST `/auth/request-code` | Público con límites | `email`, `purpose: verify/reset` |
| POST `/auth/reset` | Público con límites | `code`, `password`; revoca sesiones y códigos del usuario |
| POST `/auth/refresh` | Sesión | Rota la sesión; invalida token anterior |
| POST `/auth/logout` | Sesión | Revoca sesión actual |
| GET/PATCH `/me` | Sesión | Perfil; edición admite `name`, `zone`, `seller` |
| GET `/categories` | Público | Caché KV con TTL de 300 s |
| GET `/products` | Público | `q`, `category`, `offset`; 20 productos por página; `mine=true` exige sesión |
| GET `/products/:id` | Público | Detalle sin datos privados de contacto |
| POST `/products` | Vendedor | `title`, `description`, `categoryId`, `zone`, `priceMinor`, `available`, `photoIds` (hasta 8) |
| PATCH `/products/:id` | Propietario | `version`, `status: active/paused/archived`; conflicto devuelve 409 |
| POST `/photos` | Vendedor | JPEG en `base64`, hasta 5 MB y 16 megapíxeles; elimina metadatos APP/EXIF/IPTC |
| GET `/photos/:id` | Público | Solo fotos enlazadas a publicaciones visibles; archivo JPEG desde R2 |
| GET `/orders` | Participante | Compras y ventas propias, 20 por página con `offset` |
| POST `/orders` | Sesión | `productId`, `quantity`, `expectedPriceMinor`; cabecera `Idempotency-Key` obligatoria |
| PATCH `/orders/:id` | Participante autorizado | `version`, `status`; cada transición comprueba rol y versión |
| GET `/favorites` | Sesión | Favoritos del usuario (hasta 200) |
| POST/DELETE `/favorites/:id` | Sesión | Guardar o quitar producto |
| GET/POST `/conversations` | Sesión | Listar propias o iniciar con `productId` |
| GET `/conversations/:id/messages` | Participante | Últimos 50; `before` pagina hacia atrás |
| POST `/conversations/:id/messages` | Participante | `body`, `clientKey` UUID; deduplicación por autor y clave |
| POST `/conversations/:id/read` | Participante | `seq` leído; limitado al máximo de la conversación |
| POST/DELETE `/blocks/:id` | Sesión | Bloquear o desbloquear un contacto |
| POST `/reports` | Sesión | `targetType: user/product`, `targetId`, `reason` |
| GET `/admin/reports` | Administrador | Cola de reportes, hasta 100 |
| POST `/admin/reports/:id/resolve` | Administrador | `action: dismiss/suspend`, `reason`; guarda auditoría |
| GET `/events?after=N` | Sesión | Eventos públicos y del propio usuario; 100/página; cursor y señal de resincronización |
| POST `/live/ticket` | Sesión | `channel: public/private`; ticket de conexión de un uso y 30 s |
| GET `/live?ticket=...` | Ticket | Upgrade WebSocket; canal de lectura; admite ping/pong |

## Pedidos

Una operación SQL crea el pedido, descuenta disponibilidad y registra eventos. Si no hay stock o el precio esperado difiere, devuelve 409 sin crear nada. Repetir la misma clave y carga devuelve el pedido original; reutilizarla para otra carga devuelve 409.

`pending → accepted → ready → completed`. Desde pending se puede rechazar, cancelar o vencer. Desde accepted/ready se puede cancelar. El vendedor acepta/rechaza/marca listo, el comprador confirma recepción, ambos pueden cancelar. Estados terminales no admiten cambios.

El total es `price_minor × quantity` en centavos de COP; se conservan precio y título del momento de compra. El pago se acuerda al recibir; no hay pasarela ni prueba electrónica de cobro en esta versión.

## Eventos

`cursor`, `eventId`, `type`, `entityId`, `entityVersion`, `occurredAt`, `payload`. El WebSocket señala cambios; el cliente recupera eventos persistidos por cursor y vuelve a consultar los datos con permisos. Un evento nunca autoriza acceso a una entidad.

Los datos públicos y privados usan hubs separados. No se manda el token de sesión en la URL del socket: se utiliza un ticket efímero, consumido antes de abrirlo. Al emitir se vuelve a comprobar la sesión; una alarma cierra conexiones revocadas o vencidas, con revisión cada minuto.

## Administración inicial

No hay registro público de administradores. El propietario debe seleccionar una cuenta verificada y asignarle el rol mediante una operación administrativa controlada en D1. La UI de administración está pendiente; las rutas están implementadas. No modificar roles desde el cliente ni incorporar claves de administrador en Flutter.
