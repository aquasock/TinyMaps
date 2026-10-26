// TinyMaps HDMI stage: a thin wrapper around hdmi.sv, matching how TinyTang's
// desktop core instantiates it.  The nesting is not cosmetic -- synthesis
// optimises per module, and the encoder maps measurably faster with this
// boundary around it than when hdmi is instantiated directly in the top.
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_hdmi #(
    parameter int VIDEOID = 4
) (
    input  wire        clk_pixel,
    input  wire        clk_5x_pixel,
    input  wire        clk_audio,
    input  wire [23:0] rgb,
    output wire [2:0]  tmds,
    output wire        tmds_clock,
    output wire [10:0] cx,
    output wire [9:0]  cy,
    output wire [11:0] frame_width,
    output wire [11:0] frame_height
);

logic [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = 16'd0;
assign audio_sample_word[1] = 16'd0;

hdmi #( .VIDEO_ID_CODE(VIDEOID), .DVI_OUTPUT(0), .VIDEO_REFRESH_RATE(60.0),
        .IT_CONTENT(1), .AUDIO_RATE(44100), .AUDIO_BIT_WIDTH(16),
        // Full-range RGB: the palette and the image data are 0-255, and with
        // the default (limited range) the sink lifted every level and clipped
        // everything above about 235 to white.  Measured on the Tang
        // 2026-10-26: index 236 arrived as 255, index 107 as 111.
        .RGB_QUANTIZATION_RANGE(2'b01),
        .START_X(0), .START_Y(0) )
u_hdmi (
    .clk_pixel_x5(clk_5x_pixel),
    .clk_pixel(clk_pixel),
    .clk_audio(clk_audio),
    .rgb(rgb),
    .reset(1'b0),
    .audio_sample_word(audio_sample_word),
    .tmds(tmds),
    .tmds_clock(tmds_clock),
    .cx(cx),
    .cy(cy),
    .frame_width(frame_width),
    .frame_height(frame_height)
);

endmodule
