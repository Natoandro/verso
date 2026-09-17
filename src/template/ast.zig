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

pub fn Node(comptime capacity: usize) type {
    return union(enum) {
        text: []const u8,
        expression: Path(capacity),
        raw_expression: Path(capacity),
    };
}

pub fn Parsed(comptime capacity: usize) type {
    return struct {
        nodes: [capacity]Node(capacity),
        count: usize,
    };
}
