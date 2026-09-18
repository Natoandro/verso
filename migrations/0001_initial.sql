-- Verso's initial canonical SQLite schema.
--
-- The future migration runner first applies 0000_migrations.sql, which owns
-- connection setup and the migration ledger, then records this file there.

CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    subject TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL CHECK (length(trim(display_name)) > 0),
    email TEXT UNIQUE COLLATE NOCASE,
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'disabled')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

-- A local credential is optional: users may instead be resolved by an
-- external provider. The login identifier is not a secret; the password
-- column must contain a memory-hard PHC password hash only.
CREATE TABLE local_password_credentials (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    login TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (
        length(login) BETWEEN 1 AND 320
        AND login = trim(login)
    ),
    password_hash TEXT NOT NULL CHECK (
        length(password_hash) BETWEEN 1 AND 512
    ),
    password_changed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE TABLE user_roles (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'manager', 'editor', 'author', 'contributor')),
    granted_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    granted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (user_id, role)
) STRICT;

CREATE TABLE role_capabilities (
    role TEXT NOT NULL CHECK (role IN ('owner', 'manager', 'editor', 'author', 'contributor')),
    capability TEXT NOT NULL CHECK (capability IN (
        'document:create', 'document:read:assigned', 'document:read:any',
        'document:update:assigned', 'document:update:any', 'document:assign_editor',
        'document:review', 'document:publish', 'document:finalize',
        'document:archive:manage', 'author:manage', 'asset:read', 'asset:upload',
        'interactive:create', 'interactive:publish', 'user:manage'
    )),
    PRIMARY KEY (role, capability)
) STRICT;

-- Authors are attribution records. They are not authorization principals.
CREATE TABLE authors (
    id INTEGER PRIMARY KEY,
    user_id INTEGER UNIQUE REFERENCES users(id) ON DELETE SET NULL,
    display_name TEXT NOT NULL CHECK (length(trim(display_name)) > 0),
    slug TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(slug)) > 0),
    biography TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE TABLE documents (
    id INTEGER PRIMARY KEY,
    type TEXT NOT NULL CHECK (length(trim(type)) > 0),
    finalized_at TEXT,
    finalized_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (
        (finalized_at IS NULL AND finalized_by IS NULL)
        OR (finalized_at IS NOT NULL AND finalized_by IS NOT NULL)
    )
) STRICT;

CREATE TABLE series (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    slug TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(slug)) > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE TABLE subjects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(name)) > 0),
    slug TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(slug)) > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE TABLE document_versions (
    id INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL CHECK (version_number > 0),
    based_on_version_id INTEGER REFERENCES document_versions(id) ON DELETE RESTRICT
        DEFERRABLE INITIALLY DEFERRED,
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'review', 'published', 'archived')),
    slug TEXT NOT NULL COLLATE NOCASE CHECK (length(trim(slug)) > 0),
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    description TEXT,
    language TEXT NOT NULL CHECK (length(trim(language)) > 0),
    series_id INTEGER REFERENCES series(id) ON DELETE RESTRICT,
    series_position INTEGER CHECK (series_position > 0),
    revision_number INTEGER NOT NULL DEFAULT 0 CHECK (revision_number >= 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    published_at TEXT,
    archive_accessible INTEGER CHECK (archive_accessible IN (0, 1)),
    UNIQUE (document_id, version_number),
    CHECK (
        (series_id IS NULL AND series_position IS NULL)
        OR (series_id IS NOT NULL AND series_position IS NOT NULL)
    ),
    CHECK (
        (state IN ('draft', 'review') AND published_at IS NULL AND archive_accessible IS NULL)
        OR (state = 'published' AND published_at IS NOT NULL AND archive_accessible IS NULL)
        OR (state = 'archived' AND published_at IS NOT NULL AND archive_accessible IS NOT NULL)
    )
) STRICT;

