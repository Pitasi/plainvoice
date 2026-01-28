const Invoice = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

title: ?[]const u8,
date: ?[]const u8,
from: ?[]const u8,
to: ?[]const u8,
items: std.ArrayList(Item),

pub const Item = struct {
    name: []const u8,
    quantity: f32, // TODO don't use f32 for decimals in financial calculations
    cost: f32,
};

pub const InvoiceError = error{
    NoTitle,
    NoDate,
    NoFrom,
    NoTo,
};

pub fn valid(inv: Invoice) !void {
    if (inv.title == null) {
        return InvoiceError.NoTitle;
    }
    if (inv.date == null) {
        return InvoiceError.NoDate;
    }
    if (inv.from == null) {
        return InvoiceError.NoFrom;
    }
    if (inv.to == null) {
        return InvoiceError.NoTo;
    }
}

pub fn total(inv: Invoice) f32 {
    var t: f32 = 0;
    for (inv.items.items) |i| {
        t += i.quantity * i.cost;
    }
    return t;
}

pub const List = struct {
    gpa: Allocator,
    list: std.ArrayList(Invoice),

    pub fn init(gpa: Allocator) !List {
        return .{
            .gpa = gpa,
            .list = try std.ArrayList(Invoice).initCapacity(gpa, 0),
        };
    }

    pub fn append(list: *List) !*Invoice {
        try list.list.append(list.gpa, .{
            .title = null,
            .date = null,
            .from = null,
            .to = null,
            .items = try std.ArrayList(Invoice.Item).initCapacity(list.gpa, 0),
        });

        return &list.list.items[list.list.items.len - 1];
    }

    pub fn invoices(list: List) []Invoice {
        return list.list.items;
    }

    pub fn deinit(list: *List) void {
        for (list.list.items) |*inv| {
            inv.items.deinit(list.gpa);
        }
        list.list.deinit(list.gpa);
    }
};
