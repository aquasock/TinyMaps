// Testbench for maps_nav: pan, zoom, and the level crossing.
//
// The checks are properties, not a second implementation of the arithmetic:
// a pan of 32 output pixels moves the origin by 32 times the step, a zoom keeps
// the centre of the screen on the same ground point, a crossing doubles or
// halves the origin and lands on the next level's base, and the clamps hold at
// both ends of the level.  Restating the module's own sums here would only
// prove that two copies agree.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_nav;

reg clk = 0;
always #5 clk = ~clk;

reg resetn = 0;
reg [24:0] cur_base = 0;
reg [15:0] cur_w = 768, cur_h = 768;
reg [31:0] cur_step = 32'd39322;          // 0.6
reg signed [31:0] cur_x0 = 0, cur_y0 = 0;

reg  [3:0]  lv_valid = 4'b1111;
wire [24:0] lv_base0 = 25'd0,          lv_base1 = 25'd21233664,
            lv_base2 = 25'd27131904,   lv_base3 = 25'd28770304;
wire [15:0] lv_w0 = 16'd4608, lv_w1 = 16'd2304, lv_w2 = 16'd1280, lv_w3 = 16'd768;
wire [15:0] lv_h0 = 16'd4608, lv_h1 = 16'd2560, lv_h2 = 16'd1280, lv_h3 = 16'd768;

reg        clear = 0;
reg        ev = 0;
reg signed [15:0] ev_px = 0, ev_py = 0;
reg signed [1:0]  ev_zoom = 0;

wire        o_we;
wire [24:0] o_base;
wire [15:0] o_w, o_h;
wire [31:0] o_step;
wire signed [31:0] o_x0, o_y0;
wire        busy;

maps_nav #(.OUT_W(1280), .OUT_H(720)) dut (
    .clk(clk), .resetn(resetn),
    .cur_base(cur_base), .cur_w(cur_w), .cur_h(cur_h),
    .cur_step(cur_step), .cur_x0(cur_x0), .cur_y0(cur_y0),
    .lv_valid(lv_valid),
    .lv_base0(lv_base0), .lv_base1(lv_base1), .lv_base2(lv_base2), .lv_base3(lv_base3),
    .lv_w0(lv_w0), .lv_w1(lv_w1), .lv_w2(lv_w2), .lv_w3(lv_w3),
    .lv_h0(lv_h0), .lv_h1(lv_h1), .lv_h2(lv_h2), .lv_h3(lv_h3),
    .clear(clear), .ev(ev), .ev_px(ev_px), .ev_py(ev_py), .ev_zoom(ev_zoom),
    .o_we(o_we), .o_base(o_base), .o_w(o_w), .o_h(o_h), .o_step(o_step),
    .o_x0(o_x0), .o_y0(o_y0), .busy(busy)
);

integer errors = 0;

// drive one event and adopt what comes back
task automatic act(input signed [15:0] px, input signed [15:0] py, input signed [1:0] z);
    integer t;
begin
    ev = 1; ev_px = px; ev_py = py; ev_zoom = z;
    @(posedge clk);
    ev = 0;
    t = 0;
    while (!o_we && t < 200) begin
        @(posedge clk);
        t = t + 1;
    end
    if (!o_we) begin
        $display("  no result for event (%0d,%0d,%0d)", px, py, z);
        errors = errors + 1;
    end else begin
        cur_base = o_base; cur_w = o_w; cur_h = o_h;
        cur_step = o_step; cur_x0 = o_x0; cur_y0 = o_y0;
    end
end
endtask

task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

integer x_before, max_x, centre_before, centre_after;

task automatic reset_pan;
begin
    clear = 1;
    @(posedge clk);
    clear = 0;
    @(posedge clk);
end
endtask

initial begin
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // the finest level at 1:1, so there is room to pan in every direction
    cur_base = lv_base0; cur_w = 4608; cur_h = 4608; cur_step = 32'd65536;
    cur_x0 = 0; cur_y0 = 0;

    // --- pan right by 32 output pixels: the origin moves 32 * step
    reset_pan;
    x_before = cur_x0;
    act(32, 0, 0);
    want(cur_x0 - x_before == 32 * 65536, "pan of 32 pixels moves 32 steps");
    want(cur_step == 32'd65536, "pan leaves the step alone");

    // --- pan back past the left edge: stops at zero
    reset_pan;
    act(-128, 0, 0);
    want(cur_x0 == 0, "pan clamps at the left edge");

    // --- a level exactly as wide as the screen has nowhere to pan to
    reset_pan;
    cur_base = lv_base3; cur_w = 768; cur_h = 768; cur_step = 32'd39322;
    cur_x0 = 0; cur_y0 = 0;
    act(128, 0, 0);
    want(cur_x0 == 0, "a level no wider than the screen does not pan");

    // --- zoom in from the middle of the table: one step, centre preserved
    reset_pan;
    cur_base = lv_base0; cur_w = 4608; cur_h = 4608;
    cur_x0 = 655360; cur_y0 = 327680; cur_step = 32'd46341;   // 0.7071
    centre_before = cur_x0 + 640 * 46341;
    act(0, 0, -1);
    want(cur_step == 32'd38970, "zoom in takes the next step down");
    centre_after = cur_x0 + 640 * 38970;
    want(centre_after - centre_before < 640 && centre_before - centre_after < 640,
         "zoom in keeps the centre within a pixel");

    // --- zoom in at the bottom of the table crosses to the finer level
    reset_pan;
    cur_base = lv_base1; cur_w = 2304; cur_h = 2560;
    cur_step = 32'd32768; cur_x0 = 65536; cur_y0 = 65536;
    act(0, 0, -1);
    want(o_base == lv_base0 && cur_base == lv_base0, "crossing finer switches level");
    want(cur_w == 4608 && cur_h == 4608, "crossing finer takes the finer size");
    want(cur_step == 32'd65536, "crossing finer lands on a step of 1.0");
    want(cur_x0 == 2 * 65536 && cur_y0 == 2 * 65536, "crossing finer doubles the origin");

    // --- zoom out at the top of the table crosses the other way
    reset_pan;
    cur_base = lv_base0; cur_w = 4608; cur_h = 4608;
    cur_step = 32'd65536; cur_x0 = 131072; cur_y0 = 131072;
    act(0, 0, 1);
    want(cur_base == lv_base1, "crossing coarser switches level");
    want(cur_step == 32'd32768, "crossing coarser lands on a step of 0.5");
    want(cur_x0 == 65536 && cur_y0 == 65536, "crossing coarser halves the origin");

    // --- at the finest level and the smallest step there is nowhere to go
    reset_pan;
    cur_base = lv_base0; cur_w = 4608; cur_h = 4608;
    cur_step = 32'd32768; cur_x0 = 65536; cur_y0 = 65536;
    act(0, 0, -1);
    want(cur_step == 32'd32768 && cur_x0 == 65536, "zoom stops at the finest");

    // --- and at the coarsest, the other way
    reset_pan;
    cur_base = lv_base3; cur_w = 768; cur_h = 768;
    cur_step = 32'd65536; cur_x0 = 0; cur_y0 = 0;
    act(0, 0, 1);
    want(cur_step == 32'd65536, "zoom stops at the coarsest");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (pan, clamps, zoom steps and both crossings)");
    $finish;
end

endmodule
