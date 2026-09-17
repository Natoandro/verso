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

pub fn Node(comptime capacity: usize) type {
    return union(enum) {
        text: []const u8,
        expression: Path(capacity),
        raw_expression: Path(capacity),
        if_block: IfBlock(capacity),
        for_block: ForBlock(capacity),
    };
}

pub fn Parsed(comptime capacity: usize) type {
    return struct {
        nodes: [capacity]Node(capacity),
        count: usize,
    };
}
