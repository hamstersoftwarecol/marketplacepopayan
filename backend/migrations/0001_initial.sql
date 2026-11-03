PRAGMA foreign_keys = ON;
CREATE TABLE users (
 id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL COLLATE NOCASE,
 name TEXT NOT NULL, zone TEXT NOT NULL DEFAULT 'Popayán',
 password_hash TEXT NOT NULL, salt TEXT NOT NULL,
 verified INTEGER NOT NULL DEFAULT 0, seller INTEGER NOT NULL DEFAULT 0,
 role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('user','admin')),
 suspended INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
);
CREATE TABLE sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires_at INTEGER NOT NULL);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE TABLE auth_tokens (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), purpose TEXT NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE rate_limits (key TEXT PRIMARY KEY, hits INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
INSERT INTO categories(id,name) VALUES ('hogar','Hogar'),('tecnologia','Tecnología'),('moda','Moda'),('deportes','Deportes'),('otros','Otros');
CREATE TABLE products (
 id TEXT PRIMARY KEY, seller_id TEXT NOT NULL REFERENCES users(id),
 title TEXT NOT NULL CHECK(length(title) BETWEEN 3 AND 100), description TEXT NOT NULL,
 category_id TEXT NOT NULL REFERENCES categories(id), zone TEXT NOT NULL,
 price_minor INTEGER NOT NULL CHECK(price_minor > 0),
 available INTEGER NOT NULL CHECK(available >= 0), status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','archived')),
 version INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX products_catalog ON products(status,created_at DESC,id);
CREATE TABLE orders (
 id TEXT PRIMARY KEY, buyer_id TEXT NOT NULL REFERENCES users(id), seller_id TEXT NOT NULL REFERENCES users(id),
 product_id TEXT NOT NULL REFERENCES products(id), title TEXT NOT NULL, price_minor INTEGER NOT NULL,
 quantity INTEGER NOT NULL CHECK(quantity BETWEEN 1 AND 100),
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','ready','completed','cancelled','rejected','expired')),
 idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL,
 expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 version INTEGER NOT NULL DEFAULT 1, UNIQUE(buyer_id,idempotency_key)
);
CREATE INDEX orders_buyer ON orders(buyer_id,created_at DESC);
CREATE INDEX orders_seller ON orders(seller_id,created_at DESC);
CREATE INDEX orders_expiry ON orders(status,expires_at);
CREATE TABLE events (
 seq INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
 audience TEXT NOT NULL, type TEXT NOT NULL, entity_id TEXT NOT NULL,
 entity_version INTEGER NOT NULL, payload TEXT NOT NULL, occurred_at INTEGER NOT NULL,
 delivered INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX events_delivery ON events(delivered,seq);
CREATE INDEX events_audience ON events(audience,seq);
CREATE TRIGGER order_reserve BEFORE INSERT ON orders BEGIN
 SELECT CASE WHEN NOT EXISTS (
   SELECT 1 FROM products p JOIN users u ON u.id=p.seller_id
   WHERE p.id=NEW.product_id AND p.status='active' AND u.suspended=0
   AND p.seller_id=NEW.seller_id AND p.seller_id<>NEW.buyer_id
   AND p.available>=NEW.quantity AND p.price_minor=NEW.price_minor
 ) THEN RAISE(ABORT,'stock_or_price_conflict') END;
 UPDATE products SET available=available-NEW.quantity, version=version+1, updated_at=NEW.created_at WHERE id=NEW.product_id;
END;
CREATE TRIGGER order_transition BEFORE UPDATE OF status ON orders BEGIN
 SELECT CASE WHEN NOT (
  (OLD.status='pending' AND NEW.status IN ('accepted','rejected','cancelled','expired')) OR
  (OLD.status='accepted' AND NEW.status IN ('ready','cancelled')) OR
  (OLD.status='ready' AND NEW.status IN ('completed','cancelled'))
 ) THEN RAISE(ABORT,'invalid_transition') END;
END;
CREATE TRIGGER order_release AFTER UPDATE OF status ON orders
WHEN NEW.status IN ('cancelled','rejected','expired') BEGIN
 UPDATE products SET available=available+NEW.quantity, version=version+1, updated_at=NEW.updated_at WHERE id=NEW.product_id;
END;
CREATE TRIGGER product_created AFTER INSERT ON products BEGIN
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 VALUES(lower(hex(randomblob(16))),'*','product.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.updated_at);
END;
CREATE TRIGGER product_updated AFTER UPDATE ON products BEGIN
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 VALUES(lower(hex(randomblob(16))),'*','product.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.updated_at);
END;
CREATE TRIGGER order_created AFTER INSERT ON orders BEGIN
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 VALUES(lower(hex(randomblob(16))),NEW.buyer_id,'order.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.created_at),
 (lower(hex(randomblob(16))),NEW.seller_id,'order.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.created_at);
END;
CREATE TRIGGER order_updated AFTER UPDATE ON orders BEGIN
 INSERT INTO events(event_id,audience,type,entity_id,entity_version,payload,occurred_at)
 VALUES(lower(hex(randomblob(16))),NEW.buyer_id,'order.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.updated_at),
 (lower(hex(randomblob(16))),NEW.seller_id,'order.updated',NEW.id,NEW.version,json_object('id',NEW.id),NEW.updated_at);
END;
