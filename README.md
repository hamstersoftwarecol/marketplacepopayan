# Marketplace Popayán

Aplicación Flutter (Android, iOS y vista web) y API Hono sobre Cloudflare Workers. D1 conserva datos transaccionales; KV almacena categorías en caché; Durable Objects distribuye eventos con WebSockets; R2 conserva fotografías.

**Estado:** primera entrega funcional en entorno de pruebas. No equivale a completar todos los criterios del backlog ni está habilitada para operar comercialmente. Consulta [el alcance entregado](docs/ESTADO.md) y el [backlog aprobado](PRODUCT_BACKLOG.md).

## Ejecutar localmente

Requisitos: Node 24, npm y Flutter 3.47.9 o compatible.

En una terminal:

```sh
cd backend
npm ci
npm run db:migrate
npm run dev
```

En otra terminal:

```sh
cd mobile
flutter pub get
flutter run -d chrome --web-port=8080 --dart-define=API_URL=http://localhost:8787
```

En un emulador Android usa `http://10.0.2.2:8787` como `API_URL`. En un teléfono físico usa la IP de tu equipo en la misma red. Para instalar contra el servidor publicado usa su URL HTTPS. Android permite HTTP únicamente en la compilación de depuración.

1. Crea una cuenta y acepta las condiciones del entorno de desarrollo.
2. En desarrollo, el código de verificación se completa automáticamente en la pantalla; en staging/producción nunca se devuelve por la API y se envía por correo cuando Resend está configurado.
3. En **Mi cuenta**, activa el perfil vendedor; publica un producto con fotografía JPEG (la app convierte las fotos seleccionadas a JPEG).
4. Abre otra sesión en otro navegador o dispositivo, crea una cuenta compradora y prueba chat, favoritos y compra.
5. El vendedor acepta el pedido y lo marca listo; el comprador confirma recepción. También puedes probar rechazo o cancelación.

La base local persiste en `backend/.wrangler/state`; las pruebas usan otra base temporal y la eliminan al terminar. No existen contraseñas universales, cuentas administrativas precargadas ni catálogos simulados.

## Comprobaciones

```sh
cd backend
npm run check
npm test
```

```sh
cd mobile
flutter analyze
flutter test
flutter build web --dart-define=API_URL=https://TU_API
```

La integración levanta Workers localmente con D1, KV, R2 y Durable Objects reales del emulador. Verifica acceso, publicación con foto, WebSockets, concurrencia por stock, idempotencia, cancelación, privacidad del chat, bloqueo y recuperación de contraseña.

En desarrollo las tareas programadas no se ejecutan solas. Para ensayar vencimientos y reintentos:

```sh
curl http://localhost:8787/cdn-cgi/local/scheduled
```

En staging está configurada la ejecución cada minuto. Los eventos pendientes se reintentan; el cliente recupera eventos persistidos y vuelve a consultar las entidades. La entrega puede repetirse y no debe interpretarse como exactamente una vez.

## Despliegue

El entorno `staging` ya tiene recursos separados y se publicó en la cuenta autorizada. `production` exige crear y enlazar sus propios recursos antes de publicar.

```sh
cd backend
npx wrangler login
npm run db:migrate:staging
npm run deploy
```

Para Resend: verifica tu dominio en Resend, establece `MAIL_FROM` en las variables de staging con un remitente autorizado y guarda la clave sin escribirla en archivos versionados:

```sh
cd backend
npx wrangler secret put RESEND_API_KEY --env staging
npm run deploy
```

La clave se introduce en la solicitud interactiva de Wrangler. No debe enviarse por chat. Mientras falten remitente o clave, el registro público responde 503 antes de crear una cuenta.

Para actualizar la vista web:

```sh
cd mobile
flutter build web --dart-define=API_URL=https://marketplace-popayan-staging.business-alejandrolopezmurillo.workers.dev
../backend/node_modules/.bin/wrangler deploy
```

Mantén su dominio en `ALLOWED_ORIGINS` de la API. La vista web es una compilación de la misma aplicación Flutter; Android/iOS usan directamente la API. La publicación en tiendas y firma de distribución móvil aún están pendientes.

## Organización

- `backend/src`: rutas, acceso, sincronización y Durable Object.
- `backend/migrations`: esquema, restricciones y disparadores transaccionales.
- `backend/test`: integración aislada y fotografía de prueba de 16 × 16 píxeles.
- `mobile/lib`: aplicación, cliente HTTP y reconexión.
- `docs`: estado de implementación y contrato HTTP.
- `.github/workflows/check.yml`: comprobaciones automáticas al subir cambios a GitHub.

Referencias de plataforma: [Hono en Workers](https://hono.dev/docs/getting-started/cloudflare-workers), [transacciones D1](https://developers.cloudflare.com/d1/worker-api/d1-database/), [WebSockets con Durable Objects](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).
