import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { auth, constantEqual, digest, limit, passwordHash, randomToken, sendCode } from './security';
import { now, uid, type App } from './types';
const emailSchema=z.string().trim().toLowerCase().email().max(254);
const passwordSchema=z.string().min(12).max(128);
const router=new Hono<App>();
router.post('/register',async c=>{
 await limit(c,'register',10,3600);
 if(c.env.APP_ENV!=='development'&&(!c.env.RESEND_API_KEY||!c.env.MAIL_FROM))throw new HTTPException(503,{message:'El registro público estará disponible al configurar el correo de verificación.'});
 const body=z.object({email:emailSchema,password:passwordSchema,name:z.string().trim().min(2).max(80),termsAccepted:z.literal(true)}).parse(await c.req.json());
 const salt=randomToken(),id=uid(),code=randomToken();
 const existing=await c.env.DB.prepare('SELECT id FROM users WHERE email=?').bind(body.email).first();
 if(existing) return c.json({message:'Si la cuenta puede registrarse, recibirás un código de verificación.'},202);
 const hash=await passwordHash(body.password,salt);
 await c.env.DB.batch([
 c.env.DB.prepare('INSERT INTO users(id,email,name,password_hash,salt,created_at) VALUES (?,?,?,?,?,?)').bind(id,body.email,body.name,hash,salt,now()),
 c.env.DB.prepare('INSERT INTO auth_tokens(hash,user_id,purpose,expires_at) VALUES (?,?,?,?)').bind(await digest(code),id,'verify',now()+1800),
 c.env.DB.prepare("INSERT INTO consents(user_id,version,accepted_at) VALUES (?,'pilot-2026-11-03',?)").bind(id,now())]);
 const delivery=await sendCode(c.env,body.email,code,'verify');
 return c.json({message:'Revisa tu correo para verificar la cuenta.',...delivery},201);
});
router.post('/verify',async c=>{
 await limit(c,'verify',20);
 const {code}=z.object({code:z.string().length(64)}).parse(await c.req.json());
 const hash=await digest(code);
 const result=await c.env.DB.batch([
 c.env.DB.prepare("UPDATE users SET verified=1 WHERE id=(SELECT user_id FROM auth_tokens WHERE hash=? AND purpose='verify' AND expires_at>?) RETURNING id").bind(hash,now()),
 c.env.DB.prepare('DELETE FROM auth_tokens WHERE hash=?').bind(hash)]);
 if(!result[0].results.length) throw new HTTPException(400,{message:'Código inválido o vencido.'});
 return c.json({message:'Cuenta verificada. Ya puedes iniciar sesión.'});
});
router.post('/login',async c=>{
 await limit(c,'login',15,300);
 const {email,password}=z.object({email:emailSchema,password:z.string().min(1).max(128)}).parse(await c.req.json());
 const row=await c.env.DB.prepare('SELECT * FROM users WHERE email=?').bind(email).first<{id:string,password_hash:string,salt:string,verified:number,suspended:number}>();
 const computed=await passwordHash(password,row?.salt??'invalid-account-salt');
 if(!row || !constantEqual(row.password_hash,computed) || row.suspended) throw new HTTPException(401,{message:'Correo o contraseña incorrectos.'});
 if(!row.verified) throw new HTTPException(403,{message:'Verifica tu correo antes de iniciar sesión.'});
 const token=randomToken();
 await c.env.DB.prepare('INSERT INTO sessions(hash,user_id,expires_at) VALUES (?,?,?)').bind(await digest(token),row.id,now()+7*86400).run();
 return c.json({token,expiresAt:now()+7*86400});
});
router.post('/request-code',async c=>{
 await limit(c,'request-code',5,3600);
 const {email,purpose}=z.object({email:emailSchema,purpose:z.enum(['verify','reset'])}).parse(await c.req.json());
 const user=await c.env.DB.prepare('SELECT id FROM users WHERE email=? AND suspended=0').bind(email).first<{id:string}>();
 let delivery={};
 if(user){
 const code=randomToken();
 await c.env.DB.prepare('INSERT INTO auth_tokens(hash,user_id,purpose,expires_at) VALUES (?,?,?,?)').bind(await digest(code),user.id,purpose,now()+1800).run();
 delivery=await sendCode(c.env,email,code,purpose);
 }
 return c.json({message:'Si la cuenta existe, recibirás un código.',...delivery});
});
router.post('/reset',async c=>{
 await limit(c,'reset',10,300);
 const {code,password}=z.object({code:z.string().length(64),password:passwordSchema}).parse(await c.req.json());
 const hash=await digest(code),salt=randomToken(),newHash=await passwordHash(password,salt);
 // A one-use claim and all changes execute in the same D1 transaction.
 const result=await c.env.DB.batch([
 c.env.DB.prepare("UPDATE users SET password_hash=?,salt=? WHERE id=(SELECT user_id FROM auth_tokens WHERE hash=? AND purpose='reset' AND expires_at>?) RETURNING id").bind(newHash,salt,hash,now()),
 c.env.DB.prepare("DELETE FROM sessions WHERE user_id=(SELECT user_id FROM auth_tokens WHERE hash=? AND purpose='reset' AND expires_at>?)").bind(hash,now()),
 c.env.DB.prepare("DELETE FROM auth_tokens WHERE user_id=(SELECT user_id FROM auth_tokens WHERE hash=? AND purpose='reset' AND expires_at>?)").bind(hash,now())]);
 if(!result[0].results.length) throw new HTTPException(400,{message:'Código inválido o vencido.'});
 return c.json({message:'Contraseña actualizada. Inicia sesión de nuevo.'});
});
router.post('/logout',auth,async c=>{await c.env.DB.prepare('DELETE FROM sessions WHERE hash=?').bind(c.get('sessionHash')).run();return c.json({ok:true});});
router.post('/refresh',auth,async c=>{
 const token=randomToken(),expiresAt=now()+7*86400;
 await c.env.DB.batch([c.env.DB.prepare('INSERT INTO sessions(hash,user_id,expires_at) VALUES (?,?,?)').bind(await digest(token),c.get('user').id,expiresAt),c.env.DB.prepare('DELETE FROM sessions WHERE hash=?').bind(c.get('sessionHash'))]);
 return c.json({token,expiresAt});
});
export default router;
