// TinyMaps navigation: pan and zoom from the board's mouse and keyboard.
//
// The viewport is (level, step, origin).  Panning moves the origin by whole
// 8-pixel nudges, because a mouse report counts output pixels and 8 output
// pixels is a shift of the step.  Zooming walks a five-entry table of steps
// between 0.5 and 1.0, a quarter of an octave apart, keeping the centre of the
// screen on the same ground point: the origin moves by half a line times the
// change in step.  When the table runs out at either end it steps to the next
// level and starts at the other end.  The pack's levels are a factor of two
// apart in metres per pixel, so a level crossing is a doubling of the source
// coordinates and nothing else -- 0.5 on one level is 1.0 on the finer one at
// twice the coordinates -- and the centre is preserved for free.
//
// Nothing here multiplies two variables: the step table is constant, half a
// line, a line and half a screen height are shift-and-add of the step, and the
// level and the table index are recovered from the current base and step by
// comparison rather than remembered.  So a viewport the host set over the link
// zooms sensibly from wherever it is, at whatever step it chose.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_nav #(
    parameter int OUT_W = 1280,
    parameter int OUT_H = 720
) (
    input  wire        clk,
    input  wire        resetn,

    // the viewport as it stands
    input  wire [24:0] cur_base,
    input  wire [15:0] cur_w,
    input  wire [15:0] cur_h,
    input  wire [31:0] cur_step,
    input  wire signed [31:0] cur_x0,
    input  wire signed [31:0] cur_y0,

    // the level table, as command 0x0B loaded it
    input  wire [3:0]  lv_valid,
    input  wire [24:0] lv_base0, lv_base1, lv_base2, lv_base3,
    input  wire [15:0] lv_w0, lv_w1, lv_w2, lv_w3,
    input  wire [15:0] lv_h0, lv_h1, lv_h2, lv_h3,

    // one event from the link
    input  wire        clear,          // a host viewport arrived: drop the pan remainder
    input  wire        ev,
    input  wire signed [15:0] ev_px,
    input  wire signed [15:0] ev_py,
    input  wire signed [1:0]  ev_zoom,

    // the viewport to latch
    output reg         o_we,
    output reg  [24:0] o_base,
    output reg  [15:0] o_w,
    output reg  [15:0] o_h,
    output reg  [31:0] o_step,
    output reg  signed [31:0] o_x0,
    output reg  signed [31:0] o_y0,
    output reg         busy
);

localparam signed [15:0] NUDGE = 16'sd8;      // output pixels per pan step

// quarter-octave steps: 0.5, 0.5946, 0.7071, 0.8409, 1.0
function automatic [31:0] step_of(input [2:0] i);
    case (i)
        3'd0: step_of = 32'd32768;
        3'd1: step_of = 32'd38970;
        3'd2: step_of = 32'd46341;
        3'd3: step_of = 32'd55109;
        default: step_of = 32'd65536;
    endcase
endfunction

function automatic [24:0] base_of(input [1:0] l);
    case (l)
        2'd0: base_of = lv_base0;
        2'd1: base_of = lv_base1;
        2'd2: base_of = lv_base2;
        default: base_of = lv_base3;
    endcase
endfunction
function automatic [15:0] w_of(input [1:0] l);
    case (l)
        2'd0: w_of = lv_w0;
        2'd1: w_of = lv_w1;
        2'd2: w_of = lv_w2;
        default: w_of = lv_w3;
    endcase
endfunction
function automatic [15:0] h_of(input [1:0] l);
    case (l)
        2'd0: h_of = lv_h0;
        2'd1: h_of = lv_h1;
        2'd2: h_of = lv_h2;
        default: h_of = lv_h3;
    endcase
endfunction

// which level the base belongs to, and which table step is nearest
reg [1:0] lvl;
reg [2:0] idx;

