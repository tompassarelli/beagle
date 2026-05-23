CREATE TABLE users (
  id         INTEGER PRIMARY KEY,
  username   TEXT NOT NULL,
  email      TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE posts (
  id         INTEGER PRIMARY KEY,
  author_id  INTEGER NOT NULL REFERENCES users(id),
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  view_count INTEGER NOT NULL DEFAULT 0,
  published  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE comments (
  id         INTEGER PRIMARY KEY,
  post_id    INTEGER NOT NULL REFERENCES posts(id),
  author_id  INTEGER NOT NULL REFERENCES users(id),
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

INSERT INTO users (id, username, email, created_at) VALUES
  (1, 'alice', 'alice@example.com', 1700000000),
  (2, 'bob',   'bob@example.com',   1700000001);

INSERT INTO posts (id, author_id, title, body, view_count, published) VALUES
  (1,  1, 'Hello',          'first post',  500,  1),
  (2,  1, 'Draft',          'unpublished',  10,  0),
  (3,  1, 'Tutorial',       'how-to',     1200,  1),
  (4,  1, 'Tips',           'short tips',  300,  1),
  (5,  1, 'Deep dive',      'long form',   800,  1),
  (6,  1, 'Hot take',       'opinion',    2000,  1),
  (7,  1, 'Notes',          'misc',        150,  1),
  (8,  2, 'Bob post',       'by bob',     9999,  1);