ALTER TABLE documents ADD COLUMN current_published_version_id INTEGER
    REFERENCES document_versions(id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE UNIQUE INDEX document_versions_one_published_per_document
    ON document_versions (document_id) WHERE state = 'published';
CREATE UNIQUE INDEX document_versions_one_mutable_per_document
    ON document_versions (document_id) WHERE state IN ('draft', 'review');
CREATE UNIQUE INDEX document_versions_current_slug
    ON document_versions (document_id, slug) WHERE state = 'published';
CREATE UNIQUE INDEX document_versions_published_series_position
    ON document_versions (series_id, series_position)
    WHERE state = 'published' AND series_id IS NOT NULL;
CREATE INDEX document_versions_by_document_state ON document_versions (document_id, state);
CREATE INDEX document_versions_by_state ON document_versions (state);

CREATE TABLE version_authors (
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES authors(id) ON DELETE RESTRICT,
    position INTEGER NOT NULL CHECK (position >= 0),
    PRIMARY KEY (version_id, author_id),
    UNIQUE (version_id, position)
) STRICT;

CREATE TABLE version_subjects (
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    subject_id INTEGER NOT NULL REFERENCES subjects(id) ON DELETE RESTRICT,
    PRIMARY KEY (version_id, subject_id)
) STRICT;

CREATE TABLE sections (
    id INTEGER PRIMARY KEY,
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (kind IN ('text', 'image', 'interactive', 'quote', 'embed')),
    data TEXT NOT NULL CHECK (json_valid(data)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    UNIQUE (version_id, position)
) STRICT;

CREATE INDEX sections_by_version_position ON sections (version_id, position);

-- Bibliographic records are owned by a document version. Their short names
-- are the version-local identifiers that future Markdown citation syntax will
-- resolve; the structured metadata format and citation rendering are defined
-- separately from this canonical storage model.
CREATE TABLE version_references (
    id INTEGER PRIMARY KEY,
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    short_name TEXT NOT NULL COLLATE NOCASE CHECK (
        length(short_name) BETWEEN 1 AND 128
        AND short_name = trim(short_name)
    ),
    data TEXT NOT NULL CHECK (json_valid(data) AND json_type(data) = 'object'),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    UNIQUE (version_id, short_name)
) STRICT;

CREATE TABLE working_revisions (
    id INTEGER PRIMARY KEY,
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
    snapshot TEXT NOT NULL CHECK (json_valid(snapshot)),
    reason TEXT NOT NULL CHECK (reason IN ('save', 'submit_for_review', 'publish', 'autosave', 'restore', 'import')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    UNIQUE (version_id, revision_number)
) STRICT;

CREATE INDEX working_revisions_by_version ON working_revisions (version_id, revision_number DESC);

CREATE TABLE assets (
    id INTEGER PRIMARY KEY,
    object_key TEXT NOT NULL UNIQUE CHECK (
        length(trim(object_key)) > 0
        AND object_key NOT GLOB '/*'
        AND object_key NOT LIKE '%..%'
    ),
    content_type TEXT NOT NULL CHECK (length(trim(content_type)) > 0),
    byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
    checksum_sha256 TEXT NOT NULL UNIQUE CHECK (
        length(checksum_sha256) = 64
        AND checksum_sha256 NOT GLOB '*[^0123456789abcdef]*'
    ),
    extension TEXT NOT NULL CHECK (extension NOT GLOB '*[^A-Za-z0-9]*' AND length(extension) > 0),
    original_filename TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    uploaded_by INTEGER REFERENCES users(id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE version_assets (
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
    name TEXT NOT NULL COLLATE NOCASE CHECK (
        length(name) BETWEEN 1 AND 128
        AND name NOT GLOB '*[^a-zA-Z0-9._-]*'
    ),
    PRIMARY KEY (version_id, asset_id),
    UNIQUE (version_id, name)
) STRICT;

CREATE INDEX version_assets_by_asset ON version_assets (asset_id);

-- Interactive modules are reserved data only. No serving or execution path is
-- enabled by this migration.
CREATE TABLE interactive_modules (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(name)) > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE interactive_module_versions (
    id INTEGER PRIMARY KEY,
    module_id INTEGER NOT NULL REFERENCES interactive_modules(id) ON DELETE RESTRICT,
    version_number INTEGER NOT NULL CHECK (version_number > 0),
    state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'published')),
    configuration_schema TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(configuration_schema)),
    published_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    UNIQUE (module_id, version_number),
    CHECK (
        (state = 'draft' AND published_at IS NULL)
        OR (state = 'published' AND published_at IS NOT NULL)
    )
) STRICT;

CREATE TABLE interactive_module_assets (
    module_version_id INTEGER NOT NULL REFERENCES interactive_module_versions(id) ON DELETE CASCADE,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
    path TEXT NOT NULL CHECK (length(trim(path)) > 0 AND path NOT GLOB '/*' AND path NOT LIKE '%..%'),
    role TEXT NOT NULL CHECK (role IN ('javascript', 'stylesheet', 'wasm', 'static')),
    PRIMARY KEY (module_version_id, asset_id),
    UNIQUE (module_version_id, path)
) STRICT;

-- A manager-created assignment is the explicit basis for an editor acting for
-- an author or on one document. It carries no authorship implication.
CREATE TABLE editor_assignments (
    id INTEGER PRIMARY KEY,
    editor_user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    author_id INTEGER REFERENCES authors(id) ON DELETE RESTRICT,
    document_id INTEGER REFERENCES documents(id) ON DELETE RESTRICT,
    granted_by INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    granted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    revoked_at TEXT,
    revoked_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL DEFAULT 0 CHECK (revision_number >= 0),
    CHECK (
        (author_id IS NOT NULL AND document_id IS NULL)
        OR (author_id IS NULL AND document_id IS NOT NULL)
    ),
    CHECK (
        (revoked_at IS NULL AND revoked_by IS NULL)
        OR (revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
    )
) STRICT;

CREATE UNIQUE INDEX editor_assignments_active_author
    ON editor_assignments (editor_user_id, author_id)
    WHERE revoked_at IS NULL AND author_id IS NOT NULL;
CREATE UNIQUE INDEX editor_assignments_active_document
    ON editor_assignments (editor_user_id, document_id)
    WHERE revoked_at IS NULL AND document_id IS NOT NULL;
CREATE INDEX editor_assignments_by_editor ON editor_assignments (editor_user_id, revoked_at);

CREATE TABLE web_sessions (
    id INTEGER PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    csrf_secret_hash TEXT NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    revoked_at TEXT
) STRICT;

CREATE INDEX web_sessions_active_by_user ON web_sessions (user_id, expires_at) WHERE revoked_at IS NULL;

-- Recovery secrets are opaque values generated by the application. Only their
-- SHA-256 hashes are stored, and a user may have at most one live token.
CREATE TABLE local_password_reset_tokens (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE CHECK (
        length(token_hash) = 64
        AND token_hash NOT GLOB '*[^0123456789abcdef]*'
    ),
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    consumed_at TEXT,
    CHECK (consumed_at IS NULL OR consumed_at >= created_at)
) STRICT;

CREATE UNIQUE INDEX local_password_reset_tokens_one_live_per_user
    ON local_password_reset_tokens (user_id) WHERE consumed_at IS NULL;
CREATE INDEX local_password_reset_tokens_active_by_expiry
    ON local_password_reset_tokens (expires_at) WHERE consumed_at IS NULL;

-- Login throttling keys are domain-separated application hashes of a
-- normalized login identifier or client address. No password or raw address
-- is retained in the database.
CREATE TABLE local_login_rate_limits (
    scope TEXT NOT NULL CHECK (scope IN ('identifier', 'address')),
    key_hash TEXT NOT NULL CHECK (
        length(key_hash) = 64
        AND key_hash NOT GLOB '*[^0123456789abcdef]*'
    ),
    failure_count INTEGER NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
    window_started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    locked_until TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (scope, key_hash)
) STRICT;

CREATE INDEX local_login_rate_limits_locked_until
    ON local_login_rate_limits (locked_until) WHERE locked_until IS NOT NULL;

CREATE TABLE oauth_clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    client_type TEXT NOT NULL CHECK (client_type IN ('public', 'confidential')),
    secret_hash TEXT,
    created_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    disabled_at TEXT,
    CHECK (
        (client_type = 'public' AND secret_hash IS NULL)
        OR (client_type = 'confidential' AND secret_hash IS NOT NULL)
    )
) STRICT;

CREATE TABLE oauth_client_redirect_uris (
    client_id TEXT NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    PRIMARY KEY (client_id, redirect_uri)
) STRICT;

CREATE TABLE oauth_authorization_grants (
    id INTEGER PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES oauth_clients(id) ON DELETE RESTRICT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    scopes TEXT NOT NULL CHECK (json_valid(scopes) AND json_type(scopes) = 'array'),
    granted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    revoked_at TEXT,
    UNIQUE (client_id, user_id)
) STRICT;

CREATE TABLE oauth_authorization_codes (
    id INTEGER PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    authorization_grant_id INTEGER NOT NULL REFERENCES oauth_authorization_grants(id) ON DELETE RESTRICT,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    code_challenge_method TEXT NOT NULL CHECK (code_challenge_method = 'S256'),
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    consumed_at TEXT
) STRICT;

CREATE INDEX oauth_authorization_codes_active
    ON oauth_authorization_codes (expires_at) WHERE consumed_at IS NULL;

CREATE TABLE oauth_tokens (
    id INTEGER PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    token_type TEXT NOT NULL CHECK (token_type IN ('access', 'refresh')),
    authorization_grant_id INTEGER NOT NULL REFERENCES oauth_authorization_grants(id) ON DELETE RESTRICT,
    parent_refresh_token_id INTEGER REFERENCES oauth_tokens(id) ON DELETE RESTRICT,
    scopes TEXT NOT NULL CHECK (json_valid(scopes) AND json_type(scopes) = 'array'),
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    used_at TEXT,
    revoked_at TEXT,
    CHECK (token_type = 'refresh' OR parent_refresh_token_id IS NOT NULL)
) STRICT;

CREATE INDEX oauth_tokens_active_by_grant
    ON oauth_tokens (authorization_grant_id, expires_at) WHERE revoked_at IS NULL;

CREATE TABLE idempotency_results (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    oauth_client_id TEXT REFERENCES oauth_clients(id) ON DELETE RESTRICT,
    operation TEXT NOT NULL CHECK (length(trim(operation)) > 0),
    idempotency_key TEXT NOT NULL CHECK (length(trim(idempotency_key)) > 0),
    request_fingerprint TEXT NOT NULL,
    status_code INTEGER NOT NULL CHECK (status_code BETWEEN 100 AND 599),
    response TEXT NOT NULL CHECK (json_valid(response)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at TEXT NOT NULL
) STRICT;

CREATE UNIQUE INDEX idempotency_results_web_key
    ON idempotency_results (user_id, operation, idempotency_key)
    WHERE oauth_client_id IS NULL;
CREATE UNIQUE INDEX idempotency_results_oauth_key
    ON idempotency_results (user_id, oauth_client_id, operation, idempotency_key)
    WHERE oauth_client_id IS NOT NULL;
CREATE INDEX idempotency_results_expiry ON idempotency_results (expires_at);

CREATE TABLE cache_invalidation_jobs (
    id INTEGER PRIMARY KEY,
    deduplication_key TEXT NOT NULL UNIQUE,
    document_id INTEGER REFERENCES documents(id) ON DELETE RESTRICT,
    version_id INTEGER REFERENCES document_versions(id) ON DELETE RESTRICT,
    reason TEXT NOT NULL CHECK (reason IN ('publish', 'archive_visibility', 'finalize')),
    targets TEXT NOT NULL CHECK (json_valid(targets) AND json_type(targets) = 'array'),
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'processing', 'completed', 'failed')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    available_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    claimed_at TEXT,
    claim_token TEXT,
    completed_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (
        (state = 'processing' AND claimed_at IS NOT NULL AND claim_token IS NOT NULL)
        OR (state != 'processing' AND claimed_at IS NULL AND claim_token IS NULL)
    ),
    CHECK ((state = 'completed') = (completed_at IS NOT NULL))
) STRICT;

CREATE INDEX cache_invalidation_jobs_claimable
    ON cache_invalidation_jobs (state, available_at, id) WHERE state IN ('pending', 'failed');

CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY,
    action TEXT NOT NULL CHECK (length(trim(action)) > 0),
    interface TEXT NOT NULL CHECK (interface IN ('web', 'mcp', 'cli', 'system')),
    actor_user_id INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    acted_for_author_id INTEGER REFERENCES authors(id) ON DELETE RESTRICT,
    oauth_client_id TEXT REFERENCES oauth_clients(id) ON DELETE RESTRICT,
    document_id INTEGER REFERENCES documents(id) ON DELETE RESTRICT,
    version_id INTEGER REFERENCES document_versions(id) ON DELETE RESTRICT,
    request_id TEXT,
    details TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details)),
    occurred_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (interface = 'system' OR actor_user_id IS NOT NULL)
) STRICT;

