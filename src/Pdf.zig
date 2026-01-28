const Pdf = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const Writer = std.io.Writer;
const FontMetrics = @import("FontMetrics.zig");

const Object = struct {
    number: u8 = undefined,
    generation_number: u8 = 0,
    type: ObjectType,

    fn write(o: Object, writer: *Writer) !usize {
        return o.type.write(o.number, o.generation_number, writer);
    }

    fn deinit(o: *Object, gpa: Allocator) void {
        o.type.deinit(gpa);
        gpa.destroy(o);
    }

    fn addChildren(o: *Object, gpa: Allocator, child: *Object) !void {
        try o.type.addChildren(gpa, child);
    }

    fn getChildren(o: *Object) Children {
        return o.type.getChildren();
    }

    fn ref(o: Object, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{} {} R", .{ o.number, o.generation_number });
    }
};

const Iterator = struct {
    allocator: Allocator,
    stack: std.ArrayList(*Object),

    const Self = @This();

    pub fn init(allocator: Allocator, root: *Object) !Self {
        var stack = try std.ArrayList(*Object).initCapacity(allocator, 1);
        try stack.append(allocator, root);
        return .{ .allocator = allocator, .stack = stack };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit(self.allocator);
    }

    pub fn next(self: *Self) ?*Object {
        if (self.stack.pop()) |node| {
            // Push children in reverse order so leftmost is processed first
            const children = node.getChildren();
            switch (children) {
                .none => {},
                .one => {
                    self.stack.append(self.allocator, children.one) catch unreachable;
                },
                .many => {
                    var i = children.many.len;
                    while (i > 0) {
                        i -= 1;
                        self.stack.append(self.allocator, children.many[i]) catch unreachable;
                    }
                },
            }

            return node;
        }
        return null;
    }
};

const ObjectType = union(enum) {
    catalog: CatalogNode,
    pages: PagesNode,
    page: PageNode,
    stream: StreamNode,
    raw: RawNode,

    fn deinit(self: *ObjectType, gpa: Allocator) void {
        switch (self.*) {
            inline else => |*obj| return obj.deinit(gpa),
        }
    }

    fn write(self: ObjectType, number: u8, generation_number: u8, writer: anytype) !usize {
        switch (self) {
            inline else => |obj| return obj.write(number, generation_number, writer),
        }
    }

    fn getChildren(self: *ObjectType) Children {
        switch (self.*) {
            inline else => |*obj| return obj.getChildren(),
        }
    }

    fn addChildren(self: *ObjectType, gpa: Allocator, child: *Object) !void {
        switch (self.*) {
            inline else => |*obj| return obj.addChildren(gpa, child),
        }
    }
};

const CatalogNode = struct {
    pages: *Object,

    fn deinit(self: *CatalogNode, gpa: Allocator) void {
        self.pages.deinit(gpa);
    }

    fn write(self: CatalogNode, number: u8, generation_number: u8, writer: *Writer) !usize {
        var refBuf: [64]u8 = undefined;
        var buf: [1024]u8 = undefined;
        const ref = try self.pages.ref(&refBuf);
        const printBuf = try std.fmt.bufPrint(&buf, "{} {} obj << /Type /Catalog /Pages {s} >> endobj\n", .{ number, generation_number, ref });
        return writer.write(printBuf);
    }

    fn getChildren(self: *CatalogNode) Children {
        return .{ .one = self.pages };
    }

    fn addChildren(_: *CatalogNode, _: Allocator, _: *Object) !void {
        unreachable;
    }
};

fn initCatalog(allocator: std.mem.Allocator, pages: *Object) !*Object {
    const ptr = try allocator.create(Object);
    ptr.* = .{ .type = .{
        .catalog = .{
            .pages = pages,
        },
    } };
    return ptr;
}

