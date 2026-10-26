// Testbench for maps_render.
//
// Builds a synthetic level in a 4 MiB model of the source memory, streams row
// reads the way the real port does, runs a shortened raster, and dumps every
// emitted pixel of every case.  tools/check_render.py recomputes the cases
// independently and compares; the testbench makes no quality judgement.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_render;

localparam integer OUT_W = 64;
localparam integer OUT_H = 48;
localparam integer LVL_W = 256;
localparam integer LVL_H = 192;
localparam integer LEVEL_BASE = 25'h100000;
localparam integer MEM_BYTES = 4*1024*1024;
localparam integer LINE_CLOCKS = 900;      // comfortably over fetch + emit
localparam integer CASES = 5;

reg clk = 0, resetn = 0;
always #5 clk = ~clk;

reg  signed [31:0] src_x0, src_y0;
reg  [31:0] step_x, step_y;
reg         bilinear;
reg  [24:0] level_base;
reg  [15:0] level_w, level_h;
reg  [10:0] cx, cy;

wire        rd_start;
wire [24:0] rd_addr;
wire [15:0] rd_count;
reg  [15:0] rd_data;
reg         rd_valid;
wire [11:0] out_x;
wire [23:0] out_rgb;
wire        out_valid;
wire [15:0] fetch_count;

reg  pal_we; reg [7:0] pal_idx; reg [23:0] pal_data;

reg [7:0] mem [0:MEM_BYTES-1];

// streaming source model: one entry per cycle after a one-cycle latency
reg        streaming = 0;
reg [24:0] s_addr;
reg [15:0] s_left;
integer    lat;
always @(posedge clk) begin
    rd_valid <= 0;
    if (rd_start) begin
        streaming <= 1;
        s_addr    <= rd_addr;
        s_left    <= rd_count;
        lat       <= 2;
    end else if (streaming && lat > 0) begin
        lat <= lat - 1;
    end else if (streaming) begin
        rd_data   <= {mem[s_addr[23:0] + 1], mem[s_addr[23:0]]};
        rd_valid  <= 1;
        s_addr    <= s_addr + 2;
        s_left    <= s_left - 1;
        if (s_left == 1) streaming <= 0;
    end
end

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H)) dut (
    .clk(clk), .resetn(resetn),
    .src_x0(src_x0), .src_y0(src_y0), .step_x(step_x), .step_y(step_y),
    .bilinear(bilinear),
    .level_base(level_base), .level_w(level_w), .level_h(level_h),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cx), .cy(cy),
    .out_x(out_x), .out_rgb(out_rgb), .out_valid(out_valid),
    .fetch_count(fetch_count)
);

integer fout, fcase;
integer fx, fy, n, c;
integer pix_count;

task run_line(input integer y);
    integer t;
    begin
        cy = y[9:0];
        for (t = 0; t < LINE_CLOCKS; t = t + 1) begin
            cx = t[10:0];
            @(posedge clk);
            if (out_valid) begin
                $fwrite(fout, "%c%c%c", out_rgb[23:16], out_rgb[15:8], out_rgb[7:0]);
                pix_count = pix_count + 1;
            end
        end
    end
endtask

task set_case(input integer idx, input [31:0] sx, input [31:0] sy,
              input [31:0] stx, input [31:0] sty, input bil);
    begin
        $fwrite(fcase, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                idx, sx, sy, stx, sty, bil, LEVEL_BASE, LVL_W, LVL_H, OUT_W);
        src_x0 = sx; src_y0 = sy; step_x = stx; step_y = sty; bilinear = bil;
    end
endtask

initial begin
    fout  = $fopen("build/sim/render_out.bin", "wb");
    fcase = $fopen("build/sim/render_cases.txt", "w");
    if (fout == 0 || fcase == 0) begin $display("cannot open output files"); $finish; end

    for (n = 0; n < MEM_BYTES; n = n + 1) mem[n] = 8'h00;
    for (fy = 0; fy < LVL_H; fy = fy + 1)
        for (fx = 0; fx < LVL_W; fx = fx + 1)
            mem[LEVEL_BASE + fy*LVL_W + fx] = (fy*3 + fx*5) & 8'hFF;

    level_base = LEVEL_BASE; level_w = LVL_W; level_h = LVL_H;

    resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    pal_we = 0; pal_idx = 0; pal_data = 0;
    for (n = 0; n < 256; n = n + 1) begin
        pal_we = 1; pal_idx = n[7:0];
        pal_data = {n[7:0], n[7:0] ^ 8'h55, n[7:0] ^ 8'hAA};
        @(posedge clk);
        pal_we = 0;
        @(posedge clk);
    end

    pix_count = 0;
    for (c = 0; c < CASES; c = c + 1) begin
        resetn = 0;
        cy = 10'h3FF; cx = 0;
        case (c)
            0: set_case(0, 32'd655360,  32'd327680,  32'h00010000, 32'h00010000, 0); // 10.0,5.0  1.000 nearest
            1: set_case(1, 32'd245760,  32'd163840,  32'h0001FD71, 32'h0001FD71, 0); //  3.75,2.5 1.990 nearest
            2: set_case(2, 32'd1343488, 32'd540672,  32'h00018000, 32'h00018000, 1); // 20.5,8.25 1.500 bilinear
            3: set_case(3, 32'd163840,  32'd98304,   32'h0001C000, 32'h0001C000, 1); //  2.5,1.5  1.750 bilinear
            4: set_case(4, 32'd589824,  32'd327680,  32'h0000C000, 32'h0000C000, 1); //  9.0,5.0  0.750 bilinear (magnifying)
        endcase
        repeat (8) @(posedge clk);
        resetn = 1;
        repeat (8) @(posedge clk);
        for (fy = 0; fy < OUT_H + 2; fy = fy + 1) run_line(fy);
        // two rows at the discontinuity, then ideally one per line in steady
        // state; anything near 2*OUT_H means the prefetch never landed in time
        $display("case %0d: %0d row fetches for %0d lines (steady state would be %0d)",
                 c, fetch_count, OUT_H, OUT_H + 1);
    end

    $fclose(fout); $fclose(fcase);
    $display("cases %0d, pixels emitted %0d, expected %0d", CASES, pix_count, CASES*OUT_W*OUT_H);
    if (pix_count != CASES*OUT_W*OUT_H) $display("RESULT: FAIL (pixel count)");
    else $display("RESULT: PASS (pixel count)");
    $finish;
end

endmodule
