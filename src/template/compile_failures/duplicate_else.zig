const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#if enabled}}one{{#else}}two{{#else}}three{{/if}}");
}
