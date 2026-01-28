pub const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Invoice = @import("Invoice.zig");

pub fn parse(gpa: Allocator, input: []const u8) !Invoice.List {
    var invoices = try Invoice.List.init(gpa);
    var linesIter = std.mem.splitSequence(u8, input, "\n");

    var current: *Invoice = undefined;
    while (linesIter.next()) |line| {
        const cmd = parseLine(line);
        switch (cmd) {
            .invoice => {
                current = try invoices.append();
                current.title = cmd.invoice;
            },
            .date => {
                if (current.date != null) {
                    @panic("duplicate date");
                }
                current.date = cmd.date;
            },
            .from => {
                if (current.from != null) {
                    @panic("duplicate from");
                }
                current.from = cmd.from;
            },
            .to => {
                if (current.to != null) {
                    @panic("duplicate to");
                }
                current.to = cmd.to;
            },
            .item => {
                const cost = try std.fmt.parseFloat(f32, cmd.item.amount);
                try current.items.append(gpa, .{
                    .name = cmd.item.name,
                    .quantity = 1,
                    .cost = cost,
                });
            },
            else => {},
        }
    }

    return invoices;
}

const Cmd = union(enum) {
    empty,
    invoice: []const u8,
    date: []const u8,
    from: []const u8,
    to: []const u8,
    // tax: []const u8,
    item: struct {
        name: []const u8,
        amount: []const u8,
    },
};

const delim = " \t";

fn parseLine(line: []const u8) Cmd {
    var l = std.mem.trimLeft(u8, line, delim);

    if (l.len == 0) {
        return .empty;
    }

    var nextSpace: usize = undefined;
    if (std.mem.indexOfAny(u8, l, delim)) |n| {
        nextSpace = n;
    } else {
        std.debug.panic("missing arg: {s}", .{l});
    }

    const tag = l[0..nextSpace];
    const arg = std.mem.trim(u8, l[nextSpace..], delim);

    if (std.mem.eql(u8, "invoice", tag)) {
        return .{ .invoice = arg };
    }
    if (std.mem.eql(u8, "date", tag)) {
        return .{ .date = arg };
    }
    if (std.mem.eql(u8, "from", tag)) {
        return .{ .from = arg };
    }
    if (std.mem.eql(u8, "to", tag)) {
        return .{ .to = arg };
    }
    if (std.mem.eql(u8, "tax", tag)) {
        return .empty;
    }
    if (std.mem.eql(u8, "+", tag)) {
        var spaceBeforePrice: usize = undefined;
        if (std.mem.lastIndexOfAny(u8, arg, delim)) |n| {
            spaceBeforePrice = n;
        } else {
            @panic("no item price");
        }

        const itemName = std.mem.trim(u8, arg[0..spaceBeforePrice], delim);
        const itemPrice = std.mem.trim(u8, arg[spaceBeforePrice + 1 ..], delim);

        return .{ .item = .{ .amount = itemPrice, .name = itemName } };
    }

    return .empty;
}
