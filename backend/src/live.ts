import { DurableObject } from 'cloudflare:workers';
import { now, type Env } from './types';
import { sessionUser } from './security';
export class LiveHub extends DurableObject<Env> {
 async fetch(request: Request) {
  const url=new URL(request.url);
  if(url.pathname==='/broadcast') {
   const event=await request.text();
   for(const socket of this.ctx.getWebSockets()) {
    try {
     const attachment=socket.deserializeAttachment() as {hash:string,userId:string}|null;
     if(attachment?.hash && !await sessionUser(this.env,attachment.hash)){socket.close(4001,'Sesión vencida');continue;}
     socket.send(event);
    } catch { socket.close(1011,'Reconecta'); }
   }
   return new Response('ok');
  }
  if(request.headers.get('Upgrade')?.toLowerCase()!=='websocket') return new Response('WebSocket requerido',{status:426});
  const hash=request.headers.get('X-Session-Hash')??'';
  const user=await sessionUser(this.env,hash);
  if(!user) return new Response('No autorizado',{status:401});
  if(this.ctx.getWebSockets().length>=100) return new Response('Demasiadas conexiones',{status:429});
  const pair=new WebSocketPair();
  this.ctx.acceptWebSocket(pair[1]);
  pair[1].serializeAttachment({hash,userId:user.id});
  this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping','pong'));
  if(!await this.ctx.storage.getAlarm()) await this.ctx.storage.setAlarm(Date.now()+60000);
  return new Response(null,{status:101,webSocket:pair[0]});
 }
 async alarm() {
  for(const socket of this.ctx.getWebSockets()) {
   const attachment=socket.deserializeAttachment() as {hash:string};
   if(!await sessionUser(this.env,attachment.hash)) socket.close(4001,'Sesión vencida');
  }
  if(this.ctx.getWebSockets().length) await this.ctx.storage.setAlarm(Date.now()+60000);
 }
 webSocketMessage(socket: WebSocket,message: string|ArrayBuffer){ if(message!=='ping') socket.close(1008,'Canal de lectura'); }
 webSocketClose(socket: WebSocket,code:number){socket.close(code);}
}
export function eventJson(row: Record<string,unknown>) {
 return {cursor:row.seq,eventId:row.event_id,type:row.type,entityId:row.entity_id,entityVersion:row.entity_version,occurredAt:row.occurred_at,payload:JSON.parse(row.payload as string)};
}
export async function dispatch(env: Env) {
 const rows=await env.DB.prepare('SELECT * FROM events WHERE delivered=0 ORDER BY seq LIMIT 100').all<Record<string,unknown>>();
 for(const row of rows.results) {
  const hub=env.LIVE.get(env.LIVE.idFromName(String(row.audience)));
  const response=await hub.fetch('https://live/broadcast',{method:'POST',body:JSON.stringify(eventJson(row))});
  if(!response.ok) throw new Error('Event delivery failed');
  await env.DB.prepare('UPDATE events SET delivered=1 WHERE seq=?').bind(row.seq).run();
 }
}
export async function housekeeping(env: Env) {
 await env.DB.batch([
  env.DB.prepare("UPDATE orders SET status='expired',version=version+1,updated_at=? WHERE status='pending' AND expires_at<=?").bind(now(),now()),
  env.DB.prepare('DELETE FROM rate_limits WHERE expires_at<?').bind(now()),
  env.DB.prepare('DELETE FROM sessions WHERE expires_at<?').bind(now()),
  env.DB.prepare('DELETE FROM auth_tokens WHERE expires_at<?').bind(now()),
  env.DB.prepare('DELETE FROM events WHERE delivered=1 AND occurred_at<?').bind(now()-7*86400),
  env.DB.prepare('DELETE FROM ws_tickets WHERE expires_at<?').bind(now())]);
 const unused=await env.DB.prepare("SELECT id FROM photos WHERE created_at<? AND NOT EXISTS(SELECT 1 FROM products p,json_each(p.photo_ids) j WHERE j.value=photos.id) LIMIT 20").bind(now()-86400).all<{id:string}>();
 for(const photo of unused.results){await env.PHOTOS.delete(photo.id);await env.DB.prepare('DELETE FROM photos WHERE id=?').bind(photo.id).run();}
 await dispatch(env);
}
