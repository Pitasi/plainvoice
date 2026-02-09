const Writer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

w: *std.io.Writer,
_written: usize = 0,

pub fn init(w: *std.io.Writer) Writer {
    return .{ .w = w };
}

pub fn write(w: *Writer, bytes: []const u8) !void {
    try w.w.writeAll(bytes);
    w._written += bytes.len;
}

pub fn allocPrint(w: *Writer, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(bytes);
    try w.write(bytes);
}

pub fn bufPrint(w: *Writer, buf: []u8, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.bufPrint(buf, fmt, args);
    try w.write(bytes);
}

pub fn flush(w: *Writer) !void {
    try w.w.flush();
}

pub fn written(w: Writer) usize {
    return w._written;
}
