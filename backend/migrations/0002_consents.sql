CREATE TABLE consents(user_id TEXT NOT NULL REFERENCES users(id), version TEXT NOT NULL, accepted_at INTEGER NOT NULL, PRIMARY KEY(user_id,version));
