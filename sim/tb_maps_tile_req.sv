// Testbench for the tile request queue.
//
// The module under test takes misses and turns them into frames on the shared
// transmitter.  Three things have to be true and none of them is visible from
// the module's own ports: the frame is the one the host's parser expects, a
// request is sent once and not once per chunk that misses it, and a byte is
// never dropped when the arbiter gives the line to the loader instead.
//
// So this bench models the two things the module talks to.  The transmitter
// captures the byte it is handed and is busy for a few cycles afterwards, so a
// byte offered while it is busy is not taken.  The arbiter grants the line to
// this module unless a higher-priority user -- the loader -- wants it, except
// that a frame already in progress keeps the line.  Every captured byte is
// decoded back into a frame and compared with what was asked for.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_tile_req;

localparam int DEPTH = 8;
localparam [7:0] CMD = 8'h1C;
localparam int GAP   = 4;              // busy cycles after a byte is taken

reg clk = 1'b0;
always #6.734 clk = ~clk;
reg resetn = 1'b0;

reg        miss = 1'b0;
reg [1:0]  miss_level = 2'd0;
reg [14:0] miss_tx = 15'd0, miss_ty = 15'd0;

wire       tx_start;
wire [7:0] tx_data;
wire       req_hold;
wire [7:0] count;
wire       overflow;

// a higher-priority user of the line, and a way to refuse the grant outright
reg  loader_wants = 1'b0;
reg  grant_open   = 1'b1;
wire grant_now = req_hold ? 1'b1 : (grant_open && !loader_wants);

integer gap = 0;
wire tx_ready = (gap == 0);
wire tx_ack   = tx_start && grant_now && tx_ready;

maps_tile_req #(.DEPTH(DEPTH), .CMD(CMD)) dut (
    .clk(clk), .resetn(resetn),
    .miss(miss), .miss_level(miss_level), .miss_tx(miss_tx), .miss_ty(miss_ty),
    .tx_grant(grant_now), .tx_ready(tx_ready), .tx_ack(tx_ack),
    .tx_start(tx_start), .tx_data(tx_data), .req_hold(req_hold),
    .count(count), .overflow(overflow));

// ---------------------------------------------------------- the transmitter --
integer cap [0:255];
integer nb = 0;
always @(posedge clk) begin
    if (!resetn) begin
        gap <= 0;
    end else if (tx_ack) begin
        if (nb < 256) cap[nb] = tx_data;
        nb <= nb + 1;
        gap <= GAP;
    end else if (gap > 0) begin
        gap <= gap - 1;
    end
end

integer errors = 0;
task automatic want(input condition_ok, input [255:0] what);
begin
    if (!condition_ok) begin
        $display("  %0s: failed", what);
        errors = errors + 1;
    end
end
endtask

// a frame is AA 00 06 CMD level txl txh tyl tyh, little-endian
task automatic want_frame(input integer at, input [1:0] lvl,
                          input [14:0] tx, input [14:0] ty, input [255:0] what);
