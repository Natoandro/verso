-- Bootstrap metadata for Verso's future migration runner.
--
-- journal_mode is deliberately outside a transaction because SQLite changes it
-- at the database-file level. Every connection must also enable foreign_keys.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL UNIQUE,
    checksum_sha256 TEXT NOT NULL UNIQUE
        CHECK (
            length(checksum_sha256) = 64
            AND checksum_sha256 NOT GLOB '*[^0123456789abcdef]*'
        ),
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;
