// Testbench for the line store and the lead schedule in tinymaps_top.
//
// The renderer is verified on its own by tb_maps_render.  What that leaves
// untested is the glue in tinymaps_top: four store slots, a two-line lead, the
// blanking schedule, and the read pipeline.  This reproduces exactly that --
// the real maps_render, the real store arithmetic and the real rc_cy formula,
// behind a raster with a proper vertical blanking.
//
// The source memory is synthetic and the viewport never changes, so every frame
// must come out pixel-identical.  Two frames are dumped; tools/compare_store.py
// compares them.  A row that differs is the corruption seen on hardware,
// reproduced without a capture card in the way.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module tb_maps_line_store;

localparam integer OUT_W   = 1280;
localparam integer OUT_H   = 720;
localparam integer V_TOTAL = 750;                 // 30 blanking lines
localparam integer H_TOTAL = 1650;                // 74.25 MHz against 45 kHz
localparam integer PREP0   = 5;
localparam integer LVL_W   = 1280;
localparam integer LVL_H   = 1280;
localparam integer LEVEL_BASE = 25'h038200;       // word address of 0x1C10000
localparam integer MEM_WORDS  = 1 << 20;
localparam integer FRAMES  = 4;

reg clk = 1'b0, resetn = 1'b0;
always #5 clk = ~clk;

// ------------------------------------------------------------- raster ------
integer cx = 0, cy = 0;
reg [10:0] cxv;
reg [9:0]  cyv;
always @(posedge clk) begin
    if (cx == H_TOTAL - 1) begin
        cx <= 0;
        if (cy == V_TOTAL - 1) cy <= 0; else cy <= cy + 1;
    end else cx <= cx + 1;
    cxv <= cx[10:0];
    cyv <= cy[9:0];
end

wire [9:0] rc_cy = (cyv >= OUT_H) ? ((cyv < OUT_H + PREP0) ? 10'd0 : 10'd1)
                                  : cyv + 10'd2;

// ------------------------------------------------------------- renderer ----
wire [11:0] out_x;
wire [23:0] out_rgb;
wire [7:0]  out_idx;
wire        out_valid;
wire [15:0] fetch_count;

reg [7:0] pal [0:255];
reg pal_we = 1'b0; reg [7:0] pal_idx = 8'd0; reg [23:0] pal_data = 24'd0;

reg [15:0] mem [0:MEM_WORDS-1];

// ---------------------------------------------- video channel and adapter ---
// A model of sdram_ctrl's video channel: vstart gives a 256-byte line, 128
// halfword entries follow with their vindex, and vdone closes the line one
// cycle after the last of them.  The model counts a violation whenever a
// vstart arrives while it is still streaming, which is the one thing the
// adapter must never do.
wire        vstart;
wire [24:8] vaddr;
reg         vvalid = 1'b0;
reg  [6:0]  vindex = 7'd0;
reg  [15:0] vdata  = 16'd0;
reg         vdone  = 1'b0;

integer violations = 0;
integer busy = 0;
reg     pending = 1'b0;
reg [24:8] line = 17'd0;
reg [6:0]  idx  = 7'd0;

