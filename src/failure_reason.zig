const std = @import("std");

/// Returns a safe, operator-facing explanation for a failure.
///
/// Error names remain in log records for machine-oriented filtering. This
/// companion value is deliberately static and never contains submitted
/// credentials, database URLs, or other request/configuration values.
pub fn forError(failure: anyerror) []const u8 {
    const name = @errorName(failure);

    if (std.mem.eql(u8, name, "InvalidSiteName")) return "site.name must be non-empty and contain no control characters";
    if (std.mem.eql(u8, name, "InvalidBaseUrl")) return "site.base_url must be an HTTP(S) URL with a host";
    if (std.mem.eql(u8, name, "MissingBaseUrl")) return "site.base_url is required for production or a non-loopback server host";
    if (std.mem.eql(u8, name, "InvalidServerHost")) return "server.host must be a valid host and server.port must be non-zero";
    if (std.mem.eql(u8, name, "InvalidDatabaseUrl")) return "database.url must be a valid SQLite path or SQLite URL";
    if (std.mem.eql(u8, name, "InvalidMigrationConfiguration")) return "migrations.path is empty or contains path traversal";
    if (std.mem.eql(u8, name, "InvalidStoragePath")) return "storage filesystem path is empty or contains path traversal";
    if (std.mem.eql(u8, name, "InvalidCachePath")) return "cache.path is empty or contains path traversal";
    if (std.mem.eql(u8, name, "InvalidPublicStaticPath")) return "public_static_root is empty or contains path traversal";
    if (std.mem.eql(u8, name, "InvalidTheme")) return "ui.theme must be a non-empty token";
    if (std.mem.eql(u8, name, "InvalidLogoPath")) return "the configured logo path is invalid";
    if (std.mem.eql(u8, name, "UnsupportedLogoVariant")) return "the configured logo variant is not implemented";
    if (std.mem.eql(u8, name, "InvalidFeatureConfiguration")) return "the requested feature is not currently supported";
    if (std.mem.eql(u8, name, "InvalidEditorConfiguration")) return "the editor configuration is incomplete or invalid";
    if (std.mem.eql(u8, name, "InvalidMcpConfiguration")) return "MCP publishing requires MCP to be enabled";
    if (std.mem.eql(u8, name, "InvalidSecurityConfiguration")) return "security proxy addresses must be comma-separated non-empty tokens";
    if (std.mem.eql(u8, name, "InvalidAuthConfiguration")) return "auth bootstrap configuration is incomplete or invalid";
    if (std.mem.eql(u8, name, "InvalidEnvironmentValue")) return "the environment value does not match the expected type or allowlist";
    if (std.mem.eql(u8, name, "InvalidArguments")) return "the command arguments are incomplete or invalid";
    if (std.mem.eql(u8, name, "InvalidCommand")) return "the command is not supported";
    if (std.mem.eql(u8, name, "InvalidBoolean")) return "the boolean value must be exactly true or false";
    if (std.mem.eql(u8, name, "InvalidCharacter")) return "a numeric argument contains a non-numeric character";
    if (std.mem.eql(u8, name, "Overflow")) return "a numeric argument is outside the supported range";
    if (std.mem.eql(u8, name, "MissingBootstrapPassword")) return "a bootstrap password or password hash is required";

    if (std.mem.eql(u8, name, "InvalidForm")) return "the request body is not a valid form encoding";
    if (std.mem.eql(u8, name, "MissingFormField")) return "a required form field is missing";
    if (std.mem.eql(u8, name, "DuplicateFormField")) return "a form field was submitted more than once";
    if (std.mem.eql(u8, name, "BodyTooLarge")) return "the request body exceeds the configured limit";
    if (std.mem.eql(u8, name, "InvalidCsrfToken")) return "the CSRF token is missing or does not match the session";
    if (std.mem.eql(u8, name, "InvalidCredentials")) return "the supplied credentials were not accepted";
    if (std.mem.eql(u8, name, "InvalidRegistration")) return "the registration data failed validation";
    if (std.mem.eql(u8, name, "InvalidPassword")) return "the password failed password validation";
    if (std.mem.eql(u8, name, "InvalidPasswordHash")) return "the password hash is not in the supported format";
    if (std.mem.eql(u8, name, "InvalidLogin")) return "the login failed validation";
    if (std.mem.eql(u8, name, "MissingOrigin")) return "the request did not include a required origin";
    if (std.mem.eql(u8, name, "InvalidOrigin")) return "the request origin is malformed";
    if (std.mem.eql(u8, name, "OriginNotAllowed")) return "the request origin is not allowed";
    if (std.mem.eql(u8, name, "UntrustedForwardedOrigin")) return "forwarded origin headers came from an untrusted peer";
    if (std.mem.eql(u8, name, "InvalidForwardedOrigin")) return "forwarded origin headers are malformed";
    if (std.mem.eql(u8, name, "IncompleteForwardedOrigin")) return "forwarded scheme and host headers must be supplied together";
    if (std.mem.eql(u8, name, "InvalidPublicOrigin")) return "the request origin does not match the configured public origin";
    if (std.mem.eql(u8, name, "InvalidForwardedHost")) return "the forwarded host header is invalid";
    if (std.mem.eql(u8, name, "InvalidForwardedScheme")) return "the forwarded scheme must be http or https";

    if (std.mem.eql(u8, name, "InvalidDocumentId")) return "document_id must be positive";
    if (std.mem.eql(u8, name, "InvalidVersionId")) return "version_id must be positive";
    if (std.mem.eql(u8, name, "InvalidSectionId")) return "section_id must be positive";
    if (std.mem.eql(u8, name, "InvalidTitle")) return "the document title must be non-empty";
    if (std.mem.eql(u8, name, "InvalidSlug")) return "the document slug contains unsupported characters";
    if (std.mem.eql(u8, name, "InvalidLanguage")) return "the document language is invalid";
    if (std.mem.eql(u8, name, "InvalidDescription")) return "the document description contains an invalid character";
    if (std.mem.eql(u8, name, "InvalidMarkdown")) return "the markdown contains an invalid character";
    if (std.mem.eql(u8, name, "InvalidAssetName")) return "the asset name contains unsupported characters";
    if (std.mem.eql(u8, name, "InvalidAltText")) return "image alt text must be non-empty";
    if (std.mem.eql(u8, name, "InvalidCaption")) return "the image caption contains an invalid character";
    if (std.mem.eql(u8, name, "DuplicateSectionId")) return "a section ID was submitted more than once";
    if (std.mem.eql(u8, name, "InvalidPosition")) return "the section position is outside the document";
    if (std.mem.eql(u8, name, "InvalidRevision")) return "the revision value is invalid";
    if (std.mem.eql(u8, name, "StaleRevision")) return "the submitted revision is older than the stored revision";
    if (std.mem.eql(u8, name, "StaleAssignment")) return "the submitted assignment revision is older than the stored revision";
    if (std.mem.eql(u8, name, "SectionLimitExceeded")) return "the document contains too many sections";
    if (std.mem.eql(u8, name, "InvalidSectionKind")) return "the section kind is not supported";
    if (std.mem.eql(u8, name, "InvalidImageDisplay")) return "the image display mode is not supported";
    if (std.mem.eql(u8, name, "InvalidAuthorSlug")) return "the author slug contains unsupported characters";
    if (std.mem.eql(u8, name, "InvalidBiography")) return "the biography is too long or contains an invalid character";
    if (std.mem.eql(u8, name, "InvalidDisplayName")) return "the display name is invalid";
    if (std.mem.eql(u8, name, "InvalidEmail")) return "the email address is invalid";
    if (std.mem.eql(u8, name, "InvalidSubject")) return "the owner subject must be non-empty and contain no unsupported characters";
    if (std.mem.eql(u8, name, "InvalidAuthorUser")) return "the author user identifier must be a positive integer";
    if (std.mem.eql(u8, name, "InvalidVersion")) return "the version identifier must be a positive integer";
    if (std.mem.eql(u8, name, "DuplicateAuthor")) return "an author was assigned more than once";

    if (std.mem.eql(u8, name, "InvalidId")) return "the identifier must be a positive integer";
    if (std.mem.eql(u8, name, "InvalidPath")) return "the requested path is not a safe relative path";
    if (std.mem.eql(u8, name, "InvalidAssignmentScope")) return "the assignment scope is not supported";
    if (std.mem.eql(u8, name, "InvalidEditor")) return "the editor identifier is invalid";
    if (std.mem.eql(u8, name, "InvalidAuthor")) return "the author identifier is invalid";
    if (std.mem.eql(u8, name, "InvalidAssignment")) return "the assignment identifier is invalid";
    if (std.mem.eql(u8, name, "InvalidAssignmentRevision")) return "the assignment revision must not be negative";
    if (std.mem.eql(u8, name, "InvalidMigrationFilename")) return "the migration filename does not match the required format";
    if (std.mem.eql(u8, name, "InvalidMigrationVersion")) return "the migration version must be positive";
    if (std.mem.eql(u8, name, "DuplicateMigrationVersion")) return "multiple migrations use the same version number";
    if (std.mem.eql(u8, name, "MalformedTarget")) return "the request target is malformed";
    if (std.mem.eql(u8, name, "UnsafeTarget")) return "the request target contains unsafe path syntax";
    if (std.mem.eql(u8, name, "TargetTooLong")) return "the request target exceeds the configured limit";
    if (std.mem.eql(u8, name, "InvalidExtension")) return "the asset extension is invalid";

    return if (isValidationError(failure)) "input failed validation" else "the operation could not be completed";
}

