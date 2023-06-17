const std = @import("std");

const events = @import("events.zig");
const c = @import("c_includes.zig").imported;

var allocator: std.mem.Allocator = undefined;
var id: usize = 0;
var list = Monome_List{ .head = null, .tail = null, .size = 0 };

pub fn init(alloc_pointer: std.mem.Allocator) void {
    allocator = alloc_pointer;
}

pub fn deinit() void {
    while (list.pop_and_deinit()) {}
}

const Monome_List = struct {
    const Node = struct {
        next: ?*Node,
        prev: ?*Node,
        dev: *Device,
    };
    head: ?*Node,
    tail: ?*Node,
    size: usize,
    fn pop_and_deinit(self: *Monome_List) bool {
        if (self.head) |n| {
            self.head = n.next;
            const dev = n.dev;
            dev.deinit();
            allocator.destroy(n);
            self.size -= 1;
            return true;
        } else {
            std.debug.assert(self.size == 0);
            return false;
        }
    }
    fn search(self: *Monome_List, path: []const u8) ?*Node {
        var node = self.head;
        while (node) |n| {
            if (std.mem.eql(u8, path, n.dev.path)) {
                return n;
            }
            node = n.next;
        }
        return null;
    }
    fn add(self: *Monome_List, dev: *Device) !events.Data {
        var new_node = try allocator.create(Node);
        new_node.* = Node{ .dev = dev, .next = null, .prev = null };
        if (self.tail) |n| {
            n.next = new_node;
            new_node.prev = n;
        } else {
            std.debug.assert(self.size == 0);
            self.head = new_node;
        }
        self.tail = new_node;
        self.size += 1;

        return .{ .Monome_Add = .{ .dev = dev } };
    }
    fn remove(self: *Monome_List, path: []const u8) void {
        var node = self.search(path);
        if (node) |n| {
            const dev = n.dev;
            const event = .{ .Monome_Remove = .{ .id = dev.id } };
            events.post(event);
            if (self.head == n) self.head = n.next;
            if (self.tail == n) self.tail = n.prev;
            const prev = n.prev;
            const next = n.next;
            if (prev) |p| p.next = next;
            if (next) |nxt| nxt.prev = prev;
            self.size -= 1;
            dev.deinit();
            allocator.destroy(n);
        }
    }
};

pub fn remove(path: []const u8) void {
    list.remove(path);
}

pub fn add(path: []const u8) !void {
    if (list.search(path) != null) return;
    const dev = try new(path);
    const event = try list.add(dev);
    events.post(event);
}

fn new(path: []const u8) !*Device {
    var path_copy: [:0]u8 = try allocator.allocSentinel(u8, path.len, 0);
    std.mem.copyForwards(u8, path_copy, path);
    var device = try allocator.create(Device);
    device.* = Device{};
    try device.init(path_copy);
    return device;
}

const Monome_t = enum { Grid, Arc };