// Faithful to sdram_ctrl: vstart only marks a line pending, the line in flight
// runs to its end, and the pending line is read afterwards from vaddr as it
// stands then.  A stray vstart therefore injects a whole extra line into the
// stream instead of being ignored.
always @(posedge clk) begin
    vvalid <= 1'b0;
    vdone  <= 1'b0;
    if (vstart) begin
        if (busy || pending) violations = violations + 1;
        pending <= 1'b1;
    end
    if (busy) begin
        vvalid <= 1'b1;
        vindex <= idx;
        vdata  <= mem[{line, idx} & (MEM_WORDS-1)];
        if (idx == 7'd127) begin
            vdone <= 1'b1;
            busy  <= 0;
        end else idx <= idx + 7'd1;
    end else if (pending) begin
        pending <= 1'b0;
        busy    <= 1;
        line    <= vaddr;
        idx     <= 7'd0;
    end
end

wire        rd_start;
wire [24:0] rd_addr;
wire [15:0] rd_count;
wire [15:0] rd_data;
wire        rd_valid;

maps_video_rd u_vrd (
    .clk(clk), .resetn(resetn),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .vstart(vstart), .vaddr(vaddr),
    .vvalid(vvalid), .vindex(vindex), .vdata(vdata), .vdone(vdone)
);

maps_render #(.OUT_W(OUT_W), .OUT_H(OUT_H), .SPAN(OUT_W/2 + 4)) dut (
    .clk(clk), .resetn(resetn),
    .src_x0(32'sd52428800), .src_y0(32'sd18874368),   // 800, 288 in Q16.16
    .step_x(32'd39322), .step_y(32'd39322), .bilinear(1'b0),
    .level_base(LEVEL_BASE[24:0]), .level_w(LVL_W[15:0]), .level_h(LVL_H[15:0]),
    .rd_start(rd_start), .rd_addr(rd_addr), .rd_count(rd_count),
    .rd_data(rd_data), .rd_valid(rd_valid),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .cx(cxv), .cy(rc_cy),
    .fetch_count(fetch_count),
    .out_x(out_x), .out_rgb(out_rgb), .out_idx(out_idx), .out_valid(out_valid)
);

// ------------------------------------------------------------- store -------
reg [7:0] lbuf [0:4*OUT_W-1];
always @(posedge clk)
    if (out_valid) lbuf[{rc_cy[1:0], out_x[10:0]}] <= out_idx;

wire [11:0] rd_cx = (cxv < OUT_W - 2) ? cxv + 12'd2 : cxv;
reg  [7:0]  rd_q, rd_q2, rd_q3;
always @(posedge clk) begin
    rd_q  <= lbuf[{cyv[1:0], rd_cx[10:0]}];
    rd_q2 <= rd_q;
    rd_q3 <= rd_q2;
end

// ------------------------------------------------------------- capture -----
// One byte per screen pixel of the frame, indexed row*OUT_W + col, taken from
// the same stage the palette reads.  Both frames use identical raster timing,
// so any difference between them is the store serving different pixels for
// identical inputs.
reg [7:0] shot [0:1][0:OUT_W*OUT_H-1];
integer frame = 0;
integer k;

always @(posedge clk) begin
    // one sample per screen pixel, addressed by the raster itself
    if (resetn && frame >= 2 && frame <= 3 && cy < OUT_H && cx < OUT_W) begin
        k = cy * OUT_W + cx;
        shot[frame-2][k] = rd_q3;
    end
    if (cx == H_TOTAL - 1 && cy == V_TOTAL - 1) frame <= frame + 1;
end

integer fi;
initial begin
    for (fi = 0; fi < MEM_WORDS; fi = fi + 1)
        mem[fi] = {(fi*7) & 8'hFF, (fi*13) & 8'hFF};
    for (fi = 0; fi < 256; fi = fi + 1) pal[fi] = fi[7:0];

    resetn = 1'b0;
    repeat (4) @(posedge clk);
    resetn = 1'b1;

    repeat (FRAMES * V_TOTAL * H_TOTAL) @(posedge clk);

    for (fi = 0; fi < 2; fi = fi + 1) begin
        integer fh;
        fh = $fopen(fi == 0 ? "build/sim/store_f2.bin" : "build/sim/store_f3.bin", "wb");
        for (k = 0; k < OUT_W*OUT_H; k = k + 1)
            $fwrite(fh, "%c", shot[fi][k]);
        $fclose(fh);
    end
    // what is actually in the four slots, read out the front door
    for (fi = 0; fi < 4; fi = fi + 1) begin
        integer nz, off;
        nz = 0;
        for (off = 16; off < OUT_W - 16; off = off + 1)
            if (lbuf[fi*OUT_W + off] != 8'h00) nz = nz + 1;
        $display("slot %0d: %0d of %0d entries nonzero, first 12 = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 fi, nz, OUT_W - 32,
                 lbuf[fi*OUT_W+16], lbuf[fi*OUT_W+17], lbuf[fi*OUT_W+18],
                 lbuf[fi*OUT_W+19], lbuf[fi*OUT_W+20], lbuf[fi*OUT_W+21],
                 lbuf[fi*OUT_W+22], lbuf[fi*OUT_W+23], lbuf[fi*OUT_W+24],
                 lbuf[fi*OUT_W+25], lbuf[fi*OUT_W+26], lbuf[fi*OUT_W+27]);
    end
    $display("row fetches after %0d frames: %0d (one per line would be %0d)",
             FRAMES, fetch_count, FRAMES * (OUT_H + 4));
    begin
        integer cs, w;
        cs = 0;
        for (w = 0; w < 4*OUT_W; w = w + 1) cs = (cs * 131 + lbuf[w]) & 32'h7FFFFFFF;
        $display("store checksum: %0d", cs);
    end
    $display("vstart during a live line: %0d", violations);

    // the verdict: the adapter must never open a line while one is live, and
    // two frames of a static viewport must be identical to the pixel
    begin
        integer diffs, q;
        diffs = 0;
        for (q = 0; q < OUT_W*OUT_H; q = q + 1)
            if (shot[0][q] !== shot[1][q]) diffs = diffs + 1;
        $display("frame 2 against frame 3: %0d differing pixels", diffs);
        if (violations != 0)
            $display("RESULT: FAIL (%0d vstarts during a live line)", violations);
        else if (diffs != 0)
            $display("RESULT: FAIL (%0d pixels differ between frames)", diffs);
        else
            $display("RESULT: PASS (no vstart during a live line, frames identical)");
    end
    $finish;
end

endmodule