/// Returns a safe remediation step for a failure. Suggestions are deliberately
/// value-free so they cannot echo credentials or other submitted secrets.
pub fn suggestion(failure: anyerror) []const u8 {
    const name = @errorName(failure);

    if (std.mem.eql(u8, name, "MissingBaseUrl")) return "Set VERSO_SITE_BASE_URL to the reachable HTTP(S) origin, or configure site.base_url in verso.toml.";
    if (std.mem.eql(u8, name, "InvalidBaseUrl")) return "Use an HTTP(S) URL with a reachable hostname or IP address; production URLs must not be loopback.";
    if (std.mem.eql(u8, name, "InvalidServerHost")) return "Set VERSO_SERVER_HOST to a valid IP address or hostname and VERSO_SERVER_PORT to a non-zero port.";
    if (std.mem.eql(u8, name, "InvalidEnvironmentValue")) return "Check the VERSO_* variable spelling and use the documented type or allowlisted value.";
    if (std.mem.eql(u8, name, "InvalidDatabaseUrl")) return "Set database.url to a valid SQLite path or sqlite:// URL.";
    if (std.mem.eql(u8, name, "InvalidMigrationConfiguration")) return "Set migrations.path to an existing safe directory path without '..' traversal.";
    if (std.mem.eql(u8, name, "InvalidStoragePath")) return "Set the filesystem storage path to a safe directory path without '..' traversal.";
    if (std.mem.eql(u8, name, "InvalidCachePath")) return "Set cache.path to a safe directory path without '..' traversal.";
    if (std.mem.eql(u8, name, "InvalidPublicStaticPath")) return "Set public_static_root to a safe directory path without '..' traversal.";
    if (std.mem.eql(u8, name, "InvalidAuthConfiguration")) return "Provide a complete supported bootstrap configuration, including both local login and password hash.";
    if (std.mem.eql(u8, name, "InvalidMcpConfiguration")) return "Enable MCP before enabling MCP publishing.";
    if (std.mem.eql(u8, name, "InvalidFeatureConfiguration")) return "Disable the unsupported feature until its implementation is available.";
    if (std.mem.eql(u8, name, "InvalidEditorConfiguration")) return "Provide a complete supported editor configuration or disable the editor feature.";
    if (std.mem.eql(u8, name, "UnsupportedLogoVariant")) return "Remove the unsupported logo variant or use ui.logo only.";

    if (std.mem.eql(u8, name, "InvalidForm") or
        std.mem.eql(u8, name, "MissingFormField") or
        std.mem.eql(u8, name, "DuplicateFormField"))
    {
        return "Submit a correctly encoded form with each required field exactly once.";
    }
    if (std.mem.eql(u8, name, "BodyTooLarge")) return "Reduce the request body and submit it again.";
    if (std.mem.eql(u8, name, "InvalidCsrfToken")) return "Reload the page to obtain a fresh CSRF token, then retry.";
    if (std.mem.eql(u8, name, "InvalidCredentials")) return "Verify the credentials and retry without reusing an expired session.";
    if (std.mem.eql(u8, name, "InvalidPassword")) return "Choose a password that satisfies the password policy and retry.";
    if (std.mem.eql(u8, name, "InvalidPasswordHash")) return "Supply a password hash in the supported Argon2id format.";
    if (std.mem.eql(u8, name, "InvalidOrigin") or
        std.mem.eql(u8, name, "OriginNotAllowed") or
        std.mem.eql(u8, name, "UntrustedForwardedOrigin") or
        std.mem.eql(u8, name, "InvalidPublicOrigin") or
        std.mem.eql(u8, name, "InvalidForwardedHost") or
        std.mem.eql(u8, name, "InvalidForwardedScheme") or
        std.mem.eql(u8, name, "IncompleteForwardedOrigin"))
    {
        return "Use the configured public origin and ensure forwarded headers come from a trusted proxy.";
    }
    if (std.mem.eql(u8, name, "StaleRevision")) return "Reload the current draft and apply the change to the latest revision.";
    if (std.mem.eql(u8, name, "StaleAssignment")) return "Reload the current assignment and apply the change to the latest revision.";
    if (std.mem.eql(u8, name, "InvalidSectionId") or
        std.mem.eql(u8, name, "InvalidVersionId") or
        std.mem.eql(u8, name, "InvalidDocumentId") or
        std.mem.eql(u8, name, "InvalidId"))
    {
        return "Use the positive identifier from the current page or route.";
    }
    if (std.mem.eql(u8, name, "InvalidSlug") or std.mem.eql(u8, name, "InvalidAuthorSlug")) {
        return "Use only letters, numbers, hyphens, or underscores in the slug.";
    }
    if (std.mem.eql(u8, name, "InvalidTitle")) return "Enter a non-empty title and submit the form again.";
    if (std.mem.eql(u8, name, "InvalidAltText")) return "Provide concise, non-empty alternative text for the image.";
    if (std.mem.eql(u8, name, "InvalidSubject")) return "Provide a non-empty owner subject without unsupported control characters.";
    if (std.mem.eql(u8, name, "InvalidAuthorUser") or std.mem.eql(u8, name, "InvalidVersion")) {
        return "Use the positive identifier from the current page or route.";
    }
    if (std.mem.eql(u8, name, "InvalidMarkdown")) return "Remove NUL or other unsupported control characters from the markdown.";
    if (std.mem.eql(u8, name, "InvalidAssignmentRevision") or std.mem.eql(u8, name, "InvalidRevision")) {
        return "Use the revision value supplied by the current page.";
    }
    if (std.mem.eql(u8, name, "SectionLimitExceeded")) return "Remove a section or increase the supported document limit.";
    if (std.mem.eql(u8, name, "InvalidPath")) return "Use a relative path without separators, traversal, or control characters.";
    if (std.mem.eql(u8, name, "InvalidExtension")) return "Use an alphanumeric asset extension of supported length.";
    if (std.mem.eql(u8, name, "DuplicateMigrationVersion")) return "Give each migration a unique positive version number.";
    if (std.mem.eql(u8, name, "InvalidCharacter")) return "Use decimal digits for numeric command-line arguments.";
    if (std.mem.eql(u8, name, "Overflow")) return "Use a value within the documented numeric range.";

    return if (isValidationError(failure))
        "Correct the reported field or input and retry."
    else
        "Inspect the error details and retry after correcting the underlying problem.";
}

