// Testbench for tmds_channel.
//
// Drives one instance per channel (CN = 0, 1, 2) through every coding mode with
// a deterministic input sequence and dumps the resulting 10-bit TMDS words, one
// line per pixel clock, for each channel.  tools/check_tmds.py recomputes the
// encoding from HDMI 1.4a independently and compares it against the dump, and
// can additionally compare the dump against one captured from an earlier
// revision so a pipelining change can be shown not to alter the stream.  The
// testbench makes no coding judgement of its own.
//
// Row format: cycle mode video_data island_data control ch0 ch1 ch2
// Inputs are applied before the clock edge and the outputs are sampled just
// after it, so a row holds the inputs that were live at that edge together with
// the register state that edge produced.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`include "fpga/tinymaps/hdmi/tmds_channel.sv"

module tb_hdmi_encode;

reg clk = 0;
always #5 clk = ~clk;

reg  [7:0] video_data = 0;
reg  [3:0] ds_data    = 0;
reg  [1:0] ctrl       = 0;
reg  [2:0] mode       = 0;

wire [9:0] tmds0, tmds1, tmds2;

tmds_channel #(.CN(0)) u_ch0 (
    .clk_pixel(clk), .video_data(video_data), .data_island_data(ds_data),
    .control_data(ctrl), .mode(mode), .tmds(tmds0));

tmds_channel #(.CN(1)) u_ch1 (
    .clk_pixel(clk), .video_data(video_data), .data_island_data(ds_data),
    .control_data(ctrl), .mode(mode), .tmds(tmds1));

tmds_channel #(.CN(2)) u_ch2 (
    .clk_pixel(clk), .video_data(video_data), .data_island_data(ds_data),
    .control_data(ctrl), .mode(mode), .tmds(tmds2));

integer fd;
integer cyc = 0;
integer rep, d, c, i;
reg [15:0] lfsr = 16'hACE1;

task automatic step(input [7:0] vd, input [3:0] di, input [1:0] cd, input [2:0] md);
begin
    video_data = vd;
    ds_data    = di;
    ctrl       = cd;
    mode       = md;
    @(posedge clk);
    #1;
    $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d\n",
            cyc, mode, video_data, ds_data, ctrl, tmds0, tmds1, tmds2);
    cyc = cyc + 1;
end
endtask

initial begin
    fd = $fopen("build/sim/tmds_dump.txt", "w");
    if (fd == 0) begin
        $display("cannot open build/sim/tmds_dump.txt");
        $display("RESULT: FAIL (dump)");
        $finish;
    end

    // a few control periods first, so the encoder starts from its quiescent
    // state rather than from the first edge
    repeat (4) step(8'h00, 4'h0, 2'b00, 3'd0);

    // video: every input byte, four passes, so the disparity accumulator
    // traverses and revisits every state it can reach
    for (rep = 0; rep < 4; rep = rep + 1)
        for (d = 0; d < 256; d = d + 1)
            step(d[7:0], 4'h0, 2'b00, 3'd1);

    // control period: all four control words
    for (c = 0; c < 4; c = c + 1)
        repeat (4) step(8'h00, 4'h0, c[1:0], 3'd0);

    // data island: all sixteen TERC4 symbols
    for (d = 0; d < 16; d = d + 1)
        repeat (4) step(8'h00, d[3:0], 2'b00, 3'd3);

    // data island guard band: the codes are control dependent on channel 0
    for (c = 0; c < 4; c = c + 1)
        repeat (4) step(8'h00, 4'h0, c[1:0], 3'd4);

    // video guard band
    repeat (8) step(8'h00, 4'h0, 2'b00, 3'd2);

    // interleaved: random mode, pixel, island and control words, which is what
    // exercises the accumulator reset at every mode boundary
    for (i = 0; i < 2000; i = i + 1) begin
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        step(lfsr[7:0], lfsr[11:8], lfsr[13:12], lfsr[2:0] % 5);
    end

    $fclose(fd);
    $display("dumped %0d cycles", cyc);
    $display("RESULT: PASS (dump written)");
    $finish;
end

endmodule
