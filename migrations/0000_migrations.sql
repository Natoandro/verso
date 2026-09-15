-- Bootstrap metadata for Verso's migration runner.
--
-- WAL mode and per-connection safety PRAGMAs are configured by Database.open.
-- This idempotent ledger setup runs before migrations are inspected.

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL UNIQUE,
    checksum_sha256 TEXT NOT NULL UNIQUE
        CHECK (
            length(checksum_sha256) = 64
            AND checksum_sha256 NOT GLOB '*[^0123456789abcdef]*'
        ),
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;
