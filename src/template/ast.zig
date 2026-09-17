pub const Segment = struct {
    start: usize,
    len: usize,
};

pub fn Path(comptime capacity: usize) type {
    return struct {
        source: []const u8,
        segments: [capacity]Segment,
        count: usize,
    };
}

pub fn IfBlock(comptime capacity: usize) type {
    return struct {
        condition: Path(capacity),
        capture: ?[]const u8,
        body_start: usize,
        body_end: usize,
        else_start: usize,
        else_end: usize,
        node_end: usize,
    };
}

pub fn ForBlock(comptime capacity: usize) type {
    return struct {
        iterable: Path(capacity),
        capture: []const u8,
        body_start: usize,
        body_end: usize,
        node_end: usize,
    };
}

pub const Expr = union(enum) {
    path: []const u8,
    string: []const u8,
    boolean: bool,
    integer: i64,
};

pub const ComponentArg = struct {
    name: []const u8,
    value: Expr,
};

pub fn Component(comptime capacity: usize) type {
    return struct {
        name: []const u8,
        args: [capacity]ComponentArg,
        count: usize,
        local_decl: ?usize,
    };
}

pub fn Snippet(comptime capacity: usize) type {
    return struct {
        name: []const u8,
        parameters: [capacity][]const u8,
        parameter_count: usize,
        body_start: usize,
        body_end: usize,
        node_end: usize,
    };
}

pub fn Node(comptime capacity: usize) type {
    return union(enum) {
        text: []const u8,
        expression: Path(capacity),
        raw_expression: Path(capacity),
        if_block: IfBlock(capacity),
        for_block: ForBlock(capacity),
        component: Component(capacity),
        snippet_declaration: Snippet(capacity),
    };
}

pub fn Parsed(comptime capacity: usize) type {
    return struct {
        nodes: [capacity]Node(capacity),
        count: usize,
    };
}
