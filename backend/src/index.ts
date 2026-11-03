import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { bodyLimit } from 'hono/body-limit';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import authRoutes from './auth';
import community from './community';
import photos from './photos';
import { auth, digest, limit, randomToken, sessionUser } from './security';
import { dispatch, eventJson, housekeeping } from './live';
import { now, uid, type App, type Env } from './types';
export { LiveHub } from './live';
const app=new Hono<App>();
app.use('*',secureHeaders());
app.use('*',async(c,next)=>bodyLimit({maxSize:c.req.path==='/api/photos'?7100000:32768,onError:c=>c.json({error:'Solicitud demasiado grande.'},413)})(c,next));
app.use('*',cors({origin:(origin,c)=>c.env.ALLOWED_ORIGINS.split(',').map((x:string)=>x.trim()).includes(origin)?origin:undefined,allowHeaders:['Authorization','Content-Type','Idempotency-Key'],allowMethods:['GET','POST','PATCH','DELETE','OPTIONS']}));
app.use('/api/*',async(c,next)=>{c.header('Cache-Control','no-store');await next();});
app.onError((error,c)=>{
 if(error instanceof HTTPException) return c.json({error:error.message},error.status);
 if(error instanceof z.ZodError) return c.json({error:'Revisa los datos ingresados.',details:error.issues.map(x=>({field:x.path.join('.'),message:x.message}))},400);
 if(error instanceof SyntaxError) return c.json({error:'JSON inválido.'},400);
 if(error.message.includes('stock_or_price_conflict')) return c.json({error:'La disponibilidad o el precio cambió. Actualiza e intenta de nuevo.'},409);
 console.error(JSON.stringify({level:'error',requestId:c.req.header('CF-Ray')??uid(),message:'request_failed'}));
 return c.json({error:'No fue posible completar la operación.'},500);
});
app.notFound(c=>c.json({error:'Recurso no encontrado.'},404));
app.get('/health',c=>c.json({ok:true,service:'marketplace-api',environment:c.env.APP_ENV}));
app.route('/api/auth',authRoutes);
app.route('/api',community);
app.route('/api',photos);
app.get('/api/me',auth,c=>c.json(c.get('user')));
app.patch('/api/me',auth,async c=>{
 const body=z.object({name:z.string().trim().min(2).max(80),zone:z.string().trim().min(2).max(80),seller:z.boolean()}).parse(await c.req.json());
 await c.env.DB.prepare('UPDATE users SET name=?,zone=?,seller=? WHERE id=?').bind(body.name,body.zone,body.seller?1:0,c.get('user').id).run();
 return c.json({ok:true});
});
app.get('/api/categories',async c=>{
 const cached=await c.env.CACHE.get('categories:v1','json');
 if(cached) return c.json(cached);
 const rows=(await c.env.DB.prepare('SELECT id,name FROM categories WHERE active=1 ORDER BY name').all()).results;
 c.executionCtx.waitUntil(c.env.CACHE.put('categories:v1',JSON.stringify(rows),{expirationTtl:300}));
 return c.json(rows);
});
const productSchema=z.object({title:z.string().trim().min(3).max(100),description:z.string().trim().min(10).max(4000),categoryId:z.string().max(40),zone:z.string().trim().min(2).max(80),priceMinor:z.number().int().positive().max(100000000000),available:z.number().int().min(0).max(1000000),photoIds:z.array(z.string().uuid()).max(8).default([])});
app.get('/api/products',async c=>{
 const query=z.object({q:z.string().max(100).default(''),category:z.string().max(40).default(''),offset:z.coerce.number().int().min(0).max(10000).default(0),mine:z.enum(['true','false']).default('false')}).parse(c.req.query());
 let seller='';
 if(query.mine==='true') {
  const raw=c.req.header('Authorization')?.replace(/^Bearer /,'')??'';
  const user=await sessionUser(c.env,await digest(raw));
  if(!user) throw new HTTPException(401,{message:'Inicia sesión.'});
  seller=user.id;
 }
 const result=await c.env.DB.prepare(`SELECT p.*,u.name AS seller_name FROM products p JOIN users u ON u.id=p.seller_id WHERE u.suspended=0 AND ((?<>'' AND p.seller_id=?) OR (?='' AND p.status='active')) AND (?='' OR p.category_id=?) AND (?='' OR instr(lower(p.title||' '||p.description),lower(?))>0) ORDER BY p.created_at DESC,p.id LIMIT 21 OFFSET ?`).bind(seller,seller,seller,query.category,query.category,query.q,query.q,query.offset).all();
 return c.json({items:result.results.slice(0,20),nextOffset:result.results.length>20?query.offset+20:null});
});
app.get('/api/products/:id',async c=>{
 const row=await c.env.DB.prepare("SELECT p.*,u.name AS seller_name FROM products p JOIN users u ON u.id=p.seller_id WHERE p.id=? AND u.suspended=0 AND p.status<>'archived'").bind(c.req.param('id')).first();
 if(!row) throw new HTTPException(404,{message:'Publicación no disponible.'});
 return c.json(row);
});
app.post('/api/products',auth,async c=>{
 await limit(c,'product-write',30);
 const user=c.get('user');
 if(!user.seller) throw new HTTPException(403,{message:'Activa tu perfil vendedor primero.'});
 const body=productSchema.parse(await c.req.json());
 if(!await c.env.DB.prepare('SELECT id FROM categories WHERE id=? AND active=1').bind(body.categoryId).first()) throw new HTTPException(400,{message:'Categoría inválida.'});
 for(const photoId of body.photoIds){if(!await c.env.DB.prepare('SELECT id FROM photos WHERE id=? AND owner_id=?').bind(photoId,user.id).first())throw new HTTPException(400,{message:'Fotografía no disponible.'});}
 const id=uid();
 await c.env.DB.prepare('INSERT INTO products(id,seller_id,title,description,category_id,zone,price_minor,available,created_at,updated_at,photo_ids) VALUES (?,?,?,?,?,?,?,?,?,?,?)').bind(id,user.id,body.title,body.description,body.categoryId,body.zone,body.priceMinor,body.available,now(),now(),JSON.stringify(body.photoIds)).run();
 c.executionCtx.waitUntil(dispatch(c.env));
 return c.json({id},201);
});
app.patch('/api/products/:id',auth,async c=>{
 const body=z.object({version:z.number().int().positive(),status:z.enum(['active','paused','archived'])}).parse(await c.req.json());
 const result=await c.env.DB.prepare('UPDATE products SET status=?,version=version+1,updated_at=? WHERE id=? AND seller_id=? AND version=? RETURNING id').bind(body.status,now(),c.req.param('id'),c.get('user').id,body.version).first();
 if(!result) throw new HTTPException(409,{message:'No tienes acceso o la publicación cambió. Actualiza.'});
 c.executionCtx.waitUntil(dispatch(c.env));return c.json(result);
});
app.get('/api/orders',auth,async c=>{
 const offset=z.coerce.number().int().min(0).max(10000).parse(c.req.query('offset')??0);
 const user=c.get('user');
 const result=await c.env.DB.prepare('SELECT * FROM orders WHERE buyer_id=? OR seller_id=? ORDER BY created_at DESC,id LIMIT 21 OFFSET ?').bind(user.id,user.id,offset).all();
 return c.json({items:result.results.slice(0,20),nextOffset:result.results.length>20?offset+20:null});
});
app.post('/api/orders',auth,async c=>{
 await limit(c,'purchase',30);
 const body=z.object({productId:z.string().uuid(),quantity:z.number().int().min(1).max(100),expectedPriceMinor:z.number().int().positive()}).parse(await c.req.json());
 const key=z.string().min(16).max(100).parse(c.req.header('Idempotency-Key'));
 const user=c.get('user'),hash=await digest(JSON.stringify(body));
 const existing=await c.env.DB.prepare('SELECT * FROM orders WHERE buyer_id=? AND idempotency_key=?').bind(user.id,key).first();
 if(existing) {
  if(existing.request_hash!==hash) throw new HTTPException(409,{message:'La clave de reintento ya se usó para otra compra.'});
  return c.json(existing);
 }
 const id=uid();
 // INSERT..SELECT and the reserve trigger are a single atomic SQL operation.
 try {
 const row=await c.env.DB.prepare(`INSERT INTO orders(id,buyer_id,seller_id,product_id,title,price_minor,quantity,idempotency_key,request_hash,expires_at,created_at,updated_at) SELECT ?,?,seller_id,id,title,?,?,?, ?,?,?,? FROM products WHERE id=? RETURNING *`).bind(id,user.id,body.expectedPriceMinor,body.quantity,key,hash,now()+1800,now(),now(),body.productId).first();
 if(!row) throw new HTTPException(404,{message:'Producto no encontrado.'});
 c.executionCtx.waitUntil(dispatch(c.env));return c.json(row,201);
 } catch(error) {
 const retry=await c.env.DB.prepare('SELECT * FROM orders WHERE buyer_id=? AND idempotency_key=?').bind(user.id,key).first();
 if(retry && retry.request_hash===hash) return c.json(retry);
 throw error;
 }
});
app.patch('/api/orders/:id',auth,async c=>{
 const body=z.object({status:z.enum(['accepted','rejected','ready','completed','cancelled']),version:z.number().int().positive()}).parse(await c.req.json());
 const user=c.get('user');
 const order=await c.env.DB.prepare('SELECT * FROM orders WHERE id=? AND (buyer_id=? OR seller_id=?)').bind(c.req.param('id'),user.id,user.id).first();
 if(!order) throw new HTTPException(404,{message:'Pedido no encontrado.'});
 const isSeller=order.seller_id===user.id;
 if((['accepted','rejected','ready'].includes(body.status)&&!isSeller)||(body.status==='completed'&&order.buyer_id!==user.id)) throw new HTTPException(403,{message:'Esta acción corresponde al otro participante.'});
 const transitions:Record<string,string[]>={pending:['accepted','rejected','cancelled'],accepted:['ready','cancelled'],ready:['completed','cancelled']};
 if(!transitions[String(order.status)]?.includes(body.status)) throw new HTTPException(409,{message:'El estado del pedido ya cambió.'});
 const row=await c.env.DB.prepare(`UPDATE orders SET status=?,version=version+1,updated_at=? WHERE id=? AND version=? AND status=? AND (status<>'pending' OR expires_at>?) RETURNING *`).bind(body.status,now(),order.id,body.version,order.status,now()).first();
 if(!row) throw new HTTPException(409,{message:'El pedido cambió o venció. Actualiza.'});
 c.executionCtx.waitUntil(dispatch(c.env));return c.json(row);
});
app.get('/api/events',auth,async c=>{
 const cursor=z.coerce.number().int().min(0).parse(c.req.query('after')??0);
 const rows=await c.env.DB.prepare("SELECT * FROM events WHERE seq>? AND (audience='*' OR audience=?) ORDER BY seq LIMIT 101").bind(cursor,c.get('user').id).all<Record<string,unknown>>();
 const min=await c.env.DB.prepare('SELECT MIN(seq) AS seq FROM events').first<{seq:number|null}>();
 return c.json({items:rows.results.slice(0,100).map(eventJson),hasMore:rows.results.length>100,resetRequired:cursor>0&&min?.seq!=null&&cursor<min.seq-1});
});
app.post('/api/live/ticket',auth,async c=>{
 await limit(c,'ws-ticket',30);
 const {channel}=z.object({channel:z.enum(['public','private'])}).parse(await c.req.json());
 const ticket=randomToken();
 await c.env.DB.prepare('INSERT INTO ws_tickets(hash,session_hash,channel,expires_at) VALUES (?,?,?,?)').bind(await digest(ticket),c.get('sessionHash'),channel==='public'?'*':c.get('user').id,now()+30).run();
 return c.json({ticket});
});
app.get('/api/live',async c=>{
 const ticket=c.req.query('ticket')??'';
 if(!/^[a-f0-9]{64}$/.test(ticket)) throw new HTTPException(401,{message:'Ticket inválido.'});
 const row=await c.env.DB.prepare('DELETE FROM ws_tickets WHERE hash=? AND expires_at>? RETURNING *').bind(await digest(ticket),now()).first<{session_hash:string,channel:string}>();
 if(!row||!await sessionUser(c.env,row.session_hash)) throw new HTTPException(401,{message:'Ticket vencido.'});
 const headers=new Headers(c.req.raw.headers);headers.set('X-Session-Hash',row.session_hash);
 return c.env.LIVE.get(c.env.LIVE.idFromName(row.channel)).fetch(new Request('https://live/connect',{headers}));
});
export default {
 fetch:app.fetch,
 scheduled:(_event:ScheduledEvent,env:Env,ctx:ExecutionContext)=>ctx.waitUntil(housekeeping(env))
};
