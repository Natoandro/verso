const std = @import("std");

pub fn Scope(comptime Outer: type, comptime name: []const u8, comptime Value: type) type {
    return struct {
        pub const template_scope = true;
        pub const capture_name = name;
        pub const capture_type = Value;
        pub const outer_type = Outer;

        // Scope chains are borrowed, not owned. Keeping the outer context as
        // a pointer avoids copying the complete lexical chain into every
        // nested scope. The renderer is synchronous, so the pointed-to scope
        // remains alive until the recursive render call returns.
        outer: *const Outer,
        value: Value,
    };
}

pub fn resolvePathType(comptime Context: type, comptime path: anytype, comptime index: usize) type {
    if (index == path.count) return Context;

    if (comptime isScope(Context) and index == 0) {
        const ScopeType = unwrapScopePointer(Context);
        const segment = path.segments[index];
        const name = path.source[segment.start .. segment.start + segment.len];
        if (comptime std.mem.eql(u8, name, ScopeType.capture_name)) {
            return resolvePathType(ScopeType.capture_type, path, index + 1);
        }
        return resolvePathType(ScopeType.outer_type, path, index);
    }

    const Struct = structType(Context, path.source);
    const segment = path.segments[index];
    const name = path.source[segment.start .. segment.start + segment.len];
    return resolvePathType(fieldType(Struct, name, path.source), path, index + 1);
}

pub fn resolvePath(comptime path: anytype, context: anytype) resolvePathType(@TypeOf(context), path, 0) {
    return resolvePathAt(path, 0, context);
}

fn resolvePathAt(comptime path: anytype, comptime index: usize, value: anytype) resolvePathType(@TypeOf(value), path, index) {
    if (index == path.count) return value;

    if (comptime isScope(@TypeOf(value)) and index == 0) {
        const ScopeType = unwrapScopePointer(@TypeOf(value));
        const segment = path.segments[index];
        const name = path.source[segment.start .. segment.start + segment.len];
        if (comptime std.mem.eql(u8, name, ScopeType.capture_name)) {
            return resolvePathAt(path, index + 1, value.value);
        }
        return resolvePathAt(path, index, value.outer);
    }

    const dereferenced = dereference(value);
    const segment = path.segments[index];
    const name = path.source[segment.start .. segment.start + segment.len];
    return resolvePathAt(path, index + 1, @field(dereferenced, name));
}

fn isScope(comptime Value: type) bool {
    const Candidate = unwrapScopePointer(Value);
    return switch (@typeInfo(Candidate)) {
        .@"struct" => @hasDecl(Candidate, "template_scope"),
        else => false,
    };
}

fn unwrapScopePointer(comptime Value: type) type {
    return switch (@typeInfo(Value)) {
        .pointer => |pointer| if (pointer.size == .one) pointer.child else Value,
        else => Value,
    };
}

fn structType(comptime Value: type, comptime expression: []const u8) type {
    const Unwrapped = unwrapStructPointer(Value);
    return switch (@typeInfo(Unwrapped)) {
        .@"struct" => Unwrapped,
        else => @compileError(std.fmt.comptimePrint(
            "template expression '{s}' traverses a non-struct value of type {s}",
            .{ expression, @typeName(Value) },
        )),
    };
}

fn fieldType(comptime Struct: type, comptime name: []const u8, comptime expression: []const u8) type {
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    @compileError(std.fmt.comptimePrint(
        "unknown field '{s}' in template expression '{s}' on {s}",
        .{ name, expression, @typeName(Struct) },
    ));
}

fn unwrapStructPointer(comptime Value: type) type {
    return switch (@typeInfo(Value)) {
        .pointer => |pointer| if (pointer.size == .one and @typeInfo(pointer.child) == .@"struct")
            pointer.child
        else
            Value,
        else => Value,
    };
}

fn dereference(value: anytype) unwrapStructPointer(@TypeOf(value)) {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| if (pointer.size == .one and @typeInfo(pointer.child) == .@"struct")
            value.*
        else
            value,
        else => value,
    };
}
