// TinyMaps top level, Tang Console 138K, GW5AST-LV138PG484AC1/I0 revision C.
//
// Clocks follow TinyTang's desktop core: 50 MHz crystal -> pll_27 -> 27 MHz ->
// pll_hdmi -> 371.25 MHz, divided by 5 to the 74.25 MHz pixel clock.  The SDRAM
// controller and the renderer both run on that pixel clock, so nothing crosses a
// clock boundary and no block RAM is written on one clock and read on another --
// the combination Apicula reads back wrong on this part.
//
// sdram_ctrl's own defaults (INIT_CYCLES 15000, REFRESH_CYCLES 525) are tuned
// for about 75 MHz, which is this clock: 200 us of initialisation and a 7 us
// refresh interval.
//
// One line is drawn ahead of the raster: the renderer is given cy+1, so the line
// shown at raster line N was completed at N-1 and the pixel path only ever reads
// a finished line.  The two line buffers alternate by line parity for the same
// reason.
//
// Not wired yet: the pack loader.  sdram_ctrl's A25 write port is idle and the
// viewport registers are constants, so the SDRAM holds nothing and the picture
// is the default palette over empty memory.  maps_link_rx is finished and
// verified; it needs a UART receiver and the 0xAA frame parser in front of it.
//
// SPDX-License-Identifier: GPL-3.0-only