CREATE INDEX audit_log_by_document ON audit_log (document_id, occurred_at DESC);
CREATE INDEX audit_log_by_actor ON audit_log (actor_user_id, occurred_at DESC);

CREATE TABLE version_import_provenance (
    id INTEGER PRIMARY KEY,
    version_id INTEGER NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('import', 'bootstrap', 'migration')),
    source_uri TEXT,
    source_document_identifier TEXT,
    source_version_identifier TEXT,
    artifact_checksum_sha256 TEXT CHECK (
        artifact_checksum_sha256 IS NULL OR (
            length(artifact_checksum_sha256) = 64
            AND artifact_checksum_sha256 NOT GLOB '*[^0123456789abcdef]*'
        )
    ),
    details TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details)),
    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    recorded_by INTEGER REFERENCES users(id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX version_import_provenance_by_version
    ON version_import_provenance (version_id, recorded_at);

CREATE TRIGGER documents_type_is_immutable
BEFORE UPDATE OF type ON documents
FOR EACH ROW WHEN NEW.type IS NOT OLD.type
BEGIN
    SELECT RAISE(ABORT, 'document type is immutable');
END;

CREATE TRIGGER documents_cannot_change_after_finalization
BEFORE UPDATE ON documents
FOR EACH ROW WHEN OLD.finalized_at IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'finalized document is immutable');
END;

