CREATE TABLE favorites(user_id TEXT NOT NULL REFERENCES users(id),product_id TEXT NOT NULL REFERENCES products(id),PRIMARY KEY(user_id,product_id));
CREATE TABLE conversations(id TEXT PRIMARY KEY,product_id TEXT NOT NULL REFERENCES products(id),buyer_id TEXT NOT NULL REFERENCES users(id),seller_id TEXT NOT NULL REFERENCES users(id),created_at INTEGER NOT NULL,UNIQUE(product_id,buyer_id));
CREATE INDEX conversations_seller ON conversations(seller_id);
CREATE TABLE messages(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL REFERENCES conversations(id),sender_id TEXT NOT NULL REFERENCES users(id),body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),client_key TEXT NOT NULL,created_at INTEGER NOT NULL,UNIQUE(sender_id,client_key));
CREATE INDEX messages_conversation ON messages(conversation_id,seq);
CREATE TABLE reads(conversation_id TEXT NOT NULL REFERENCES conversations(id),user_id TEXT NOT NULL REFERENCES users(id),last_seq INTEGER NOT NULL,PRIMARY KEY(conversation_id,user_id));
CREATE TABLE blocks(user_id TEXT NOT NULL REFERENCES users(id),blocked_id TEXT NOT NULL REFERENCES users(id),PRIMARY KEY(user_id,blocked_id));
CREATE TABLE reports(id TEXT PRIMARY KEY,reporter_id TEXT NOT NULL REFERENCES users(id),target_type TEXT NOT NULL CHECK(target_type IN ('user','product')),target_id TEXT NOT NULL,reason TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open',resolution TEXT,created_at INTEGER NOT NULL);
CREATE TABLE audit(id TEXT PRIMARY KEY,actor_id TEXT NOT NULL REFERENCES users(id),action TEXT NOT NULL,target_id TEXT NOT NULL,reason TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE TRIGGER message_created AFTER INSERT ON messages BEGIN
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 SELECT lower(hex(randomblob(16))),buyer_id,'message.created',NEW.conversation_id,NEW.seq,json_object('id',NEW.id),NEW.created_at FROM conversations WHERE id=NEW.conversation_id;
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 SELECT lower(hex(randomblob(16))),seller_id,'message.created',NEW.conversation_id,NEW.seq,json_object('id',NEW.id),NEW.created_at FROM conversations WHERE id=NEW.conversation_id;
END;
