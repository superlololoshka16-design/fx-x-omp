const std = @import("std");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const HubMenuProjection = render_input.HubMenuProjection;

pub const max_visible_items: u16 = 20;
const roomy_header_rows: u16 = 2;
pub const max_inline_rows: u16 = roomy_header_rows + max_visible_items;

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
};

fn itemCount(projection: HubMenuProjection) usize {
    return if (projection.open_peer != null) projection.mailboxLineCount() else projection.filteredItemCount();
}

pub fn menuRowCount(projection: HubMenuProjection, width: u16, max_rows: u16) u16 {
    return buildLayout(projection, width, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: HubMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    return @max(buildLayout(projection, width, row_budget).visible_items, 1);
}

pub fn composeHubMenuRow(
    alloc: Allocator,
    projection: HubMenuProjection,
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
    if (layout.match_count == 0) return composeEmptyRow(alloc, projection, width);

    const display_index = layout.first_item + (row_index - layout.body_start_row);
    const selected = display_index == layout.selected;
    if (projection.open_peer != null) {
        const line = projection.mailboxLineAt(display_index) orelse return empty;
        return composeMailboxRow(alloc, line, selected, width);
    }
    const peer = projection.itemAt(display_index) orelse return empty;
    return composePeerRow(alloc, peer.name, peer.messages, selected, width);
}

fn buildLayout(projection: HubMenuProjection, width: u16, max_rows: u16) Layout {
    _ = width;
    if (max_rows == 0) return .{};
    const match_count = itemCount(projection);
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
    var visible: u16 = 0;
    var rows: u16 = 0;
    var idx = first_item;
    while (idx < match_count) : (idx += 1) {
        if (rows + 1 > body_budget) break;
        rows += 1;
        visible += 1;
        if (visible == max_visible_items) break;
    }
    while (selected >= first_item + visible and first_item < selected) first_item += 1;
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = visible,
        .body_start_row = body_start_row,
        .row_count = body_start_row + rows,
    };
}

fn composeHeaderRow(alloc: Allocator, projection: HubMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [112]u8 = undefined;
    const title = if (projection.open_peer) |peer|
        std.fmt.bufPrint(&buf, "hub · {s} · backspace back · esc close", .{peer}) catch "Agent hub"
    else
        std.fmt.bufPrint(&buf, "Agent hub · {d} peer(s) · enter open · esc close", .{projection.filteredItemCount()}) catch "Agent hub";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
    return cloneClippedRow(alloc, row.items, width);
}

fn composePeerRow(alloc: Allocator, name: []const u8, messages: usize, selected: bool, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.reset_style);
    var buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&buf, " [{d}] ", .{messages}) catch " [-] ";
    try row.appendSlice(alloc, count);
    try row_text.appendSingleLineEllipsized(alloc, &row, name, if (width > 8) width - 8 else 0);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeMailboxRow(alloc: Allocator, line: []const u8, selected: bool, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, " ");
    try row_text.appendSingleLineEllipsized(alloc, &row, line, if (width > 2) width - 2 else 0);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeEmptyRow(alloc: Allocator, projection: HubMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    const msg = if (projection.open_peer != null) "(empty mailbox)" else "Hub is empty. Agents message each other with the hub tool.";
    try row_text.appendSingleLineEllipsized(alloc, &row, msg, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}