pub fn isValidationError(failure: anyerror) bool {
    const name = @errorName(failure);
    return std.mem.eql(u8, name, "InvalidSiteName") or
        std.mem.eql(u8, name, "InvalidBaseUrl") or
        std.mem.eql(u8, name, "MissingBaseUrl") or
        std.mem.eql(u8, name, "InvalidServerHost") or
        std.mem.eql(u8, name, "InvalidDatabaseUrl") or
        std.mem.eql(u8, name, "InvalidMigrationConfiguration") or
        std.mem.eql(u8, name, "InvalidStoragePath") or
        std.mem.eql(u8, name, "InvalidCachePath") or
        std.mem.eql(u8, name, "InvalidPublicStaticPath") or
        std.mem.eql(u8, name, "InvalidTheme") or
        std.mem.eql(u8, name, "InvalidLogoPath") or
        std.mem.eql(u8, name, "UnsupportedLogoVariant") or
        std.mem.eql(u8, name, "InvalidFeatureConfiguration") or
        std.mem.eql(u8, name, "InvalidEditorConfiguration") or
        std.mem.eql(u8, name, "InvalidMcpConfiguration") or
        std.mem.eql(u8, name, "InvalidSecurityConfiguration") or
        std.mem.eql(u8, name, "InvalidAuthConfiguration") or
        std.mem.eql(u8, name, "InvalidEnvironmentValue") or
        std.mem.eql(u8, name, "InvalidArguments") or
        std.mem.eql(u8, name, "InvalidCommand") or
        std.mem.eql(u8, name, "InvalidBoolean") or
        std.mem.eql(u8, name, "InvalidCharacter") or
        std.mem.eql(u8, name, "Overflow") or
        std.mem.eql(u8, name, "MissingBootstrapPassword") or
        std.mem.eql(u8, name, "InvalidForm") or
        std.mem.eql(u8, name, "MissingFormField") or
        std.mem.eql(u8, name, "DuplicateFormField") or
        std.mem.eql(u8, name, "BodyTooLarge") or
        std.mem.eql(u8, name, "InvalidCsrfToken") or
        std.mem.eql(u8, name, "InvalidCredentials") or
        std.mem.eql(u8, name, "InvalidRegistration") or
        std.mem.eql(u8, name, "InvalidPassword") or
        std.mem.eql(u8, name, "InvalidPasswordHash") or
        std.mem.eql(u8, name, "InvalidLogin") or
        std.mem.eql(u8, name, "MissingOrigin") or
        std.mem.eql(u8, name, "InvalidOrigin") or
        std.mem.eql(u8, name, "OriginNotAllowed") or
        std.mem.eql(u8, name, "UntrustedForwardedOrigin") or
        std.mem.eql(u8, name, "InvalidForwardedOrigin") or
        std.mem.eql(u8, name, "IncompleteForwardedOrigin") or
        std.mem.eql(u8, name, "InvalidPublicOrigin") or
        std.mem.eql(u8, name, "InvalidForwardedHost") or
        std.mem.eql(u8, name, "InvalidForwardedScheme") or
        std.mem.eql(u8, name, "InvalidDocumentId") or
        std.mem.eql(u8, name, "InvalidVersionId") or
        std.mem.eql(u8, name, "InvalidSectionId") or
        std.mem.eql(u8, name, "InvalidTitle") or
        std.mem.eql(u8, name, "InvalidSlug") or
        std.mem.eql(u8, name, "InvalidLanguage") or
        std.mem.eql(u8, name, "InvalidDescription") or
        std.mem.eql(u8, name, "InvalidMarkdown") or
        std.mem.eql(u8, name, "InvalidAssetName") or
        std.mem.eql(u8, name, "InvalidAltText") or
        std.mem.eql(u8, name, "InvalidCaption") or
        std.mem.eql(u8, name, "DuplicateSectionId") or
        std.mem.eql(u8, name, "InvalidPosition") or
        std.mem.eql(u8, name, "InvalidRevision") or
        std.mem.eql(u8, name, "StaleRevision") or
        std.mem.eql(u8, name, "StaleAssignment") or
        std.mem.eql(u8, name, "SectionLimitExceeded") or
        std.mem.eql(u8, name, "InvalidSectionKind") or
        std.mem.eql(u8, name, "InvalidImageDisplay") or
        std.mem.eql(u8, name, "InvalidAuthorSlug") or
        std.mem.eql(u8, name, "InvalidBiography") or
        std.mem.eql(u8, name, "InvalidDisplayName") or
        std.mem.eql(u8, name, "InvalidEmail") or
        std.mem.eql(u8, name, "InvalidSubject") or
        std.mem.eql(u8, name, "InvalidAuthorUser") or
        std.mem.eql(u8, name, "InvalidVersion") or
        std.mem.eql(u8, name, "DuplicateAuthor") or
        std.mem.eql(u8, name, "InvalidId") or
        std.mem.eql(u8, name, "InvalidPath") or
        std.mem.eql(u8, name, "InvalidAssignmentScope") or
        std.mem.eql(u8, name, "InvalidEditor") or
        std.mem.eql(u8, name, "InvalidAuthor") or
        std.mem.eql(u8, name, "InvalidAssignment") or
        std.mem.eql(u8, name, "InvalidAssignmentRevision") or
        std.mem.eql(u8, name, "InvalidMigrationFilename") or
        std.mem.eql(u8, name, "InvalidMigrationVersion") or
        std.mem.eql(u8, name, "DuplicateMigrationVersion") or
        std.mem.eql(u8, name, "MalformedTarget") or
        std.mem.eql(u8, name, "UnsafeTarget") or
        std.mem.eql(u8, name, "TargetTooLong") or
        std.mem.eql(u8, name, "InvalidExtension");
}

test "validation reasons do not expose input values" {
    try std.testing.expectEqualStrings(
        "site.base_url is required for production or a non-loopback server host",
        forError(error.MissingBaseUrl),
    );
    try std.testing.expectEqualStrings(
        "the supplied credentials were not accepted",
        forError(error.InvalidCredentials),
    );
    try std.testing.expectEqualStrings(
        "Set VERSO_SITE_BASE_URL to the reachable HTTP(S) origin, or configure site.base_url in verso.toml.",
        suggestion(error.MissingBaseUrl),
    );
    try std.testing.expect(isValidationError(error.IncompleteForwardedOrigin));
    try std.testing.expect(isValidationError(error.StaleAssignment));
    try std.testing.expect(!isValidationError(error.InvalidSession));
    try std.testing.expect(!isValidationError(error.InvalidJournalMode));
}
