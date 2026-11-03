import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { auth, limit } from './security';
import { dispatch } from './live';
import { now,uid,type App } from './types';
const routes=new Hono<App>();
for(const prefix of ['/favorites','/conversations','/blocks','/reports','/admin']) { routes.use(prefix,auth);routes.use(`${prefix}/*`,auth); }
routes.get('/favorites',async c=>c.json((await c.env.DB.prepare("SELECT p.*,u.name AS seller_name FROM favorites f JOIN products p ON p.id=f.product_id JOIN users u ON u.id=p.seller_id WHERE f.user_id=? AND u.suspended=0 ORDER BY p.created_at DESC LIMIT 200").bind(c.get('user').id).all()).results));
routes.post('/favorites/:id',async c=>{
 if(!await c.env.DB.prepare('SELECT id FROM products WHERE id=?').bind(c.req.param('id')).first())throw new HTTPException(404,{message:'Producto no encontrado.'});
 await c.env.DB.prepare('INSERT OR IGNORE INTO favorites(user_id,product_id) VALUES (?,?)').bind(c.get('user').id,c.req.param('id')).run();return c.json({ok:true});
});
routes.delete('/favorites/:id',async c=>{await c.env.DB.prepare('DELETE FROM favorites WHERE user_id=? AND product_id=?').bind(c.get('user').id,c.req.param('id')).run();return c.json({ok:true});});
routes.get('/conversations',async c=>{
 const id=c.get('user').id;
 return c.json((await c.env.DB.prepare(`SELECT c.*,p.title,u.name AS other_name,(SELECT body FROM messages WHERE conversation_id=c.id ORDER BY seq DESC LIMIT 1) AS last_message,(SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id AND m.sender_id<>? AND m.seq>COALESCE((SELECT last_seq FROM reads WHERE conversation_id=c.id AND user_id=?),0)) AS unread FROM conversations c JOIN products p ON p.id=c.product_id JOIN users u ON u.id=CASE WHEN c.buyer_id=? THEN c.seller_id ELSE c.buyer_id END WHERE c.buyer_id=? OR c.seller_id=? ORDER BY COALESCE((SELECT MAX(created_at) FROM messages WHERE conversation_id=c.id),c.created_at) DESC LIMIT 100`).bind(id,id,id,id,id).all()).results);
});
routes.post('/conversations',async c=>{
 const {productId}=z.object({productId:z.string().uuid()}).parse(await c.req.json());
 const p=await c.env.DB.prepare("SELECT p.seller_id FROM products p JOIN users u ON u.id=p.seller_id WHERE p.id=? AND p.status='active' AND u.suspended=0").bind(productId).first<{seller_id:string}>();
 if(!p)throw new HTTPException(404,{message:'Publicación no disponible.'});
 if(p.seller_id===c.get('user').id)throw new HTTPException(400,{message:'Esta es tu publicación.'});
 await c.env.DB.prepare('INSERT OR IGNORE INTO conversations(id,product_id,buyer_id,seller_id,created_at) VALUES (?,?,?,?,?)').bind(uid(),productId,c.get('user').id,p.seller_id,now()).run();
 return c.json(await c.env.DB.prepare('SELECT * FROM conversations WHERE product_id=? AND buyer_id=?').bind(productId,c.get('user').id).first());
});
routes.use('/conversations/:id/*',async(c,next)=>{
 if(!await c.env.DB.prepare('SELECT id FROM conversations WHERE id=? AND (buyer_id=? OR seller_id=?)').bind(c.req.param('id'),c.get('user').id,c.get('user').id).first())throw new HTTPException(404,{message:'Conversación no disponible.'});
 await next();
});
routes.get('/conversations/:id/messages',async c=>{
 const before=z.coerce.number().int().positive().parse(c.req.query('before')??Number.MAX_SAFE_INTEGER);
 const rows=(await c.env.DB.prepare('SELECT * FROM messages WHERE conversation_id=? AND seq<? ORDER BY seq DESC LIMIT 51').bind(c.req.param('id'),before).all()).results;
 const reads=(await c.env.DB.prepare('SELECT user_id,last_seq FROM reads WHERE conversation_id=?').bind(c.req.param('id')).all()).results;
 return c.json({items:rows.slice(0,50).reverse(),before:rows.length>50?rows[49].seq:null,reads});
});
routes.post('/conversations/:id/messages',async c=>{
 await limit(c,'message',60);
 const {body,clientKey}=z.object({body:z.string().trim().min(1).max(2000),clientKey:z.string().uuid()}).parse(await c.req.json());
 const id=c.get('user').id;
 const conversation=await c.env.DB.prepare('SELECT * FROM conversations WHERE id=?').bind(c.req.param('id')).first<{buyer_id:string,seller_id:string}>();
 const other=conversation!.buyer_id===id?conversation!.seller_id:conversation!.buyer_id;
 if(await c.env.DB.prepare('SELECT user_id FROM blocks WHERE (user_id=? AND blocked_id=?) OR (user_id=? AND blocked_id=?)').bind(id,other,other,id).first())throw new HTTPException(403,{message:'El contacto está bloqueado.'});
 if(await c.env.DB.prepare('SELECT id FROM users WHERE id=? AND suspended=1').bind(other).first())throw new HTTPException(403,{message:'El contacto no está disponible.'});
 const previous=await c.env.DB.prepare('SELECT * FROM messages WHERE sender_id=? AND client_key=?').bind(id,clientKey).first();
 if(previous){if(previous.body!==body||previous.conversation_id!==c.req.param('id'))throw new HTTPException(409,{message:'Identificador ya utilizado.'});return c.json(previous);}
 const row=await c.env.DB.prepare('INSERT INTO messages(id,conversation_id,sender_id,body,client_key,created_at) VALUES (?,?,?,?,?,?) RETURNING *').bind(uid(),c.req.param('id'),id,body,clientKey,now()).first();
 c.executionCtx.waitUntil(dispatch(c.env));return c.json(row,201);
});
routes.post('/conversations/:id/read',async c=>{
 const {seq}=z.object({seq:z.number().int().nonnegative()}).parse(await c.req.json());
 const max=await c.env.DB.prepare('SELECT COALESCE(MAX(seq),0) AS seq FROM messages WHERE conversation_id=?').bind(c.req.param('id')).first<{seq:number}>();
 const last=Math.min(seq,max!.seq);
 await c.env.DB.batch([
 c.env.DB.prepare('INSERT INTO reads(conversation_id,user_id,last_seq) VALUES (?,?,?) ON CONFLICT(conversation_id,user_id) DO UPDATE SET last_seq=MAX(last_seq,excluded.last_seq)').bind(c.req.param('id'),c.get('user').id,last),
 c.env.DB.prepare("INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at) SELECT ?,CASE WHEN buyer_id=? THEN seller_id ELSE buyer_id END,'message.read',id,?,json_object('seq',?),? FROM conversations WHERE id=?").bind(uid(),c.get('user').id,last,last,now(),c.req.param('id'))]);
 c.executionCtx.waitUntil(dispatch(c.env));return c.json({ok:true});
});
routes.post('/blocks/:id',async c=>{
 const id=z.string().uuid().parse(c.req.param('id'));
 if(id===c.get('user').id||!await c.env.DB.prepare('SELECT id FROM users WHERE id=?').bind(id).first())throw new HTTPException(400,{message:'Contacto inválido.'});
 await c.env.DB.prepare('INSERT OR IGNORE INTO blocks(user_id,blocked_id) VALUES (?,?)').bind(c.get('user').id,id).run();return c.json({ok:true});
});
routes.delete('/blocks/:id',async c=>{await c.env.DB.prepare('DELETE FROM blocks WHERE user_id=? AND blocked_id=?').bind(c.get('user').id,c.req.param('id')).run();return c.json({ok:true});});
routes.post('/reports',async c=>{
 await limit(c,'reports',5,3600);
 const b=z.object({targetType:z.enum(['user','product']),targetId:z.string().uuid(),reason:z.string().trim().min(10).max(2000)}).parse(await c.req.json());
 const id=uid();await c.env.DB.prepare('INSERT INTO reports(id,reporter_id,target_type,target_id,reason,created_at) VALUES (?,?,?,?,?,?)').bind(id,c.get('user').id,b.targetType,b.targetId,b.reason,now()).run();return c.json({id},201);
});
routes.use('/admin/*',async(c,next)=>{if(c.get('user').role!=='admin')throw new HTTPException(403,{message:'Acceso restringido.'});await next();});
routes.get('/admin/reports',async c=>c.json((await c.env.DB.prepare("SELECT * FROM reports ORDER BY created_at DESC LIMIT 100").all()).results));
routes.post('/admin/reports/:id/resolve',async c=>{
 const b=z.object({action:z.enum(['dismiss','suspend']),reason:z.string().trim().min(10).max(2000)}).parse(await c.req.json());
 const report=await c.env.DB.prepare("SELECT * FROM reports WHERE id=? AND status='open'").bind(c.req.param('id')).first();
 if(!report)throw new HTTPException(409,{message:'Reporte no disponible.'});
 const statements=[c.env.DB.prepare("UPDATE reports SET status='resolved',resolution=? WHERE id=? AND status='open'").bind(b.reason,report.id),c.env.DB.prepare('INSERT INTO audit(id,actor_id,action,target_id,reason,created_at) VALUES (?,?,?,?,?,?)').bind(uid(),c.get('user').id,b.action,report.target_id,b.reason,now())];
 if(b.action==='suspend') {
  if(report.target_type==='user')statements.push(c.env.DB.prepare("UPDATE users SET suspended=1 WHERE id=? AND role<>'admin'").bind(report.target_id));
  else statements.push(c.env.DB.prepare("UPDATE products SET status='paused',version=version+1,updated_at=? WHERE id=?").bind(now(),report.target_id));
 }
 await c.env.DB.batch(statements);c.executionCtx.waitUntil(dispatch(c.env));return c.json({ok:true});
});
export default routes;
