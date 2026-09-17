const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#if enabled |flag| trailing}}visible{{/if}}");
}
