import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';
const wrangler=join(process.cwd(),'node_modules/wrangler/bin/wrangler.js');
const state=mkdtempSync(join(tmpdir(),'marketplace-test-'));
const port=19000+Math.floor(Math.random()*10000), base=`http://127.0.0.1:${port}`;
const password='Prueba-segura-2026!';
let server,logs='';
async function api(path,{method='GET',token,body,key}={}) {
 const r=await fetch(`${base}/api${path}`,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`} : {}),...(key?{'Idempotency-Key':key}:{})},body:body?JSON.stringify(body):undefined});
 return {status:r.status,data:await r.json()};
}
async function account(name) {
 const email=`${name}-${randomUUID()}@example.com`;
 const registered=await api('/auth/register',{method:'POST',body:{email,password,name,termsAccepted:true}});
 assert.equal(registered.status,201,JSON.stringify(registered.data));
 const code=registered.data.developmentCode;assert.ok(code);
 assert.equal((await api('/auth/verify',{method:'POST',body:{code}})).status,200);
 assert.equal((await api('/auth/verify',{method:'POST',body:{code}})).status,400);
 const login=await api('/auth/login',{method:'POST',body:{email,password}});assert.equal(login.status,200);
 const token=login.data.token,me=await api('/me',{token});return {token,id:me.data.id,email};
}
test('Marketplace: integración real con D1, KV y Durable Objects',async t=>{
 try {
  const migrated=spawnSync(process.execPath,[wrangler,'d1','migrations','apply','marketplace','--local','--persist-to',state],{encoding:'utf8'});
  assert.equal(migrated.status,0,migrated.stderr);
  server=spawn(process.execPath,[wrangler,'dev','--port',String(port),'--persist-to',state],{stdio:['ignore','pipe','pipe']});
  server.stdout.on('data',x=>logs+=x);server.stderr.on('data',x=>logs+=x);
  let ready=false;for(let i=0;i<80;i++){try{if((await fetch(`${base}/health`)).ok){ready=true;break;}}catch{}await delay(250);}assert.ok(ready,logs);
  let seller,buyer,other,productId,order;
  await t.test('registro, verificación de un uso y sesiones',async()=>{
   seller=await account('Vendedor');buyer=await account('Comprador');other=await account('Tercero');
   assert.equal((await api('/me')).status,401);
   assert.equal((await api('/auth/login',{method:'POST',body:{email:buyer.email,password:'incorrecta'}})).status,401);
  });
  await t.test('perfil vendedor, catálogo y caché KV',async()=>{
   const body={title:'Mesa de prueba',description:'Mesa local en buen estado para recogida.',categoryId:'hogar',zone:'Centro',priceMinor:2500000,available:1};
   assert.equal((await api('/products',{method:'POST',token:seller.token,body})).status,403);
   assert.equal((await api('/me',{method:'PATCH',token:seller.token,body:{name:'Vendedor local',zone:'Centro',seller:true,role:'admin'}})).status,200);
   assert.equal((await api('/me',{token:seller.token})).data.role,'user');
   assert.ok((await api('/categories')).data.length>0);assert.ok((await api('/categories')).data.length>0);
   const uploaded=await api('/photos',{method:'POST',token:seller.token,body:{base64:readFileSync('test/fixtures/product.jpg').toString('base64')}});assert.equal(uploaded.status,201,JSON.stringify(uploaded.data));body.photoIds=[uploaded.data.id];
   const r=await api('/products',{method:'POST',token:seller.token,body});assert.equal(r.status,201);productId=r.data.id;
   assert.equal((await fetch(`${base}/api/photos/${uploaded.data.id}`)).status,200);
   assert.equal((await api(`/products/${productId}`)).data.available,1);
  });
  await t.test('evento WebSocket persistente por Durable Object',async()=>{
   const ticket=await api('/live/ticket',{method:'POST',token:buyer.token,body:{channel:'public'}});assert.equal(ticket.status,200);
   const ws=new WebSocket(`${base.replace('http','ws')}/api/live?ticket=${ticket.data.ticket}`);
   try {
    await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
    const incoming=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('No llegó el evento')),8000);ws.addEventListener('message',e=>{clearTimeout(timer);resolve(JSON.parse(e.data));},{once:true});});
    const p=await api(`/products/${productId}`);await api(`/products/${productId}`,{method:'PATCH',token:seller.token,body:{status:'active',version:p.data.version}});
    const event=await incoming;assert.equal(event.type,'product.updated');assert.ok(event.eventId);
   }finally{ws.close();}
  });
  const purchase=()=>({productId,quantity:1,expectedPriceMinor:2500000});
  await t.test('concurrencia por la última unidad sin sobreventa',async()=>{
   const results=await Promise.all([api('/orders',{method:'POST',token:buyer.token,key:randomUUID(),body:purchase()}),api('/orders',{method:'POST',token:other.token,key:randomUUID(),body:purchase()})]);
   assert.deepEqual(results.map(r=>r.status).sort(),[201,409]);order=results.find(r=>r.status===201).data;
   if(order.buyer_id===other.id)[buyer,other]=[other,buyer];
   assert.equal((await api(`/products/${productId}`)).data.available,0);
  });
  await t.test('reintento de compra idempotente',async()=>{
   const retry=await api('/orders',{method:'POST',token:buyer.token,key:order.idempotency_key,body:purchase()});assert.equal(retry.status,200);assert.equal(retry.data.id,order.id);
   assert.equal((await api('/orders',{method:'POST',token:buyer.token,key:order.idempotency_key,body:{...purchase(),quantity:2}})).status,409);
  });
  await t.test('permisos y versiones en cambios de pedido',async()=>{
   assert.equal((await api(`/orders/${order.id}`,{method:'PATCH',token:other.token,body:{status:'cancelled',version:1}})).status,404);
   assert.equal((await api(`/orders/${order.id}`,{method:'PATCH',token:buyer.token,body:{status:'accepted',version:1}})).status,403);
   assert.equal((await api(`/orders/${order.id}`,{method:'PATCH',token:seller.token,body:{status:'accepted',version:99}})).status,409);
   const r=await api(`/orders/${order.id}`,{method:'PATCH',token:seller.token,body:{status:'accepted',version:1}});assert.equal(r.status,200);order=r.data;
  });
  await t.test('cancelaciones concurrentes restituyen solo una vez',async()=>{
   const results=await Promise.all([1,2].map(()=>api(`/orders/${order.id}`,{method:'PATCH',token:buyer.token,body:{status:'cancelled',version:order.version}})));
   assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);assert.equal((await api(`/products/${productId}`)).data.available,1);
  });
  await t.test('recuperación de eventos con aislamiento de pedidos',async()=>{
   assert.ok((await api('/events?after=0',{token:buyer.token})).data.items.some(e=>e.entityId===order.id));
   assert.ok(!(await api('/events?after=0',{token:other.token})).data.items.some(e=>e.entityId===order.id));
   assert.equal((await api('/live/ticket',{method:'POST',body:{channel:'private'}})).status,401);
  });
  await t.test('vencimiento programado libera una reserva una sola vez',async()=>{
   const created=await api('/orders',{method:'POST',token:buyer.token,key:randomUUID(),body:purchase()});assert.equal(created.status,201);
   const expired=spawnSync(process.execPath,[wrangler,'d1','execute','marketplace','--local','--persist-to',state,'--command',`UPDATE orders SET expires_at=0 WHERE id='${created.data.id}'`],{encoding:'utf8'});assert.equal(expired.status,0,expired.stderr);
   for(let i=0;i<2;i++){const scheduled=await fetch(`${base}/cdn-cgi/local/scheduled`);assert.ok(scheduled.ok,await scheduled.text());}
   for(let i=0;i<20;i++){if((await api(`/products/${productId}`)).data.available===1)break;await delay(100);}
   assert.equal((await api(`/products/${productId}`)).data.available,1);
   const orders=await api('/orders',{token:buyer.token});assert.equal(orders.data.items.find(o=>o.id===created.data.id).status,'expired');
  });
  await t.test('compra completa y estado terminal',async()=>{
   const created=await api('/orders',{method:'POST',token:buyer.token,key:randomUUID(),body:purchase()});assert.equal(created.status,201);let current=created.data;
   for(const [status,actor] of [['accepted',seller],['ready',seller],['completed',buyer]]){const r=await api(`/orders/${current.id}`,{method:'PATCH',token:actor.token,body:{status,version:current.version}});assert.equal(r.status,200);current=r.data;}
   assert.equal((await api(`/orders/${current.id}`,{method:'PATCH',token:buyer.token,body:{status:'cancelled',version:current.version}})).status,409);
   assert.equal((await api(`/products/${productId}`)).data.available,0);
  });
  await t.test('favoritos, chat privado, reintentos, lectura y bloqueo',async()=>{
   assert.equal((await api(`/favorites/${productId}`,{method:'POST',token:buyer.token})).status,200);
   assert.equal((await api('/favorites',{token:buyer.token})).data.length,1);
   const conversation=await api('/conversations',{method:'POST',token:buyer.token,body:{productId}});
   assert.equal(conversation.status,200);const id=conversation.data.id;
   assert.equal((await api(`/conversations/${id}/messages`,{token:other.token})).status,404);
   const body={body:'Hola, ¿dónde acordamos la recogida?',clientKey:randomUUID()};
   assert.equal((await api(`/conversations/${id}/messages`,{method:'POST',token:buyer.token,body})).status,201);
   assert.equal((await api(`/conversations/${id}/messages`,{method:'POST',token:buyer.token,body})).status,200);
   const messages=await api(`/conversations/${id}/messages`,{token:seller.token});
   assert.equal(messages.data.items.length,1);
   assert.equal((await api(`/conversations/${id}/read`,{method:'POST',token:seller.token,body:{seq:messages.data.items[0].seq}})).status,200);
   assert.equal((await api(`/blocks/${buyer.id}`,{method:'POST',token:seller.token})).status,200);
   assert.equal((await api(`/conversations/${id}/messages`,{method:'POST',token:buyer.token,body:{...body,clientKey:randomUUID()}})).status,403);
   assert.equal((await api('/admin/reports',{token:buyer.token})).status,403);
   assert.equal((await api('/reports',{method:'POST',token:buyer.token,body:{targetType:'product',targetId:productId,reason:'Revisar esta publicación del piloto de pruebas.'}})).status,201);
  });
  await t.test('recuperación revoca sesiones y consume el código',async()=>{
   const r=await api('/auth/request-code',{method:'POST',body:{email:buyer.email,purpose:'reset'}});const code=r.data.developmentCode;
   assert.equal((await api('/auth/reset',{method:'POST',body:{code,password:'Nueva-segura-2026!'}})).status,200);
   assert.equal((await api('/me',{token:buyer.token})).status,401);
   assert.equal((await api('/auth/reset',{method:'POST',body:{code,password:'Otra-segura-2026!'}})).status,400);
  });
  await t.test('logout invalida la sesión',async()=>{assert.equal((await api('/auth/logout',{method:'POST',token:seller.token})).status,200);assert.equal((await api('/me',{token:seller.token})).status,401);});
 }finally{
  if(server){server.kill('SIGTERM');await new Promise(resolve=>{server.once('exit',resolve);setTimeout(resolve,3000);});}
  rmSync(state,{recursive:true,force:true});
 }
});
