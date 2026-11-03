import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { auth,limit } from './security';
import { now,uid,type App } from './types';
// Drop EXIF/IPTC/comments while retaining JPEG image data.
export function cleanJpeg(input:Uint8Array):Uint8Array {
 const invalid=()=>new HTTPException(400,{message:'Selecciona una fotografía JPEG válida de hasta 16 megapíxeles.'});
 if(input.length<12||input[0]!==255||input[1]!==216||input.at(-2)!==255||input.at(-1)!==217)throw invalid();
 const chunks:Uint8Array[]=[input.slice(0,2)];let offset=2,dimensions=false;
 while(offset<input.length-2){
  if(input[offset]!==255)throw invalid();const marker=input[offset+1];
  if(marker===218){if(!dimensions)throw invalid();chunks.push(input.slice(offset));break;}
  const length=(input[offset+2]<<8)|input[offset+3];
  if(length<2||offset+length+2>input.length)throw invalid();
  if([192,193,194].includes(marker)){
   if(length<8)throw invalid();const h=(input[offset+5]<<8)|input[offset+6],w=(input[offset+7]<<8)|input[offset+8];
   if(!h||!w||h*w>16000000)throw invalid();dimensions=true;
  }
  if(!(marker>=225&&marker<=239)&&marker!==254)chunks.push(input.slice(offset,offset+length+2));offset+=length+2;
 }
 if(!dimensions||offset>=input.length-2)throw invalid();
 const result=new Uint8Array(chunks.reduce((n,c)=>n+c.length,0));let position=0;
 for(const chunk of chunks){result.set(chunk,position);position+=chunk.length;}return result;
}
const routes=new Hono<App>();
routes.post('/photos',auth,async c=>{
 await limit(c,'photos',40,3600);
 if(!c.get('user').seller)throw new HTTPException(403,{message:'Activa tu perfil vendedor.'});
 const body=z.object({base64:z.string().max(7000000)}).parse(await c.req.json());
 let bytes:Uint8Array;try{bytes=Uint8Array.from(atob(body.base64),x=>x.charCodeAt(0));}catch{throw new HTTPException(400,{message:'Foto inválida.'});}
 if(bytes.length>5*1024*1024)throw new HTTPException(413,{message:'La foto supera 5 MB.'});
 const cleaned=cleanJpeg(bytes),id=uid();await c.env.PHOTOS.put(id,cleaned,{httpMetadata:{contentType:'image/jpeg'}});
 try{await c.env.DB.prepare('INSERT INTO photos(id,owner_id,created_at) VALUES (?,?,?)').bind(id,c.get('user').id,now()).run();}catch(e){await c.env.PHOTOS.delete(id);throw e;}
 return c.json({id},201);
});
routes.get('/photos/:id',async c=>{
 const id=z.string().uuid().parse(c.req.param('id'));
 const photo=await c.env.DB.prepare("SELECT ph.id FROM photos ph JOIN products p ON EXISTS(SELECT 1 FROM json_each(p.photo_ids) WHERE value=ph.id) JOIN users u ON u.id=p.seller_id WHERE ph.id=? AND p.status<>'archived' AND u.suspended=0 LIMIT 1").bind(id).first();
 if(!photo)throw new HTTPException(404,{message:'Foto no disponible.'});
 const object=await c.env.PHOTOS.get(id);if(!object)throw new HTTPException(404,{message:'Foto no disponible.'});
 return new Response(object.body,{headers:{'Content-Type':'image/jpeg','Cache-Control':'public,max-age=60','X-Content-Type-Options':'nosniff'}});
});
export default routes;