always @* begin
    lvl = 2'd0;
    if (lv_valid[0] && cur_base == lv_base0)      lvl = 2'd0;
    else if (lv_valid[1] && cur_base == lv_base1) lvl = 2'd1;
    else if (lv_valid[2] && cur_base == lv_base2) lvl = 2'd2;
    else if (lv_valid[3] && cur_base == lv_base3) lvl = 2'd3;

    idx = 3'd0;
    if      (cur_step > 32'd62460) idx = 3'd4;
    else if (cur_step > 32'd50725) idx = 3'd3;
    else if (cur_step > 32'd42655) idx = 3'd2;
    else if (cur_step > 32'd35869) idx = 3'd1;
end

reg signed [15:0] acc_x, acc_y;
reg signed [31:0] nx0, ny0;
reg        z_in, z_out;
reg [4:0]  ct;
reg [1:0]  c_level;
reg [2:0]  c_idx;
reg [1:0]  t_level;
reg [31:0] t_step;
reg        t_fine, t_coarse;

localparam [2:0] N_IDLE = 3'd0, N_PAN = 3'd1, N_ZOOM = 3'd2,
                 N_APPLY = 3'd3, N_DONE = 3'd4;
reg [2:0] ns;

// the new step, and the step in force, as signed values for the arithmetic
wire signed [31:0] s_old = $signed({1'b0, cur_step[30:0]});
wire signed [31:0] s_new = $signed({1'b0, t_step[30:0]});
wire signed [31:0] s_diff = s_old - s_new;

// origin shift that keeps the centre still: half a line across, half a screen
// down, times the change in step
wire signed [31:0] dx_centre = (s_diff <<< 9) + (s_diff <<< 7);                      // 640
wire signed [31:0] dy_centre = (s_diff <<< 8) + (s_diff <<< 6) +
                               (s_diff <<< 5) + (s_diff <<< 3);                      // 360

// The furthest the origin can go with a given step.  A level narrower than the
// screen leaves no room at all, so the bound is held at zero rather than going
// negative -- a negative bound would let the origin go negative and read before
// the level.
function automatic signed [31:0] max_steps(input signed [31:0] room);
    max_steps = (room > 0) ? room : 32'sd0;
endfunction

wire signed [31:0] max_x_new = max_steps($signed({16'd0, w_of(t_level)}) * 32'sd65536 -
                               ((s_new <<< 10) + (s_new <<< 8)));                    // 1280
wire signed [31:0] max_y_new = max_steps($signed({16'd0, h_of(t_level)}) * 32'sd65536 -
                               ((s_new <<< 9) + (s_new <<< 7) +
                                (s_new <<< 6) + (s_new <<< 4)));                     // 720

wire signed [31:0] nudge = s_old <<< 3;        // 8 * step
wire signed [31:0] max_x_old = max_steps($signed({16'd0, cur_w}) * 32'sd65536 -
                               ((s_old <<< 10) + (s_old <<< 8)));
wire signed [31:0] max_y_old = max_steps($signed({16'd0, cur_h}) * 32'sd65536 -
                               ((s_old <<< 9) + (s_old <<< 7) +
                                (s_old <<< 6) + (s_old <<< 4)));

reg signed [31:0] ax0, ay0;

always @(posedge clk) begin
    o_we <= 1'b0;
    if (!resetn) begin
        ns <= N_IDLE; busy <= 1'b0;
        acc_x <= 16'sd0; acc_y <= 16'sd0;
        nx0 <= 32'sd0; ny0 <= 32'sd0;
        z_in <= 1'b0; z_out <= 1'b0; ct <= 5'd0;
        c_level <= 2'd0; c_idx <= 3'd0;
        t_level <= 2'd0; t_step <= 32'd65536; t_fine <= 1'b0; t_coarse <= 1'b0;
        ax0 <= 32'sd0; ay0 <= 32'sd0;
        o_base <= 25'd0; o_w <= 16'd0; o_h <= 16'd0;
        o_step <= 32'd65536; o_x0 <= 32'sd0; o_y0 <= 32'sd0;
    end else begin
        case (ns)
            N_IDLE: if (clear) begin
                acc_x <= 16'sd0; acc_y <= 16'sd0;
            end else if (ev) begin
                busy  <= 1'b1;
                acc_x <= acc_x + ev_px;
                acc_y <= acc_y + ev_py;
                z_in  <= ev_zoom < 0;
                z_out <= ev_zoom > 0;
                nx0   <= cur_x0;
                ny0   <= cur_y0;
                ct    <= 5'd16;
                c_level <= lvl;
                c_idx   <= idx;
                ns <= N_PAN;
            end

            // whole nudges only; a remainder waits for the next report
            N_PAN: if (ct == 5'd0 ||
                       (acc_x > -NUDGE && acc_x < NUDGE &&
                        acc_y > -NUDGE && acc_y < NUDGE)) begin
                ns <= N_ZOOM;
            end else begin
                if (acc_x >= NUDGE) begin
                    nx0   <= (nx0 + nudge > max_x_old) ? max_x_old : nx0 + nudge;
                    acc_x <= acc_x - NUDGE;
                end else if (acc_x <= -NUDGE) begin
                    nx0   <= (nx0 < nudge) ? 32'sd0 : nx0 - nudge;
                    acc_x <= acc_x + NUDGE;
                end
                if (acc_y >= NUDGE) begin
                    ny0   <= (ny0 + nudge > max_y_old) ? max_y_old : ny0 + nudge;
                    acc_y <= acc_y - NUDGE;
                end else if (acc_y <= -NUDGE) begin
                    ny0   <= (ny0 < nudge) ? 32'sd0 : ny0 - nudge;
                    acc_y <= acc_y + NUDGE;
                end
                ct <= ct - 5'd1;
            end

            N_ZOOM: begin
                t_fine <= 1'b0; t_coarse <= 1'b0; t_level <= c_level;
                if (z_in && c_idx > 3'd0) begin
                    t_step <= step_of(c_idx - 3'd1);
                end else if (z_in && c_level > 2'd0 && lv_valid[c_level - 2'd1]) begin
                    t_level <= c_level - 2'd1;
                    t_step  <= step_of(3'd4);
                    t_fine  <= 1'b1;
                end else if (z_out && c_idx < 3'd4) begin
                    t_step <= step_of(c_idx + 3'd1);
                end else if (z_out && c_level < 2'd3 && lv_valid[c_level + 2'd1]) begin
                    t_level <= c_level + 2'd1;
                    t_step  <= step_of(3'd0);
                    t_coarse <= 1'b1;
                end else begin
                    t_step <= cur_step;
                end
                ns <= N_APPLY;
            end

            // keep the centre: shift by half a line times the change in step,
            // or double / halve everything when the level changes
            N_APPLY: begin
                if (t_fine) begin
                    ax0 <= nx0 <<< 1;
                    ay0 <= ny0 <<< 1;
                end else if (t_coarse) begin
                    ax0 <= nx0 >>> 1;
                    ay0 <= ny0 >>> 1;
                end else begin
                    ax0 <= nx0 + dx_centre;
                    ay0 <= ny0 + dy_centre;
                end
                ns <= N_DONE;
            end

            N_DONE: begin
                o_base <= base_of(t_level);
                o_w    <= w_of(t_level);
                o_h    <= h_of(t_level);
                o_step <= t_step;
                o_x0   <= (ax0 < 0) ? 32'sd0 : (ax0 > max_x_new) ? max_x_new : ax0;
                o_y0   <= (ay0 < 0) ? 32'sd0 : (ay0 > max_y_new) ? max_y_new : ay0;
                o_we   <= 1'b1;
                ns     <= N_IDLE;
            end

            default: ns <= N_IDLE;
        endcase
    end
end

endmodule