pub const Device = struct {
    id: usize = undefined,
    thread: std.Thread = undefined,
    quit: bool = undefined,
    path: [:0]const u8 = undefined,
    serial: []const u8 = undefined,
    name: []const u8 = undefined,
    dev_type: Monome_t = undefined,
    m_dev: *c.struct_monome = undefined,
    data: [4][64]u8 = undefined,
    dirty: [4]bool = undefined,
    cols: u8 = undefined,
    rows: u8 = undefined,
    quads: u8 = undefined,
    pub fn init(self: *Device, path: [:0]const u8) !void {
        self.path = path;
        var m = c.monome_open(path) orelse {
            std.debug.print("error: couldn't open monome device at {s}\n", .{path});
            return error.Fail;
        };
        self.m_dev = m;
        self.id = id;
        id += 1;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            self.dirty[i] = false;
            var j: u8 = 0;
            while (j < 64) : (j += 1) {
                self.data[i][j] = 0;
            }
        }
        self.rows = @intCast(u8, c.monome_get_rows(m));
        self.cols = @intCast(u8, c.monome_get_cols(m));

        if (self.rows == 0 and self.cols == 0) {
            std.debug.print("monome device reports zero rows/cols; assuming arc\n", .{});
            self.dev_type = .Arc;
            self.quads = 4;
        } else {
            self.dev_type = .Grid;
            self.quads = (self.rows * self.cols) / 64;
            std.debug.print("monome device appears to be a grid; rows={d}, cols={d}; quads={d}\n", .{ self.rows, self.cols, self.quads });
        }

        self.name = std.mem.span(c.monome_get_friendly_name(m));
        self.serial = std.mem.span(c.monome_get_serial(m));

        self.quit = false;
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }
    pub fn deinit(self: *Device) void {
        self.quit = true;
        self.thread.join();
        c.monome_close(self.m_dev);
        allocator.free(self.path);
        allocator.destroy(self);
    }
    pub fn set_rotation(self: *Device, rotation: u8) void {
        c.monome_set_rotation(self.m_dev, rotation);
    }
    pub fn tilt_enable(self: *Device, sensor: u8) void {
        _ = c.monome_tilt_enable(self.m_dev, sensor);
    }
    pub fn tilt_disable(self: *Device, sensor: u8) void {
        _ = c.monome_tilt_disable(self.m_dev, sensor);
    }
    pub fn grid_set_led(self: *Device, x: u8, y: u8, val: u8) void {
        const q = quad_index(x, y);
        self.data[q][quad_offset(x, y)] = val;
        self.dirty[q] = true;
    }
    pub fn grid_all_led(self: *Device, val: u8) void {
        var q: u8 = 0;
        while (q < self.quads) : (q += 1) {
            var i: u8 = 0;
            while (i < 64) : (i += 1) {
                self.data[q][i] = val;
            }
            self.dirty[q] = true;
        }
    }
    pub fn arc_set_led(self: *Device, ring: u8, led: u8, val: u8) void {
        self.data[ring][led] = val;
        self.dirty[ring] = true;
    }
    pub fn refresh(self: *Device) void {
        const quad_xoff = [_]u8{ 0, 8, 0, 8 };
        const quad_yoff = [_]u8{ 0, 0, 8, 8 };
        var quad: u8 = 0;
        while (quad < self.quads) : (quad += 1) {
            if (self.dirty[quad]) {
                switch (self.dev_type) {
                    .Arc => _ = c.monome_led_ring_map(self.m_dev, quad, &self.data[quad]),
                    .Grid => _ = c.monome_led_level_map(self.m_dev, quad_xoff[quad], quad_yoff[quad], &self.data[quad]),
                }
            }
            self.dirty[quad] = false;
        }
    }
    pub fn intensity(self: *Device, level: u8) void {
        if (level > 15) {
            _ = c.monome_led_intensity(self.m_dev, 15);
        } else {
            _ = c.monome_led_intensity(self.m_dev, level);
        }
    }
};

inline fn quad_index(x: u8, y: u8) u8 {
    switch (y) {
        0...7 => {
            switch (x) {
                0...7 => return 0,
                else => return 1,
            }
        },
        else => {
            switch (x) {
                0...7 => return 2,
                else => return 3,
            }
        },
    }
}

inline fn quad_offset(x: u8, y: u8) u8 {
    return ((y & 7) * 8) + (x & 7);
}

fn loop(self: *Device) !void {
    const fd = c.monome_get_fd(self.m_dev);
    var fds = [1]std.os.pollfd{.{ .fd = fd, .events = std.os.POLL.IN, .revents = 0 }};
    var ev: c.monome_event = undefined;
    while (!self.quit) {
        if (c.monome_event_next(self.m_dev, &ev) > 0) {
            switch (ev.event_type) {
                c.MONOME_BUTTON_UP => {
                    const x = ev.unnamed_0.grid.x;
                    const y = ev.unnamed_0.grid.y;
                    const event = .{ .Grid_Key = .{ .id = self.id, .x = x, .y = y, .state = 0 } };
                    events.post(event);
                },
                c.MONOME_BUTTON_DOWN => {
                    const x = ev.unnamed_0.grid.x;
                    const y = ev.unnamed_0.grid.y;
                    const event = .{ .Grid_Key = .{ .id = self.id, .x = x, .y = y, .state = 1 } };
                    events.post(event);
                },
                c.MONOME_ENCODER_DELTA => {
                    const ring = ev.unnamed_0.encoder.number;
                    const delta = ev.unnamed_0.encoder.delta;
                    const event = .{ .Arc_Encoder = .{ .id = self.id, .ring = ring, .delta = delta } };
                    events.post(event);
                },
                c.MONOME_ENCODER_KEY_UP => {
                    const ring = ev.unnamed_0.encoder.number;
                    const event = .{ .Arc_Key = .{ .id = self.id, .ring = ring, .state = 0 } };
                    events.post(event);
                },
                c.MONOME_ENCODER_KEY_DOWN => {
                    const ring = ev.unnamed_0.encoder.number;
                    const event = .{ .Arc_Key = .{ .id = self.id, .ring = ring, .state = 1 } };
                    events.post(event);
                },
                c.MONOME_TILT => {
                    const sensor = ev.unnamed_0.tilt.sensor;
                    const x = ev.unnamed_0.tilt.x;
                    const y = ev.unnamed_0.tilt.y;
                    const z = ev.unnamed_0.tilt.z;
                    const event = .{ .Grid_Tilt = .{ .id = self.id, .sensor = sensor, .x = x, .y = y, .z = z } };
                    events.post(event);
                },
                else => {
                    @setCold(true);
                    std.debug.print("got bad event type: {d}", .{ev.event_type});
                },
            }
        } else {
            _ = try std.os.poll(&fds, 1000);
        }
    }
}
