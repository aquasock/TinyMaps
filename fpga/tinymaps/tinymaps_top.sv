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
// The pack loader is wired: maps_uart_rx and maps_uart_tx carry the BL616's
// link, and maps_link_rx parses its 0xAA frames and writes the payload through
// sdram_ctrl's A25 port.  The viewport registers are still constants and the
// palette is still the fabric grey ramp, so what is on screen is whatever the
// loaded image looks like through that ramp.
//
// SPDX-License-Identifier: GPL-3.0-only

`timescale 1ns / 1ps

module tinymaps_top #(
    parameter int VIDEOID = 4,                // VIC 4 = 1280x720p60
    // The BL616 link's rate: 2 Mbaud is the board's default, and a faster rate
    // needs the same value on the other end (`fpgabaud` in the shell).  The
    // oversampling follows from it -- sixteen samples a bit needs sixteen clocks
    // a bit, and this clock is 74.25 MHz.
    parameter int LINK_BAUD       = 2_000_000,
    parameter int LINK_OVERSAMPLE = 16
) (
    input         sys_clk,                    // 50 MHz crystal

    // UART to the BL616: the pack loader's transport
    input         uart_rx,
    output        uart_tx,

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
// A grey ramp fills the table at power-on so the screen is not garbage before
// anything is loaded; after that the link's palette command owns it.  Only one
// writer is ever active: the ramp finishes inside 512 clocks, long before a
// host can send a palette over a 2 Mbaud link.
reg [8:0] pal_init = 9'd0;
always @(posedge hclk) if (pal_init != 9'h1FF) pal_init <= pal_init + 9'd1;

wire        ld_pal_we;
wire [7:0]  ld_pal_idx;
wire [23:0] ld_pal_data;

wire        pal_we   = ld_pal_we | ~pal_init[8];
wire [7:0]  pal_idx  = ld_pal_we ? ld_pal_idx  : pal_init[7:0];
wire [23:0] pal_data = ld_pal_we ? ld_pal_data
                                 : {pal_init[7:0], pal_init[7:0], pal_init[7:0]};
// read and written on hclk only, for the same block RAM reason
reg [23:0] pal [0:255];
always @(posedge hclk) if (pal_we) pal[pal_idx] <= pal_data;

// ----------------------------------------------------------------- renderer --
// The viewport is set over the link by command 0x0A and holds its power-on
// values until then: a 768x768 eight-bit level at byte 0, which is what
// tools/maps_test_image.py writes and what the pack's L3 level is, at 0.6
// source pixels per output pixel so the level's 768 columns fill the line.
reg  signed [31:0] SRC_X0     = 32'sd0;
reg  signed [31:0] SRC_Y0     = 32'sd0;
reg         [31:0] STEP       = 32'd39322;      // 0.600006 source px per output px
reg         [24:0] LEVEL_BASE = 25'd0;
reg         [15:0] LEVEL_W    = 16'd768;
reg         [15:0] LEVEL_H    = 16'd768;
wire               vp_we;
wire        [3:0]  lv_valid;
wire        [24:0] lv_base0, lv_base1, lv_base2, lv_base3;
wire        [15:0] lv_w0, lv_w1, lv_w2, lv_w3;
wire        [15:0] lv_h0, lv_h1, lv_h2, lv_h3;
wire               nav_ev;
wire signed [15:0] nav_px, nav_py;
wire signed [1:0]  nav_zoom;
wire        [2:0]  nav_btn;
wire               nav_mouse;
wire        [10:0] ptr_x;
wire        [9:0]  ptr_y;
wire               ptr_hold;
wire               nav_we;
wire        [24:0] nav_base;
wire        [15:0] nav_w, nav_h;
wire        [31:0] nav_step;
wire signed [31:0] nav_x0, nav_y0;
wire        [24:0] vp_base;
wire        [15:0] vp_w, vp_h;
wire        [31:0] vp_step;
wire signed [31:0] vp_x0, vp_y0;

wire [10:0] cx;
wire [9:0]  cy;
wire [11:0] frameWidth, frameHeight;
wire [23:0] render_rgb;
wire [7:0]  render_idx;
wire [11:0] render_x;
wire        render_valid;
wire [2:0]  render_state;

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

// The renderer is asked for line 0 for the whole of the vertical blanking, not
// just the last raster line.  At the wrap it cannot reuse the rows it holds --
// the source row jumps from the bottom of the level back to zero -- so it has to
// fetch both rows before it can emit: about 700 clocks a row at SPAN 644, plus
// 1280 to emit, against the 1650 a line has.  Given one line it falls behind and
// the line store is read before it is written, which is what put the previous
// frame's last line at the top of the picture; the blanking is 30 lines and more
// than covers the one discontinuity a frame has.
// Two lines ahead into four store slots.
//
// The lead has to cover a line, not an average line: a blocking line -- the
// frame start, or the line after a pan -- fetches both rows and waits for the
// third, so it costs three row fetches plus the emit.  At the hardware's
// measured 1340 clocks a fetch that is 5300 clocks, 3.2 rasters against a
// 1650-clock raster, which is more than the two rasters of lead this store
// gives it.  A steady-state line rotates a buffer and costs one fetch plus the
// emit, 1.6 rasters, which fits.  That is the shape of the symptom: the first
// lines of a frame, corrupt on the right of each line, changing frame to frame.
//
// The first line of a frame is therefore given five blanking lines to itself
// and the second line the remaining twenty-five.
localparam int PREP0 = 5;              // blanking lines spent drawing line 0
wire [9:0] rc_cy = (cy >= OUT_H) ? ((cy < OUT_H + PREP0) ? 10'd0 : 10'd1)
                                 : cy + 10'd2;

// A viewport change costs the renderer a blocking refetch of both rows -- about
// 2680 clocks against the 1650 a line has -- so applying one mid-frame tears the
// picture: the row buffers hold a window fetched for another origin and the line
// store is read before it is written.  That is what a single mouse report did.
//
// So the writers do not touch the live viewport.  They write a shadow, and the
// shadow is swapped in at the top of the vertical blanking, where the renderer
// starts line 0 with thirty lines in hand.  Several events in one frame fold
// into one swap, and the navigation reads the shadow, so its own steps chain.
reg  [24:0] sh_base = 25'd0;
reg  [15:0] sh_w    = 16'd768;
reg  [15:0] sh_h    = 16'd768;
reg  [31:0] sh_step = 32'd39322;
reg  signed [31:0] sh_x0 = 32'sd0;
reg  signed [31:0] sh_y0 = 32'sd0;
reg         vp_pending = 1'b1;

always @(posedge hclk)
    if (vp_we) begin
        sh_base <= vp_base;
        sh_w    <= vp_w;
        sh_h    <= vp_h;
        sh_step <= vp_step;
        sh_x0   <= vp_x0;
        sh_y0   <= vp_y0;
        vp_pending <= 1'b1;
    end else if (nav_we) begin
        sh_base <= nav_base;
        sh_w    <= nav_w;
        sh_h    <= nav_h;
        sh_step <= nav_step;
        sh_x0   <= nav_x0;
        sh_y0   <= nav_y0;
        vp_pending <= 1'b1;
    end

wire at_blank = (cy == OUT_H);
reg  at_blank_d = 1'b0;
always @(posedge hclk) at_blank_d <= at_blank;

always @(posedge hclk)
    if (at_blank && !at_blank_d && vp_pending) begin
        LEVEL_BASE <= sh_base;
        LEVEL_W    <= sh_w;
        LEVEL_H    <= sh_h;
        STEP       <= sh_step;
        SRC_X0     <= sh_x0;
        SRC_Y0     <= sh_y0;
        vp_pending <= 1'b0;
    end

maps_nav #(.OUT_W(OUT_W), .OUT_H(OUT_H)) u_nav (
    .clk(hclk), .resetn(rstn_h),
    .cur_base(sh_base), .cur_w(sh_w), .cur_h(sh_h),
    .cur_step(sh_step), .cur_x0(sh_x0), .cur_y0(sh_y0),
    .lv_valid(lv_valid),
    .lv_base0(lv_base0), .lv_base1(lv_base1),
    .lv_base2(lv_base2), .lv_base3(lv_base3),
    .lv_w0(lv_w0), .lv_w1(lv_w1), .lv_w2(lv_w2), .lv_w3(lv_w3),
    .lv_h0(lv_h0), .lv_h1(lv_h1), .lv_h2(lv_h2), .lv_h3(lv_h3),
    .clear(vp_we),
    .ev(nav_ev), .ev_px(nav_px), .ev_py(nav_py), .ev_zoom(nav_zoom),
    .ev_btn(nav_btn), .ev_mouse(nav_mouse),
    .ptr_x(ptr_x), .ptr_y(ptr_y), .ptr_hold(ptr_hold),
    .o_we(nav_we), .o_base(nav_base), .o_w(nav_w), .o_h(nav_h),
    .o_step(nav_step), .o_x0(nav_x0), .o_y0(nav_y0), .busy()
);

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(OUT_W/2 + 4)) u_render (
    .clk(hclk), .resetn(rstn_h),
    .src_x0(SRC_X0), .src_y0(SRC_Y0), .step_x(STEP), .step_y(STEP),
    .bilinear(1'b1),
    .level_base(LEVEL_BASE), .level_w(LEVEL_W), .level_h(LEVEL_H),
    .rd_start(vrd_rd_start), .rd_addr(vrd_rd_addr), .rd_count(vrd_rd_count),
    .rd_data(vrd_rd_data), .rd_valid(vrd_rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(rc_cy),
    .fetch_count(),
    .dbg_state(render_state),
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

// ------------------------------------------------------------------- loader --
// The pack arrives over the BL616's UART in 0xAA frames.  maps_link_rx parses
// the frames itself and writes the payload through the SDRAM's A25 port, which
// the renderer never touches: sdram_ctrl arbitrates between that port and the
// video line and gives the video priority, so a load cannot stall a line.
wire [7:0]  urx_data;
wire        urx_valid;
wire        utx_start;
wire [7:0]  utx_data;
wire        utx_busy;
wire        ld_req;
wire [24:3] ld_addr;
wire [7:0]  ld_lanes;
wire [63:0] ld_wdata;

sdram_ctrl #(.CL(3), .INIT_CYCLES(15000), .REFRESH_CYCLES(525)) u_sdram (
    .clk(hclk), .resetn(rstn_h),
    // the loader's port
    .req(ld_req), .write(ld_req), .addr(ld_addr), .lanes(ld_lanes),
    .wdata(ld_wdata),
    .ack(sd_ack), .rdata(sd_rdata), .ready(sd_ready),
    .vstart(v_vstart), .vaddr(v_vaddr),
    .vvalid(v_vvalid), .vindex(v_vindex), .vdata(v_vdata), .vdone(v_vdone),
    .sdram_clk(sdram_clk),
    .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a),
    .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq)
);

// The PHY stays on the pixel clock.  It was moved to the 371.25 MHz clock, which
// the TMDS serialiser already needs, to reach 12 Mbaud -- sixteen samples a bit
// needs sixteen clocks a bit, and 74.25 MHz therefore caps the link at 4.64
// Mbaud.  That domain could not host it: the baud accumulator, its compare and
// the receiver state machine close at 189 MHz against the 371 the serializer
// demands, and a feedback loop cannot be pipelined to fix it.  So the link runs
// here at 5 Mbaud with eight samples a bit, which is 14.85 clocks a bit and fits
// with the mid-bit sample intact, and 12 Mbaud waits for a ~200 MHz clock.
maps_uart_rx #(.CLK_HZ(74_250_000), .BAUD(LINK_BAUD), .OVERSAMPLE(LINK_OVERSAMPLE))
    u_uart_rx (.clk(hclk), .resetn(rstn_h), .rx(uart_rx),
               .data(urx_data), .valid(urx_valid));

maps_uart_tx #(.CLK_HZ(74_250_000), .BAUD(LINK_BAUD), .OVERSAMPLE(LINK_OVERSAMPLE))
    u_uart_tx (.clk(hclk), .resetn(rstn_h), .start(utx_start), .data(utx_data),
               .tx(uart_tx), .busy(utx_busy));

maps_link_rx u_loader (
    .clk(hclk), .resetn(rstn_h),
    .rx_data(urx_data), .rx_valid(urx_valid),
    .tx_start(utx_start), .tx_data(utx_data), .tx_busy(utx_busy),
    .wr_req(ld_req), .wr_addr(ld_addr), .wr_lanes(ld_lanes),
    .wr_wdata(ld_wdata), .wr_ack(sd_ack),
    .pal_we(ld_pal_we), .pal_idx(ld_pal_idx), .pal_data(ld_pal_data),
    // The tile pool has no home yet: the pack occupies 27.62 MiB of the dock's
    // 32 and the pool's base is inside it, so command 0x1D stays off here
    // (TILES defaults to 0) and this address is never used.  It is tied rather
    // than left open because an open input on a path that writes memory is not
    // something to leave to a synthesis warning.
    .fill_addr(25'd0),
    .vp_we(vp_we), .vp_base(vp_base), .vp_w(vp_w), .vp_h(vp_h),
    .vp_step(vp_step), .vp_x0(vp_x0), .vp_y0(vp_y0),
    .st_base(LEVEL_BASE), .st_w(LEVEL_W), .st_h(LEVEL_H), .st_step(STEP),
    .st_x0(SRC_X0), .st_y0(SRC_Y0), .st_rstate(render_state),
    .lv_valid(lv_valid),
    .lv_base0(lv_base0), .lv_base1(lv_base1),
    .lv_base2(lv_base2), .lv_base3(lv_base3),
    .lv_w0(lv_w0), .lv_w1(lv_w1), .lv_w2(lv_w2), .lv_w3(lv_w3),
    .lv_h0(lv_h0), .lv_h1(lv_h1), .lv_h2(lv_h2), .lv_h3(lv_h3),
    .nav_ev(nav_ev), .nav_px(nav_px), .nav_py(nav_py), .nav_zoom(nav_zoom),
    .nav_btn(nav_btn), .nav_mouse(nav_mouse),
    .busy(), .images(), .bytes_written(), .last_nak(),
    .overflows(), .timeouts()
);

// ------------------------------------------------------------- line store ---
// Written on fclk by the renderer, read on hclk by the pixel path.  This is
// deliberately flip-flops and not block RAM: Apicula's block RAM reads back
// wrong on the GW5AST-138 when it is written on one clock and read on another.
// Four lines, so the reader is looking at a slot the writer is not: the writer
// runs two lines ahead and each line is a whole slot.
reg [7:0] lbuf [0:4*OUT_W-1];
always @(posedge hclk)
    if (render_valid) lbuf[{rc_cy[1:0], render_x[10:0]}] <= render_idx;

// Synchronous read, so this is block RAM and not a multiplexer tree: an
// asynchronous read of the whole array became distributed RAM and cost more
// than the store itself.  Two stages run before the pixel is needed, so the
// address leads the raster by two.
wire [11:0] rd_cx = (cx < OUT_W - 2) ? cx + 12'd2 : cx;
reg  [7:0]  rd_q, rd_q2, rd_q3;
always @(posedge hclk) begin
    rd_q  <= lbuf[{cy[1:0], rd_cx[10:0]}];
    rd_q2 <= rd_q;
    rd_q3 <= rd_q2;
end
// ------------------------------------------------------------- the cursor ---
// A thirty-two-pixel marker centred on the cursor, drawn over the picture rather
// than through the palette so the pack's colours are untouched.  Green frame
// while nothing is held and a red crosshair while a button is, which is
// TinyCreature's own scheme -- the colours change the moment a button moves,
// whether or not the mouse does.  It is centred on the pixel it is drawn at, so
// the land a press takes is the land under the middle of the marker.
//
// The marker is combined combinationally with the raster counters, which is
// right even though the picture it is drawn over comes out of a registered
// read: the HDMI stage takes the colour and the counters on the same clock, so a
// marker placed by cx and cy lands on the pixel those counters are drawing.  The
// map's own few pixels of read latency shift the whole picture uniformly, not
// the marker against it.
wire [11:0] spx = {1'b0, cx} - {1'b0, ptr_x};
wire [11:0] spy = {1'b0, cy} - {1'b0, ptr_y};
wire        sp_in   = (spx[11:5] == 7'd0) && (spy[11:5] == 7'd0);
wire        sp_edge = (spx[4:0] < 5'd4) || (spx[4:0] > 5'd27) ||
                      (spy[4:0] < 5'd4) || (spy[4:0] > 5'd27);
wire        sp_mid  = (spx[4:0] >= 5'd14 && spx[4:0] <= 5'd17) ||
                      (spy[4:0] >= 5'd14 && spy[4:0] <= 5'd17);
wire        sp_hit  = sp_in && (ptr_hold ? sp_mid : sp_edge);
wire [23:0] rgb_vis = sp_hit ? (ptr_hold ? 24'hFF0000 : 24'h00FF00)
                             : ((cy < OUT_H) ? pal[rd_q3] : 24'h000000);


// -------------------------------------------------------------------- HDMI ---
logic [2:0] tmds;
wire        tmdsClk;

maps_hdmi #(.VIDEOID(VIDEOID)) u_hdmi (
    .clk_pixel(hclk),
    .clk_5x_pixel(hclk5),
    .clk_audio(clk_audio),
    .rgb(rgb_vis),
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