CREATE TRIGGER documents_finalization_requires_current_publication
BEFORE UPDATE OF finalized_at, finalized_by ON documents
FOR EACH ROW WHEN OLD.finalized_at IS NULL AND NEW.finalized_at IS NOT NULL
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM document_versions
        WHERE id = NEW.current_published_version_id
          AND document_id = NEW.id
          AND state = 'published'
    ) THEN RAISE(ABORT, 'finalization requires current published version') END;
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM document_versions
        WHERE document_id = NEW.id AND state IN ('draft', 'review')
    ) THEN RAISE(ABORT, 'finalization requires no mutable version') END;
END;

CREATE TRIGGER documents_current_version_must_match
BEFORE UPDATE OF current_published_version_id ON documents
FOR EACH ROW WHEN NEW.current_published_version_id IS NOT NULL
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM document_versions AS version
        WHERE version.id = NEW.current_published_version_id
          AND version.document_id = NEW.id
          AND version.state = 'published'
    ) THEN RAISE(ABORT, 'current version must be this document published version') END;
END;

CREATE TRIGGER documents_current_version_cannot_be_cleared
BEFORE UPDATE OF current_published_version_id ON documents
FOR EACH ROW WHEN OLD.current_published_version_id IS NOT NULL AND NEW.current_published_version_id IS NULL
BEGIN
    SELECT RAISE(ABORT, 'published document must retain a current version');
