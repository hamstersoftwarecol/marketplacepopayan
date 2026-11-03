export interface Env {
 DB: D1Database;
 PHOTOS: R2Bucket;
 CACHE: KVNamespace;
 LIVE: DurableObjectNamespace;
 APP_ENV: string;
 ALLOWED_ORIGINS: string;
 MAIL_FROM: string;
 RESEND_API_KEY?: string;
}
export interface User {
 id: string; email: string; name: string; zone: string; verified: number;
 seller: number; role: 'user' | 'admin'; suspended: number;
}
export type App = { Bindings: Env; Variables: { user: User; sessionHash: string } };
export const now = () => Math.floor(Date.now() / 1000);
export const uid = () => crypto.randomUUID();