const PagesNode = struct {
    children: ArrayList(*Object),

    fn deinit(pages: *PagesNode, gpa: Allocator) void {
        for (pages.children.items) |c| {
            c.deinit(gpa);
        }
        pages.children.deinit(gpa);
    }

    fn write(pages: PagesNode, number: u8, generation_number: u8, writer: *Writer) !usize {
        // /Type /Pages /Kids [3 0 R 6 0 R] /Count 2
        var buf: [1024]u8 = undefined;
        var printBuf: []u8 = undefined;

        var written: usize = 0;

        printBuf = try std.fmt.bufPrint(&buf, "{} {} obj << /Type /Pages /Kids [", .{ number, generation_number });
        written += try writer.write(printBuf);

        var refBuf: [64]u8 = undefined;
        const pagesCount = pages.children.items.len;
        for (pages.children.items, 0..) |c, i| {
            written += try writer.write(try c.ref(&refBuf));
            if (i != pagesCount - 1) {
                written += try writer.write(" ");
            }
        }
        printBuf = try std.fmt.bufPrint(&buf, "] /Count {} >> endobj\n", .{pagesCount});
        written += try writer.write(printBuf);

        return written;
    }

    fn getChildren(pages: PagesNode) Children {
        return .{ .many = pages.children.items };
    }

    fn addChildren(pages: *PagesNode, gpa: Allocator, child: *Object) !void {
        try pages.children.append(gpa, child);
    }
};

fn initPages(allocator: std.mem.Allocator) !*Object {
    const ptr = try allocator.create(Object);
    ptr.* = .{ .type = .{
        .pages = .{
            .children = try ArrayList(*Object).initCapacity(allocator, 1),
        },
    } };
    return ptr;
}

const PageNode = struct {
    pages: *Object,
    stream_content: *Object,
    resources: std.ArrayList(*Object),

    fn getChildren(page: *PageNode) Children {
        return .{ .one = page.stream_content };
    }

    fn addChildren(_: *PageNode, _: Allocator, _: *Object) !void {}

    fn deinit(page: *PageNode, gpa: Allocator) void {
        page.stream_content.deinit(gpa);
    }

    fn write(page: PageNode, number: u8, generation_number: u8, writer: *Writer) !usize {
        var parentRefBuf: [64]u8 = undefined;
        const parentRef = try page.pages.ref(&parentRefBuf);

        var contentRefBuf: [64]u8 = undefined;
        const contentRef = try page.stream_content.ref(&contentRefBuf);

        var written: usize = 0;

        var buf: [1024]u8 = undefined;
        const printBuf = try std.fmt.bufPrint(&buf, "{} {} obj << /Type /Page /Parent {s} /MediaBox [0 0 595 842] /Contents {s} /Resources << /Font << ", .{ number, generation_number, parentRef, contentRef });
        written += try writer.write(printBuf);

        for (page.resources.items, 1..) |obj, i| {
            var fontRefBuf: [64]u8 = undefined;
            const fontRef = try obj.ref(&fontRefBuf);

            const printBuf2 = try std.fmt.bufPrint(&buf, "/F{} {s} ", .{ i, fontRef });
            try writer.writeAll(printBuf2);
            written += printBuf2.len;
        }

        written += try writer.write(">> >> >> endobj\n");

        return written;
    }
};

fn initPage(gpa: Allocator, pages: *Object, content: *Object, resources: std.ArrayList(*Object)) !*Object {
    const ptr = try gpa.create(Object);
    ptr.* = .{
        .type = .{
            .page = .{
                .pages = pages,
                .stream_content = content,
                .resources = resources,
            },
        },
    };
    return ptr;
}

const StreamNode = struct {
    data: ArrayList([]const u8),

    fn getChildren(_: *StreamNode) Children {
        return .none;
    }

    fn addChildren(_: *StreamNode, _: Allocator, _: *Object) !void {}

    fn deinit(stream: *StreamNode, gpa: Allocator) void {
        for (stream.data.items) |chunk| {
            gpa.free(chunk);
        }
        stream.data.deinit(gpa);
    }

    fn append(stream: *StreamNode, gpa: Allocator, data: []const u8) !void {
        try stream.data.append(gpa, data);
    }

    fn write(stream: StreamNode, number: u8, generation_number: u8, writer: *Writer) !usize {
        var written: usize = 0;
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        for (stream.data.items) |chunk| {
            len += chunk.len;
        }
        const printBuf = try std.fmt.bufPrint(&buf, "{} {} obj << /Length {} >>\n", .{ number, generation_number, len });
        written += try writer.write(printBuf);
        written += try writer.write("stream\n");
        for (stream.data.items) |chunk| {
            written += try writer.write(chunk);
        }
        written += try writer.write("\nendstream\n");
        written += try writer.write("endobj\n");
        return written;
    }
};

