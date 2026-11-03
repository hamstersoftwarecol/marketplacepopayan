import { HTTPException } from 'hono/http-exception';
import type { Context, MiddlewareHandler } from 'hono';
import type { App, Env, User } from './types';
import { now } from './types';
export const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
export const randomToken = () => hex(crypto.getRandomValues(new Uint8Array(32)).buffer);
export const digest = async (value: string) => hex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)));
export async function passwordHash(password: string, salt: string) {
 const key = await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);
 return hex(await crypto.subtle.deriveBits({name:'PBKDF2',salt:new TextEncoder().encode(salt),iterations:100000,hash:'SHA-256'},key,256));
}
export function constantEqual(a: string,b: string) {
 let diff=a.length^b.length; for(let i=0;i<Math.max(a.length,b.length);i++) diff|=(a.charCodeAt(i)||0)^(b.charCodeAt(i)||0); return diff===0;
}
export async function sessionUser(env: Env, hash: string): Promise<User | null> {
 return env.DB.prepare(`SELECT u.id,u.email,u.name,u.zone,u.verified,u.seller,u.role,u.suspended FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.hash=? AND s.expires_at>? AND u.suspended=0 AND u.verified=1`).bind(hash,now()).first<User>();
}
export const auth: MiddlewareHandler<App> = async (c,next) => {
 const token = c.req.header('Authorization')?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
 if(!token) throw new HTTPException(401,{message:'Inicia sesión para continuar.'});
 const hash=await digest(token); const user=await sessionUser(c.env,hash);
 if(!user) throw new HTTPException(401,{message:'La sesión venció o no está disponible.'});
 c.set('user',user); c.set('sessionHash',hash); await next();
};
export async function limit(c: Context<App>, scope: string, count: number, seconds=60) {
 const ip=c.req.header('CF-Connecting-IP') ?? 'local';
 const key=`${scope}:${ip}:${Math.floor(now()/seconds)}`;
 const row=await c.env.DB.prepare(`INSERT INTO rate_limits(key,hits,expires_at) VALUES (?,1,?) ON CONFLICT(key) DO UPDATE SET hits=hits+1 RETURNING hits`).bind(key,now()+seconds).first<{hits:number}>();
 if(row!.hits>count) throw new HTTPException(429,{message:'Demasiados intentos. Intenta más tarde.'});
}
export async function sendCode(env: Env,email: string,code: string,purpose: string) {
 if(env.APP_ENV==='development') return {developmentCode:code};
 if(!env.RESEND_API_KEY || !env.MAIL_FROM) throw new HTTPException(503,{message:'El servicio de correo aún no está configurado.'});
 const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${env.RESEND_API_KEY}`,'Content-Type':'application/json'},body:JSON.stringify({from:env.MAIL_FROM,to:[email],subject:purpose==='verify'?'Verifica tu cuenta de Marketplace Popayán':'Recupera tu acceso',text:`Tu código es: ${code}\nVence en 30 minutos. No lo compartas.`})});
 if(!response.ok) throw new HTTPException(503,{message:'No fue posible enviar el correo. Intenta nuevamente.'});
 return {};
}