END;

CREATE TRIGGER document_versions_parent_must_be_previous_current_publication
BEFORE INSERT ON document_versions
FOR EACH ROW
BEGIN
    SELECT CASE WHEN NOT (
        (NEW.version_number = 1 AND NEW.based_on_version_id IS NULL)
        OR
        (NEW.version_number > 1 AND EXISTS (
            SELECT 1 FROM document_versions AS parent
            JOIN documents AS document ON document.id = NEW.document_id
            WHERE parent.id = NEW.based_on_version_id
              AND parent.document_id = NEW.document_id
              AND parent.version_number = NEW.version_number - 1
              AND parent.id = document.current_published_version_id
              AND parent.state = 'published'
        ))
    ) THEN RAISE(ABORT, 'version must begin at one or follow current published version') END;
END;

CREATE TRIGGER document_versions_cannot_change_after_document_finalization
BEFORE INSERT ON document_versions
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM documents WHERE id = NEW.document_id AND finalized_at IS NOT NULL
)
BEGIN
    SELECT RAISE(ABORT, 'cannot add a version to a finalized document');
END;

CREATE TRIGGER document_versions_identity_is_immutable
BEFORE UPDATE OF document_id, version_number, based_on_version_id ON document_versions
FOR EACH ROW WHEN NEW.document_id IS NOT OLD.document_id
    OR NEW.version_number IS NOT OLD.version_number
    OR NEW.based_on_version_id IS NOT OLD.based_on_version_id
