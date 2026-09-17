const std = @import("std");

pub fn resolvePathType(comptime Context: type, comptime path: anytype, comptime index: usize) type {
    if (index == path.count) return Context;

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

    const dereferenced = dereference(value);
    const segment = path.segments[index];
    const name = path.source[segment.start .. segment.start + segment.len];
    return resolvePathAt(path, index + 1, @field(dereferenced, name));
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
