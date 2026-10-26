// TinyMaps top level, Tang Console 138K, GW5AST-LV138PG484AC1/I0 revision C.
//
// Phase 0: clocks, 720p HDMI out, and a test pattern drawn from the HDMI
// pixel counters.  No map data, no SDRAM, no BL616 link yet -- this exists to
// prove the open flow builds this board's design and that the pixel
// coordinates the renderer will be addressed with are the ones presented.
//
// Clocks follow TinyTang's desktop core, the open-flow build of record on this
// board: 50 MHz crystal -> pll_27 -> 27 MHz -> pll_hdmi -> 371.25 MHz, divided
// by 5 to the 74.25 MHz pixel clock.  pll_nes gives the 21.492 MHz logic clock
// and, later, fclk at 3x for the SDRAM controller.
//
// HDMI output stage derived from nes2hdmi.sv in nestang by nand2mario.
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
    output [2:0]  tmds_d_p
);

wire clk27;     // 27 MHz, HDMI PLL reference
wire hclk;      // 74.25 MHz pixel clock
wire hclk5;     // 371.25 MHz, 5x pixel clock
wire clk;       // 21.492 MHz logic clock
wire fclk;      // 3x clk, reserved for the SDRAM controller

reg sys_resetn = 0;
reg [7:0] reset_cnt = 255;
always @(posedge clk) begin
    reset_cnt <= reset_cnt == 0 ? 0 : reset_cnt - 1;
    if (reset_cnt == 0) sys_resetn <= 1'b1;
end

gowin_pll_27  pll_27  (.clkin(sys_clk), .clkout0(clk27));
gowin_pll_nes pll_nes (.clkin(sys_clk), .clkout0(clk), .clkout1(fclk), .clkout2());

gowin_pll_hdmi pll_hdmi (
    .clkin(clk27),
    .clkout(hclk5)
);

CLKDIV #(.DIV_MODE(5)) div5 (
    .CLKOUT(hclk),
    .HCLKIN(hclk5),
    .RESETN(sys_resetn),
    .CALIB(1'b0)
);

// ------------------------------------------------------------------ audio --
// hdmi.sv always emits the audio packets, so it needs a clock and silence.
logic clk_audio;
logic [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = 16'd0;
assign audio_sample_word[1] = 16'd0;

localparam int AUDIO_CLK_DELAY = 23;          // as TinyTang's desktop core

logic [4:0] audio_divider = 0;
always_ff @(posedge hclk) begin
    if (audio_divider != AUDIO_CLK_DELAY - 1)
        audio_divider <= audio_divider + 1;
    else begin
        clk_audio     <= ~clk_audio;
        audio_divider <= 0;
    end
end

// ------------------------------------------------------------- test pattern --
// Read straight off the HDMI counters, which name the pixel presented in this
// clock.  Ten 128-px colour bars over a vertical ramp, with a 1-px white grid
// every 64 px so a mis-registered or off-by-N pixel path is obvious on screen
// rather than plausible.
logic [10:0] cx;
logic [9:0]  cy;
logic [11:0] frameWidth;
logic [11:0] frameHeight;
logic [23:0] rgb;

// Ten 128-px bars off the bar counter alone: no per-pixel arithmetic in this
// cycle.  An earlier version built a 24-bit colour from cy[7:0] in each of six
// case arms with a grid comparison on top, and that combination out of the
// pixel counters into rgb's register was the only thing in the design that
// missed 74.25 MHz -- it took hclk to 68 MHz on every seed.  With a constant
// colour the same netlist reached 134 MHz.  The renderer will face the same
// hazard: its output has to arrive registered, one shallow stage off cx/cy.
wire [2:0] bar = cx[9:7];                     // 128-px bars

always @(posedge hclk) begin
    if (cx >= 1280 || cy >= 720)
        rgb <= 24'h000000;
    else case (bar)
        3'd0: rgb <= 24'h800000;
        3'd1: rgb <= 24'h008000;
        3'd2: rgb <= 24'h000080;
        3'd3: rgb <= 24'h808000;
        3'd4: rgb <= 24'h008080;
        3'd5: rgb <= 24'h800080;
        3'd6: rgb <= 24'hc0c0c0;
        default: rgb <= 24'h404040;
    endcase
end

// -------------------------------------------------------------------- HDMI --
logic [2:0] tmds;
wire        tmdsClk;

hdmi #( .VIDEO_ID_CODE(VIDEOID),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(60.0),
        .IT_CONTENT(1),
        .AUDIO_RATE(44100),
        .AUDIO_BIT_WIDTH(16),
        .START_X(0),
        .START_Y(0) )
u_hdmi (
    .clk_pixel_x5(hclk5),
    .clk_pixel(hclk),
    .clk_audio(clk_audio),
    .rgb(rgb),
    .reset(1'b0),
    .audio_sample_word(audio_sample_word),
    .tmds(tmds),
    .tmds_clock(tmdsClk),
    .cx(cx),
    .cy(cy),
    .frame_width(frameWidth),
    .frame_height(frameHeight)
);


// Gowin LVDS output buffers
ELVDS_OBUF tmds_bufds [3:0] (
    .I({tmdsClk, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

endmodule