`timescale 1ns / 1ps

module tinymaps_top #(
    parameter int VIDEOID = 4                 // VIC 4 = 1280x720p60
) (
    input         sys_clk,                    // 50 MHz crystal

    // HDMI TX
    output        tmds_clk_n,
    output        tmds_clk_p,
    output [2:0]  tmds_d_n,
    output [2:0]  tmds_d_p,

    // SDRAM, the dock's J9 module
    output        sdram_clk,
    output        sdram_cs_n,
    output        sdram_ras_n,
    output        sdram_cas_n,
    output        sdram_we_n,
    output [1:0]  sdram_ba,
    output [12:0] sdram_a,
    output [1:0]  sdram_dqm,
    inout  [15:0] sdram_dq
);

localparam int OUT_W = 1280;
localparam int OUT_H = 720;

wire clk27, hclk, hclk5, clk, fclk;

reg sys_resetn = 0;
reg [7:0] reset_cnt = 255;
always @(posedge clk) begin
    reset_cnt <= reset_cnt == 0 ? 0 : reset_cnt - 1;
    if (reset_cnt == 0) sys_resetn <= 1'b1;
end

gowin_pll_27  pll_27  (.clkin(sys_clk), .clkout0(clk27));
gowin_pll_nes pll_nes (.clkin(sys_clk), .clkout0(clk), .clkout1(fclk), .clkout2());
gowin_pll_hdmi pll_hdmi (.clkin(clk27), .clkout(hclk5));
CLKDIV #(.DIV_MODE(5)) div5 (
    .CLKOUT(hclk), .HCLKIN(hclk5), .RESETN(sys_resetn), .CALIB(1'b0)
);

// Per-domain resets.  sys_resetn deasserts in the `clk` domain; each domain
// takes it through two flops so nothing sees a metastable release.
reg [1:0] rst_f = 2'b00, rst_h = 2'b00;
always @(posedge fclk) rst_f <= {rst_f[0], sys_resetn};
always @(posedge hclk) rst_h <= {rst_h[0], sys_resetn};
wire rstn_f = rst_f[1];
wire rstn_h = rst_h[1];

// ------------------------------------------------------------------ audio ---
logic clk_audio;
logic [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = 16'd0;
assign audio_sample_word[1] = 16'd0;
localparam int AUDIO_CLK_DELAY = 23;
logic [4:0] audio_divider = 0;
always_ff @(posedge hclk) begin
    if (audio_divider != AUDIO_CLK_DELAY - 1)
        audio_divider <= audio_divider + 1;
    else begin
        clk_audio     <= ~clk_audio;
        audio_divider <= 0;
    end
end

// ---------------------------------------------------------------- palette ---
// A grey ramp until the loader can supply the pack's palette.
reg [8:0] pal_init = 9'd0;
wire      pal_we    = ~pal_init[8];
wire [7:0] pal_idx  = pal_init[7:0];
wire [23:0] pal_data = {pal_init[7:0], pal_init[7:0], pal_init[7:0]};
always @(posedge hclk) if (pal_init != 9'h1FF) pal_init <= pal_init + 9'd1;
// read and written on hclk only, for the same block RAM reason
reg [23:0] pal [0:255];
always @(posedge hclk) if (pal_we) pal[pal_idx] <= pal_data;

// ----------------------------------------------------------------- renderer --
// Viewport registers are constants for now; the loader will own them.
localparam signed [31:0] SRC_X0 = 32'd0;
localparam signed [31:0] SRC_Y0 = 32'd0;
localparam        [31:0] STEP   = 32'h0000_C000;     // 0.75 source px per output px
localparam        [24:0] LEVEL_BASE = 25'd0;
localparam        [15:0] LEVEL_W = 16'd4608;
localparam        [15:0] LEVEL_H = 16'd4608;

wire [10:0] cx;
wire [9:0]  cy;
wire [11:0] frameWidth, frameHeight;
wire [23:0] render_rgb;
wire [7:0]  render_idx;
wire [11:0] render_x;
wire        render_valid;
wire [15:0] fetch_count;

wire        vrd_rd_start;
wire [24:0] vrd_rd_addr;
wire [15:0] vrd_rd_count;
wire [15:0] vrd_rd_data;
wire        vrd_rd_valid;

// One line ahead of the raster.  The line boundary crosses into fclk as a
// toggle, not as the ten-bit counter: a multi-bit value changing under another
// clock is a bus skew problem, one toggle is not.
reg [9:0]  cy_q;
reg        line_tog_h;
always @(posedge hclk) begin
    cy_q <= cy;
    if (cy != cy_q) line_tog_h <= ~line_tog_h;
end
reg [2:0] tog_f;
always @(posedge fclk) tog_f <= {tog_f[1:0], line_tog_h};
wire line_tick = tog_f[2] ^ tog_f[1];

wire [9:0] rc_cy = (cy == 10'd749) ? 10'd0 : cy + 10'd1;

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(OUT_W/2 + 4)) u_render (
    .clk(hclk), .resetn(rstn_h),
    .src_x0(SRC_X0), .src_y0(SRC_Y0), .step_x(STEP), .step_y(STEP),
    .bilinear(1'b1),
    .level_base(LEVEL_BASE), .level_w(LEVEL_W), .level_h(LEVEL_H),
    .rd_start(vrd_rd_start), .rd_addr(vrd_rd_addr), .rd_count(vrd_rd_count),
    .rd_data(vrd_rd_data), .rd_valid(vrd_rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(rc_cy),
    .fetch_count(fetch_count),
    .out_x(render_x), .out_rgb(render_rgb), .out_idx(render_idx),
    .out_valid(render_valid)
);

maps_video_rd u_vrd (
    .clk(hclk), .resetn(rstn_h),
    .rd_start(vrd_rd_start), .rd_addr(vrd_rd_addr), .rd_count(vrd_rd_count),
    .rd_data(vrd_rd_data), .rd_valid(vrd_rd_valid),
    .vstart(v_vstart), .vaddr(v_vaddr),
    .vvalid(v_vvalid), .vindex(v_vindex), .vdata(v_vdata), .vdone(v_vdone)
);

wire        v_vstart;
wire [24:8] v_vaddr;
wire        v_vvalid;
wire [6:0]  v_vindex;
wire [15:0] v_vdata;
wire        v_vdone;

// -------------------------------------------------------------------- SDRAM --
wire        sd_ack, sd_ready;
wire [63:0] sd_rdata;

sdram_ctrl #(.CL(3), .INIT_CYCLES(15000), .REFRESH_CYCLES(525)) u_sdram (
    .clk(hclk), .resetn(rstn_h),
    // the loader's port: idle until it is wired
    .req(1'b0), .write(1'b0), .addr(21'd0), .lanes(8'd0), .wdata(64'd0),
    .ack(sd_ack), .rdata(sd_rdata), .ready(sd_ready),
    .vstart(v_vstart), .vaddr(v_vaddr),
    .vvalid(v_vvalid), .vindex(v_vindex), .vdata(v_vdata), .vdone(v_vdone),
    .sdram_clk(sdram_clk),
    .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq)
);

// ------------------------------------------------------------- line store ---
// Written on fclk by the renderer, read on hclk by the pixel path.  This is
// deliberately flip-flops and not block RAM: Apicula's block RAM reads back
// wrong on the GW5AST-138 when it is written on one clock and read on another.
// The reader only ever looks at the buffer written during the previous line,
// which is why the parity split is there.
reg [7:0] lbuf [0:2*OUT_W-1];
always @(posedge hclk)
    if (render_valid) lbuf[{rc_cy[0], render_x[10:0]}] <= render_idx;

// Synchronous read, so this is block RAM and not a multiplexer tree: an
// asynchronous read of the whole array became distributed RAM and cost more
// than the store itself.  Two stages run before the pixel is needed, so the
// address leads the raster by two.
wire [11:0] rd_cx = (cx < OUT_W - 2) ? cx + 12'd2 : cx;
reg  [7:0]  rd_q, rd_q2, rd_q3;
always @(posedge hclk) begin
    rd_q  <= lbuf[{cy[0], rd_cx[10:0]}];
    rd_q2 <= rd_q;
    rd_q3 <= rd_q2;
end
reg  [23:0] rgb;
always @(posedge hclk)
    rgb <= (cy < OUT_H) ? pal[rd_q3] : 24'h000000;

// -------------------------------------------------------------------- HDMI ---
logic [2:0] tmds;
wire        tmdsClk;

maps_hdmi #(.VIDEOID(VIDEOID)) u_hdmi (
    .clk_pixel(hclk),
    .clk_5x_pixel(hclk5),
    .clk_audio(clk_audio),
    .rgb(rgb),
    .tmds(tmds),
    .tmds_clock(tmdsClk),
    .cx(cx),
    .cy(cy),
    .frame_width(frameWidth),
    .frame_height(frameHeight)
);

ELVDS_OBUF tmds_bufds [3:0] (
    .I({tmdsClk, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

endmodule