fn initStream(gpa: Allocator) !*Object {
    const ptr = try gpa.create(Object);
    ptr.* = .{
        .type = .{
            .stream = .{
                .data = try ArrayList([]const u8).initCapacity(gpa, 1),
            },
        },
    };
    return ptr;
}

const RawNode = struct {
    data: []const u8,
    children: ArrayList(*Object),

    fn getChildren(raw: *RawNode) Children {
        return .{ .many = raw.children.items };
    }

    fn addChildren(raw: *RawNode, gpa: Allocator, child: *Object) !void {
        try raw.children.append(gpa, child);
    }

    fn deinit(raw: *RawNode, gpa: Allocator) void {
        for (raw.children.items) |c| {
            c.deinit(gpa);
        }
        raw.children.deinit(gpa);
    }

    fn write(raw: RawNode, number: u8, generation_number: u8, writer: *Writer) !usize {
        var buf: [1024]u8 = undefined;
        const printBuf = try std.fmt.bufPrint(&buf, "{} {} obj << {s} >> endobj\n", .{ number, generation_number, raw.data });
        return writer.write(printBuf);
    }
};

fn initRaw(gpa: Allocator, data: []const u8) !*Object {
    const ptr = try gpa.create(Object);
    ptr.* = .{
        .type = .{
            .raw = .{
                .data = data,
                .children = try ArrayList(*Object).initCapacity(gpa, 0),
            },
        },
    };
    return ptr;
}

const Children = union(enum) {
    none,
    one: *Object,
    many: []*Object,
};

allocator: std.mem.Allocator,
resourcesByName: std.AutoHashMap(Font, u8),
resources: std.ArrayList(*Object),

catalog: *Object = undefined,
pages: *Object = undefined,

last_page: *Object = undefined,
last_page_content: *Object = undefined,

pub fn new(gpa: std.mem.Allocator) !Pdf {
    var pdf = Pdf{
        .allocator = gpa,
        .resourcesByName = std.AutoHashMap(Font, u8).init(gpa),
        .resources = try std.ArrayList(*Object).initCapacity(gpa, 2),
    };

    pdf.pages = try initPages(gpa);
    const catalog = try initCatalog(gpa, pdf.pages);
    pdf.catalog = catalog;

    try pdf.resources.append(gpa, try initRaw(gpa, "/Type /Font /Subtype /Type1 /BaseFont /Helvetica"));
    try pdf.resourcesByName.put(Font.Helvetica, @intCast(pdf.resources.items.len));
    try pdf.resources.append(gpa, try initRaw(gpa, "/Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold"));
    try pdf.resourcesByName.put(Font.HelveticaBold, @intCast(pdf.resources.items.len));

    return pdf;
}

pub fn deinit(self: *Pdf) void {
    self.catalog.deinit(self.allocator);

    // fonts
    for (self.resources.items) |obj| {
        obj.deinit(self.allocator);
    }
    self.resources.deinit(self.allocator);
    self.resourcesByName.deinit();
}

pub const Font = enum {
    Helvetica,
    HelveticaBold,
};

pub fn addPage(pdf: *Pdf) !void {
    const content = try initStream(pdf.allocator);
    pdf.last_page = try initPage(pdf.allocator, pdf.pages, content, pdf.resources);
    pdf.last_page_content = content;
    try pdf.pages.addChildren(pdf.allocator, pdf.last_page);
}

pub fn text(pdf: *Pdf, font: Font, font_size: f32, x: f32, y: f32, content: []const u8) !void {
    const cmds = [_]TextDirective{
        .{ .font = .{ .font = font, .size = font_size, .lineHeight = 1.2 } },
        .{ .move = .{ .x = x, .y = y } },
        .{ .text = content },
    };
    try pdf.textRaw(&cmds);
}

pub fn textRight(pdf: *Pdf, font: Font, font_size: f32, x: f32, y: f32, content: []const u8) !void {
    var width: f32 = 0;
    for (content) |c| {
        width += FontMetrics.width(font, c, font_size);
    }
    const cmds = [_]TextDirective{
        .{ .font = .{ .font = font, .size = font_size, .lineHeight = 1.2 } },
        .{ .move = .{ .x = x - width, .y = y } },
        .{ .text = content },
    };
    try pdf.textRaw(&cmds);
}

pub const TextDirective = union(enum) {
    font: struct {
        font: Font,
        size: f32,
        lineHeight: f32 = 1,
    },
    move: struct { x: f32, y: f32 },
    text: []const u8,
};

