const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const TreeMenuProjection = render_input.TreeMenuProjection;

pub const max_visible_items: u16 = 20;
const roomy_header_rows: u16 = 2;
pub const max_inline_rows: u16 = roomy_header_rows + max_visible_items;

const BodyRow = union(enum) {
    none,
    item: struct {
        index: usize,
        preview: []const u8,
        selected: bool,
        marker: []const u8,
        abandoned: bool,
    },
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
};

pub fn menuRowCount(projection: TreeMenuProjection, width: u16, max_rows: u16) u16 {
    return buildLayout(projection, width, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: TreeMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    return @max(buildLayout(projection, width, row_budget).visible_items, 1);
}

pub fn composeTreeMenuRow(
    alloc: Allocator,
    projection: TreeMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return empty;

    const layout = buildLayout(projection, width, row_count);
    if (row_index < layout.body_start_row) {
        if (row_index == 0) return composeHeaderRow(alloc, projection, width);
        return empty;
    }
    if (layout.match_count == 0) return composeEmptyRow(alloc, width);

    return switch (bodyRowAt(projection, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .item => |item| composeTurnRow(alloc, item, width),
    };
}

fn buildLayout(projection: TreeMenuProjection, width: u16, max_rows: u16) Layout {
    _ = width;
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const show_header = max_rows > 2;
    const body_start_row: u16 = if (show_header) roomy_header_rows else 0;
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = @min(max_rows, body_start_row + 1),
        };
    }

    const body_budget = max_rows - body_start_row;
    var first_item = @min(projection.window_start, match_count - 1);
    if (selected < first_item) first_item = selected;
    var body = measureBody(projection, first_item, body_budget);
    while (selected >= first_item + body.visible_items and first_item < selected) {
        first_item += 1;
        body = measureBody(projection, first_item, body_budget);
    }
    if (body.visible_items == 0) {
        first_item = selected;
        body = measureBody(projection, first_item, body_budget);
    }
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = body.visible_items,
        .body_start_row = body_start_row,
        .row_count = body_start_row + body.rows,
    };
}

const BodyMeasurement = struct {
    visible_items: u16 = 0,
    rows: u16 = 0,
};

fn measureBody(projection: TreeMenuProjection, first_item: usize, row_budget: u16) BodyMeasurement {
    var measurement: BodyMeasurement = .{};
    var display_index = first_item;
    while (display_index < projection.filteredItemCount()) : (display_index += 1) {
        const required: u16 = 1;
        if (measurement.rows + required > row_budget) break;
        measurement.rows += required;
        measurement.visible_items += 1;
        if (measurement.visible_items == max_visible_items) break;
    }
    return measurement;
}

fn bodyRowAt(projection: TreeMenuProjection, layout: Layout, target: u16) BodyRow {
    const display_index = layout.first_item + target;
    const node = projection.itemAt(display_index) orelse return .none;
    const active = projection.turnActive(node.index);
    const is_leaf = projection.leaf != 0 and node.index == projection.leaf;
    return .{ .item = .{
        .index = node.index,
        .preview = node.preview,
        .selected = display_index == layout.selected,
        .marker = if (is_leaf) "<<" else if (active) "  " else " .",
        .abandoned = !active,
    } };
}

fn composeHeaderRow(alloc: Allocator, projection: TreeMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Conversation tree {d} · enter rewind · esc close", .{projection.filteredItemCount()}) catch "Conversation tree";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
    return cloneClippedRow(alloc, row.items, width);
}

fn composeTurnRow(alloc: Allocator, item: anytype, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const style = if (item.selected) ui_render.selected_completion_style else if (item.abandoned) ui_render.dim_style else ui_render.reset_style;
    try row.appendSlice(alloc, style);
    var num_buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, " {d: >3} {s} ", .{ item.index, item.marker }) catch " ... ";
    try row.appendSlice(alloc, num);
    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    const preview_budget = if (width > used + 1) width - used - 1 else 0;
    const suffix = if (item.abandoned) " (abandoned)" else "";
    if (preview_budget > suffix.len + 2) {
        try row_text.appendSingleLineEllipsized(alloc, &row, item.preview, preview_budget - suffix.len);
    } else {
        try row_text.appendSingleLineEllipsized(alloc, &row, item.preview, preview_budget);
    }
    if (item.abandoned) try row.appendSlice(alloc, suffix);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}

fn composeEmptyRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, "No turns recorded yet.", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}