BEGIN
    SELECT RAISE(ABORT, 'document version identity and parent are immutable');
END;

CREATE TRIGGER document_versions_cannot_update_after_document_finalization
BEFORE UPDATE ON document_versions
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM documents WHERE id = OLD.document_id AND finalized_at IS NOT NULL
)
BEGIN
    SELECT RAISE(ABORT, 'finalized document versions are immutable');
END;

CREATE TRIGGER document_versions_published_content_is_immutable
BEFORE UPDATE ON document_versions
FOR EACH ROW WHEN OLD.state = 'published' AND NOT (
    NEW.state = 'archived'
    AND NEW.document_id IS OLD.document_id
    AND NEW.version_number IS OLD.version_number
    AND NEW.based_on_version_id IS OLD.based_on_version_id
    AND NEW.slug IS OLD.slug
    AND NEW.title IS OLD.title
    AND NEW.description IS OLD.description
    AND NEW.language IS OLD.language
    AND NEW.series_id IS OLD.series_id
    AND NEW.series_position IS OLD.series_position
    AND NEW.revision_number IS OLD.revision_number
    AND NEW.created_at IS OLD.created_at
    AND NEW.created_by IS OLD.created_by
    AND NEW.updated_at IS OLD.updated_at
    AND NEW.updated_by IS OLD.updated_by
    AND NEW.published_at IS OLD.published_at
    AND NEW.archive_accessible IN (0, 1)
)
BEGIN
    SELECT RAISE(ABORT, 'published version content is immutable');
END;

CREATE TRIGGER document_versions_archived_content_is_immutable
BEFORE UPDATE ON document_versions
FOR EACH ROW WHEN OLD.state = 'archived' AND NOT (
    NEW.state = 'archived'
    AND NEW.document_id IS OLD.document_id
    AND NEW.version_number IS OLD.version_number
    AND NEW.based_on_version_id IS OLD.based_on_version_id
    AND NEW.slug IS OLD.slug
    AND NEW.title IS OLD.title
    AND NEW.description IS OLD.description
    AND NEW.language IS OLD.language
    AND NEW.series_id IS OLD.series_id
    AND NEW.series_position IS OLD.series_position
    AND NEW.revision_number IS OLD.revision_number
    AND NEW.created_at IS OLD.created_at
    AND NEW.created_by IS OLD.created_by
    AND NEW.updated_at IS OLD.updated_at
    AND NEW.updated_by IS OLD.updated_by
    AND NEW.published_at IS OLD.published_at
)
BEGIN
    SELECT RAISE(ABORT, 'archived version content is immutable');
END;

CREATE TRIGGER document_versions_cannot_delete_immutable_version
BEFORE DELETE ON document_versions
FOR EACH ROW WHEN OLD.state IN ('published', 'archived')
BEGIN
    SELECT RAISE(ABORT, 'published and archived versions cannot be deleted');
END;

CREATE TRIGGER sections_cannot_modify_immutable_version
BEFORE INSERT ON sections
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id = NEW.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'cannot add sections to immutable version');
END;

CREATE TRIGGER sections_cannot_update_immutable_version
BEFORE UPDATE ON sections
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version sections cannot be changed');
END;

CREATE TRIGGER sections_cannot_delete_immutable_version
BEFORE DELETE ON sections
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version sections cannot be deleted');
END;

CREATE TRIGGER version_references_cannot_modify_immutable_version
BEFORE INSERT ON version_references
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id = NEW.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'cannot add references to immutable version');
END;

CREATE TRIGGER version_references_cannot_update_immutable_version
BEFORE UPDATE ON version_references
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id IN (OLD.version_id, NEW.version_id)
      AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version references cannot be changed');
END;

CREATE TRIGGER version_references_cannot_delete_immutable_version
BEFORE DELETE ON version_references
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions
    WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version references cannot be deleted');
END;