pub const Align = enum {
    Left,
    Right,
};

pub fn textRaw(pdf: *Pdf, dirs: []const TextDirective) !void {
    try pdf.appendStream("BT\n", .{});
    for (dirs) |dir| {
        switch (dir) {
            .font => {
                if (pdf.resourcesByName.get(dir.font.font)) |fontID| {
                    try pdf.appendStream(
                        \\/F{} {} Tf
                        \\{} TL
                        \\
                    , .{ fontID, dir.font.size, dir.font.size * dir.font.lineHeight });
                } else {
                    // TODO return error
                }
            },
            .move => {
                try pdf.appendStream(
                    \\{} {} Td
                    \\
                , .{ dir.move.x, dir.move.y });
            },
            .text => {
                var lines = std.mem.splitSequence(u8, dir.text, "\n");
                if (lines.next()) |l| {
                    try pdf.appendStream("({s}) Tj\n", .{l});
                }
                while (lines.next()) |l| {
                    try pdf.appendStream("({s}) '\n", .{l});
                }
            },
        }
    }
    try pdf.appendStream("ET\n", .{});
}

pub fn hline(pdf: *Pdf, x: f32, y: f32, width: f32, thickness: f32, grey: f32) !void {
    try pdf.line(x, y, x + width, y, thickness, grey);
}

pub fn line(pdf: *Pdf, x: f32, y: f32, toX: f32, toY: f32, thickness: f32, grey: f32) !void {
    try pdf.appendStream(
        \\q
        \\{} G
        \\{} w
        \\{} {} m
        \\{} {} l
        \\S
        \\Q
        \\
    , .{ grey, thickness, x, y, toX, toY });
}

pub fn appendStream(pdf: *Pdf, comptime fmt: []const u8, args: anytype) !void {
    const content = try std.fmt.allocPrint(pdf.allocator, fmt, args);
    try pdf.last_page_content.type.stream.append(pdf.allocator, content);
}

fn prepareIds(self: *Pdf) !void {
    var iter = try Iterator.init(self.allocator, self.catalog);
    defer iter.deinit();

    var i: u8 = 1;
    while (iter.next()) |node| {
        node.number = i;
        i += 1;
    }

    for (self.resources.items) |obj| {
        obj.*.number = i;
        i += 1;
    }
}

pub fn write(self: *Pdf, writer: *std.io.Writer) !usize {
    try self.prepareIds();

    //
    var writeOffsets = try ArrayList(usize).initCapacity(self.allocator, 1);
    defer writeOffsets.deinit(self.allocator);

    var written: usize = 0;
    var fmtBuf: [1024]u8 = undefined;

    written += try writer.write("%PDF-1.4\n");

    var entriesCount: usize = 1;
    var iter = try Iterator.init(self.allocator, self.catalog);
    defer iter.deinit();
    while (iter.next()) |node| {
        try writeOffsets.append(self.allocator, written);
        written += try node.write(writer);
        entriesCount += 1;
    }

    // write fonts objects
    for (self.resources.items) |obj| {
        try writeOffsets.append(self.allocator, written);
        written += try obj.write(writer);
        entriesCount += 1;
    }

    // write xref
    const startXref = written;
    written += try writer.write("xref\n");

    var printBuf = try std.fmt.bufPrint(&fmtBuf, "{} {}\n", .{ 0, entriesCount });
    written += try writer.write(printBuf);

    written += try writer.write("0000000000 65535 f\n");

    for (writeOffsets.items) |offset| {
        // TODO we hardcoded 0 as the generation number here
        printBuf = try std.fmt.bufPrint(&fmtBuf, "{d:0>10} {d:0>5} {c}\n", .{ offset, 0, 'n' });
        written += try writer.write(printBuf);
    }

    written += try writer.write("trailer\n");

    // "1 0 R" means that we expect the root element to be the first one
    printBuf = try std.fmt.bufPrint(&fmtBuf, "<< /Size {} /Root 1 0 R >>\n", .{entriesCount});
    written += try writer.write(printBuf);

    written += try writer.write("startxref\n");

    printBuf = try std.fmt.bufPrint(&fmtBuf, "{}\n", .{startXref});
    written += try writer.write(printBuf);

    written += try writer.write("%%EOF");

    try writer.flush();

    return written;
}