begin
    if (at + 8 >= nb) begin
        $display("  %0s: only %0d bytes captured", what, nb);
        errors = errors + 1;
    end else if (cap[at]   !== 8'hAA || cap[at+1] !== 8'h00 ||
                 cap[at+2] !== 8'd6  || cap[at+3] !== CMD  ||
                 cap[at+4] !== {6'd0, lvl}     ||
                 cap[at+5] !== tx[7:0] || cap[at+6] !== {1'b0, tx[14:8]} ||
                 cap[at+7] !== ty[7:0] || cap[at+8] !== {1'b0, ty[14:8]}) begin
        $display("  %0s: got %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                 what, cap[at], cap[at+1], cap[at+2], cap[at+3], cap[at+4],
                 cap[at+5], cap[at+6], cap[at+7], cap[at+8]);
        errors = errors + 1;
    end
end
endtask

task automatic send_miss(input [1:0] lvl, input [14:0] tx, input [14:0] ty);
begin
    @(posedge clk);
    miss = 1'b1; miss_level = lvl; miss_tx = tx; miss_ty = ty;
    @(posedge clk);
    miss = 1'b0;
end
endtask

task automatic clear_capture;
begin
    nb = 0;
end
endtask

integer w, dd;

initial begin
    repeat (4) @(posedge clk);
    resetn = 1'b1;
    repeat (4) @(posedge clk);

    // nothing to say, so nothing is said
    repeat (40) @(posedge clk);
    want(nb == 0, "an empty queue sends nothing");
    want(req_hold === 1'b0, "an empty queue does not hold the line");

    // one miss, one frame, byte for byte
    send_miss(2'd1, 15'h1234, 15'h0010);
    repeat (10 * GAP + 20) @(posedge clk);
    want(nb == 9, "one request is nine bytes");
    want_frame(0, 2'd1, 15'h1234, 15'h0010, "the frame carries the tile");
    want(count == 8'd0, "the request retired");

    // the same tile missed twice before it is sent is one request
    clear_capture;
    grant_open = 1'b0;                      // hold the line so it stays queued
    send_miss(2'd2, 15'h0001, 15'h0002);
    send_miss(2'd2, 15'h0001, 15'h0002);
    send_miss(2'd2, 15'h0001, 15'h0003);
    want(count == 8'd2, "the duplicate was folded into the queue");
    grant_open = 1'b1;
    repeat (40 * GAP) @(posedge clk);
    want(nb == 18, "two distinct requests are two frames");
    want_frame(0, 2'd2, 15'h0001, 15'h0002, "the first queued tile");
    want_frame(9, 2'd2, 15'h0001, 15'h0003, "the second queued tile");

    // the same tile again after it has gone is a new request
    clear_capture;
    send_miss(2'd2, 15'h0001, 15'h0002);
    repeat (10 * GAP + 20) @(posedge clk);
    want(nb == 9, "a repeat miss is a new request");
    want_frame(0, 2'd2, 15'h0001, 15'h0002, "the repeated tile");

    // the loader wants the line: nothing starts, and nothing is lost
    clear_capture;
    loader_wants = 1'b1;
    send_miss(2'd0, 15'h0005, 15'h0006);
    repeat (20 * GAP) @(posedge clk);
    want(nb == 0, "no byte starts while the loader holds the line");
    want(req_hold === 1'b0, "a queued request does not hold the line");
    loader_wants = 1'b0;
    repeat (10 * GAP + 20) @(posedge clk);
    want(nb == 9, "the frame goes once the loader lets go");
    want_frame(0, 2'd0, 15'h0005, 15'h0006, "the frame after the wait");

    // a frame in progress keeps the line even if the loader asks for it
    clear_capture;
    send_miss(2'd3, 15'h3FFF, 15'h0009);
    repeat (GAP + 2) @(posedge clk);
    loader_wants = 1'b1;
    repeat (10 * GAP + 10) @(posedge clk);
    loader_wants = 1'b0;
    want(nb == 9, "the frame survived the loader asking mid-frame");
    want_frame(0, 2'd3, 15'h3FFF, 15'h0009, "the whole frame, in order");

    // a full queue drops and says so, and what it holds is still in order
    clear_capture;
    grant_open = 1'b0;
    for (w = 0; w < DEPTH + 2; w = w + 1) send_miss(2'd0, w[14:0], 15'h0100);
    want(count == DEPTH[7:0], "the queue filled");
    want(overflow === 1'b1, "the drop was reported");
    grant_open = 1'b1;
    repeat (DEPTH * 12 * (GAP + 2) + 80) @(posedge clk);
    want(nb == DEPTH * 9, "the queued requests all went out");
    for (w = 0; w < DEPTH; w = w + 1)
        want_frame(w * 9, 2'd0, w[14:0], 15'h0100, "a queued request in order");
    want(count == 8'd0, "the queue drained");

    // a push that lands on the same edge as a frame's last byte is the one place
    // the queue's depth is decremented and incremented together.  Push at every
    // offset inside a frame's lifetime, so exactly one of these lands on the
    // retire edge: a lost push there shows up as a frame that never goes out.
    for (dd = 0; dd < 50; dd = dd + 1) begin
        clear_capture;
        send_miss(2'd1, 15'h0500 + dd[14:0], 15'h0005);
        repeat (dd) @(posedge clk);
        send_miss(2'd1, 15'h0600 + dd[14:0], 15'h0006);
        repeat (2 * 10 * (GAP + 2) + 40) @(posedge clk);
        if (nb != 18) begin
            $display("  push at offset %0d: %0d bytes, want 18", dd, nb);
            errors = errors + 1;
        end else begin
            want_frame(0, 2'd1, 15'h0500 + dd[14:0], 15'h0005, "the first of the pair");
            want_frame(9, 2'd1, 15'h0600 + dd[14:0], 15'h0006, "the second of the pair");
        end
        if (count != 8'd0) begin
            $display("  push at offset %0d: %0d left in the queue", dd, count);
            errors = errors + 1;
        end
    end

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (requests are framed once, in order, and never dropped mid-frame)");
    $finish;
end

initial begin
    #(500e6);
    $display("RESULT: FAIL (timeout)");
    $finish;
end

endmodule