CREATE TRIGGER version_authors_cannot_modify_immutable_version
BEFORE INSERT ON version_authors
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = NEW.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version authors cannot be changed');
END;

CREATE TRIGGER version_authors_cannot_update_immutable_version
BEFORE UPDATE ON version_authors
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version authors cannot be changed');
END;

CREATE TRIGGER version_authors_cannot_delete_immutable_version
BEFORE DELETE ON version_authors
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version authors cannot be changed');
END;

CREATE TRIGGER version_subjects_cannot_modify_immutable_version
BEFORE INSERT ON version_subjects
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = NEW.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version subjects cannot be changed');
END;

CREATE TRIGGER version_subjects_cannot_update_immutable_version
BEFORE UPDATE ON version_subjects
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version subjects cannot be changed');
END;

CREATE TRIGGER version_subjects_cannot_delete_immutable_version
BEFORE DELETE ON version_subjects
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version subjects cannot be changed');
END;

CREATE TRIGGER version_assets_cannot_modify_immutable_version
BEFORE INSERT ON version_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = NEW.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version assets cannot be changed');
END;

CREATE TRIGGER version_assets_cannot_update_immutable_version
BEFORE UPDATE ON version_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version assets cannot be changed');
END;

CREATE TRIGGER version_assets_cannot_delete_immutable_version
BEFORE DELETE ON version_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM document_versions WHERE id = OLD.version_id AND state IN ('published', 'archived')
)
BEGIN
    SELECT RAISE(ABORT, 'immutable version assets cannot be changed');
END;

CREATE TRIGGER working_revisions_require_mutable_version
BEFORE INSERT ON working_revisions
FOR EACH ROW WHEN NOT EXISTS (
    SELECT 1 FROM document_versions WHERE id = NEW.version_id AND state IN ('draft', 'review')
)
BEGIN
    SELECT RAISE(ABORT, 'working revisions require a mutable version');
END;

CREATE TRIGGER working_revisions_are_append_only
BEFORE UPDATE ON working_revisions
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'working revisions are immutable');
END;

CREATE TRIGGER interactive_module_versions_published_content_is_immutable
BEFORE UPDATE ON interactive_module_versions
FOR EACH ROW WHEN OLD.state = 'published' AND NOT (
    NEW.module_id IS OLD.module_id
    AND NEW.version_number IS OLD.version_number
    AND NEW.state = 'published'
    AND NEW.configuration_schema IS OLD.configuration_schema
    AND NEW.published_at IS OLD.published_at
    AND NEW.created_at IS OLD.created_at
    AND NEW.created_by IS OLD.created_by
)
BEGIN
    SELECT RAISE(ABORT, 'published interactive module version is immutable');
END;

CREATE TRIGGER interactive_module_versions_cannot_delete_published
BEFORE DELETE ON interactive_module_versions
FOR EACH ROW WHEN OLD.state = 'published'
BEGIN
    SELECT RAISE(ABORT, 'published interactive module version cannot be deleted');
END;

CREATE TRIGGER interactive_module_assets_cannot_modify_published_version
BEFORE INSERT ON interactive_module_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM interactive_module_versions WHERE id = NEW.module_version_id AND state = 'published'
)
BEGIN
    SELECT RAISE(ABORT, 'published interactive module assets are immutable');
END;

CREATE TRIGGER interactive_module_assets_cannot_update_published_version
BEFORE UPDATE ON interactive_module_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM interactive_module_versions WHERE id = OLD.module_version_id AND state = 'published'
)
BEGIN
    SELECT RAISE(ABORT, 'published interactive module assets are immutable');
END;

CREATE TRIGGER interactive_module_assets_cannot_delete_published_version
BEFORE DELETE ON interactive_module_assets
FOR EACH ROW WHEN EXISTS (
    SELECT 1 FROM interactive_module_versions WHERE id = OLD.module_version_id AND state = 'published'
)
BEGIN
    SELECT RAISE(ABORT, 'published interactive module assets are immutable');
END;

CREATE TRIGGER audit_log_is_append_only
BEFORE UPDATE ON audit_log
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'audit log is append-only');
END;

CREATE TRIGGER audit_log_cannot_be_deleted
BEFORE DELETE ON audit_log
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'audit log is append-only');
END;
