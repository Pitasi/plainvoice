const std = @import("std");
const Allocator = std.mem.Allocator;

const plainvoice_zig = @import("plainvoice_zig");
const Pdf = @import("Pdf.zig");
const Font = Pdf.Font;
const Parser = @import("Parser.zig");
const Invoice = @import("Invoice.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("memory leak");
    }

    var args = std.process.args();
    if (!args.skip()) {
        @panic("couldn't skip argv[0]");
    }

    while (args.next()) |a| {
        try processInputFile(allocator, a);
    }
}

pub fn processInputFile(gpa: Allocator, path: []const u8) !void {
    const input = try std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024);
    defer gpa.free(input);

    const wd = if (std.fs.path.dirname(path)) |p| try std.fs.cwd().openDir(p, .{}) else std.fs.cwd();

    var parsed = try Parser.parse(gpa, input);
    defer parsed.deinit();

    // generate PDFs
    std.fs.cwd().makeDir("out") catch {};

    for (parsed.invoices()) |inv| {
        inv.valid() catch |err| {
            std.debug.print("skipping invalid invoice: {}\n", .{err});
            continue;
        };

        const outPath = try std.fmt.allocPrint(gpa, "out/{s}.pdf", .{inv.title.?});
        defer gpa.free(outPath);

        const file = try std.fs.cwd().createFile(outPath, .{});
        defer file.close();
        errdefer std.fs.cwd().deleteFile(outPath) catch {};
        var buf: [1024 * 1024]u8 = undefined;
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;

        const written = try invoiceToPDF(gpa, wd, writer, inv);

        std.debug.print("{s}: written {} bytes\n", .{ outPath, written });
    }
}

fn invoiceToPDF(gpa: Allocator, wd: std.fs.Dir, writer: *std.io.Writer, invoice: Invoice) !usize {
    var p = try Pdf.new(gpa);
    defer p.deinit();

    try p.addPage();

    const pageXMargin = 38;
    const pageYMargin = 56;
    const sectionGap = 15;
    const x = pageXMargin;
    var y: f32 = 842 - pageYMargin;

    // title
    try p.text(Font.HelveticaBold, 22, x, y, "Invoice");
    y -= sectionGap;
    y -= 24;

    // header
    const labelGap = 2;
    const labelFontSize = 10;
    try labelValue(&p, x, y, "Date", invoice.date.?);
    y -= labelFontSize * 1.2;
    y -= labelGap;
    try labelValue(&p, x, y, "Invoice Number", invoice.title.?);
    y -= labelFontSize * 1.2;
    y -= labelGap;
    try labelValue(&p, x, y, "Invoice Due", invoice.date.?);
    y -= labelFontSize * 1.2;
    y -= labelGap;

    y -= sectionGap;

    // from
    var fromY = y;
    try p.text(Font.HelveticaBold, labelFontSize, x, fromY, "From");
    fromY -= labelFontSize * 1.2;

    const isFromExternal = invoice.from.?[0] == '@';
    const from = if (isFromExternal)
        try wd.readFileAlloc(gpa, invoice.from.?[1..], 1024)
    else
        invoice.from.?;
    try p.text(Font.Helvetica, labelFontSize, x, fromY, from);
    defer if (isFromExternal) gpa.free(from);

    // to
    var toY = y;
    const toX = x + (595 - pageXMargin) / 2;
    try p.text(Font.HelveticaBold, labelFontSize, toX, toY, "To");
    toY -= labelFontSize * 1.2;

    const isToExternal = invoice.to.?[0] == '@';
    const to = if (isToExternal)
        try wd.readFileAlloc(gpa, invoice.to.?[1..], 1024)
    else
        invoice.to.?;
    try p.text(Font.Helvetica, labelFontSize, toX, toY, to);
    defer if (isToExternal) gpa.free(to);

    y = @min(fromY - 6 * 12 * 1.2, toY - 6 * 12 * 1.2);
    y -= 3 * sectionGap;

    // items
    const contentWidth: f32 = 595 - 2 * pageXMargin;
    const columnMainWidth = contentWidth * 0.4;
    const nCols = 3;
    const columnWidth = (contentWidth - columnMainWidth) / nCols;

    const tableFontSize = 9;

    _ = try p.text(Font.HelveticaBold, tableFontSize, x, y, "Description");
    _ = try p.textRight(Font.HelveticaBold, tableFontSize, x + columnWidth + columnMainWidth, y, "Quantity");
    _ = try p.textRight(Font.HelveticaBold, tableFontSize, x + columnWidth * 2 + columnMainWidth, y, "Rate");
    _ = try p.textRight(Font.HelveticaBold, tableFontSize, x + columnWidth * 3 + columnMainWidth, y, "Amount");

    y -= tableFontSize * 1.2;

    try p.hline(pageXMargin, y, 595 - 2 * pageXMargin, 1.8, 0.874);

    y -= tableFontSize * 2 + 1.8;

    var pbuf: [64]u8 = undefined;

    for (invoice.items.items) |it| {
        try p.text(Font.Helvetica, tableFontSize, x, y, it.name);

        const quantityStr = try std.fmt.bufPrint(&pbuf, "{}", .{it.quantity});
        try p.textRight(Font.Helvetica, tableFontSize, x + columnWidth + columnMainWidth, y, quantityStr);

        const costStr = try std.fmt.bufPrint(&pbuf, "{}", .{it.cost});
        try p.textRight(Font.Helvetica, tableFontSize, x + columnWidth * 2 + columnMainWidth, y, costStr);

        const itemTotalStr = try std.fmt.bufPrint(&pbuf, "EUR {}", .{it.quantity * it.cost});
        try p.textRight(Font.Helvetica, tableFontSize, x + columnWidth * 3 + columnMainWidth, y, itemTotalStr);

        y -= tableFontSize * 1.2;
        try p.hline(pageXMargin, y, 595 - 2 * pageXMargin, 0.8, 0.874);
    }

    y -= tableFontSize * 2 + 0.8;

    const totalRectWidth = contentWidth / 2;
    try p.text(Font.Helvetica, tableFontSize, x + totalRectWidth, y, "Sub total");
    const subtotalStr = try std.fmt.bufPrint(&pbuf, "{}", .{invoice.total()});
    try p.textRight(Font.Helvetica, tableFontSize, x + 2 * totalRectWidth, y, subtotalStr);

    y -= tableFontSize * 1.2;

    try p.hline(x + totalRectWidth, y, totalRectWidth, 0.8, 0.874);

    y -= tableFontSize * 2 + 0.8;

    try p.text(Font.HelveticaBold, tableFontSize, x + totalRectWidth, y, "Total");
    const totalStr = try std.fmt.bufPrint(&pbuf, "EUR {}", .{invoice.total()});
    try p.textRight(Font.HelveticaBold, tableFontSize, x + 2 * totalRectWidth, y, totalStr);

    y -= tableFontSize * 1.2;

    try p.hline(x + totalRectWidth, y, totalRectWidth, 0.8, 0.874);

    return try p.write(writer);
}

fn labelValue(pdf: *Pdf, x: f32, y: f32, label: []const u8, value: []const u8) !void {
    try pdf.textRaw(&[_]Pdf.TextDirective{
        .{ .font = .{ .font = Font.Helvetica, .size = 10, .lineHeight = 1.2 } },
        .{ .move = .{ .x = x, .y = y } },
        .{ .text = label },
        .{ .text = ": " },
        .{ .font = .{ .font = Font.HelveticaBold, .size = 10, .lineHeight = 1.2 } },
        .{ .text = value },
    });
}
