// Ask the host for a tile.
//
// The sequencer reports a miss with the tile's coordinates; this module holds
// those requests in a short queue and sends each one over the link as a frame.
// It owns nothing else: it does not know whether the tile ever arrives, and it
// does not know what the answer means.
//
// The frame is the one the host itself sends, so a single parser serves both
// directions:
//
//     0xAA  length high  length low  command  payload ...
//
// with a command of `CMD` (0x1C by default) and a five-byte payload: the level,
// then the tile's x and y, fifteen bits each in sixteen and little-endian like
// every other payload in this protocol -- only the frame's own length is
// big-endian.  The length counts the command and the payload, so it is six.
//
//     AA 00 06 1C L TXL TXH TYL TYH
//
// Nothing is answered.  The reply is the tile's bytes arriving as their own
// command, and a request that is never answered is asked again the next time a
// line needs that tile: there is no retry timer here, because the renderer keeps
// drawing and keeps missing, and that is the retry.
//
// Two requests for the same tile in the queue are one request.  A line misses in
// chunks, so the same tile can arrive eight times in a row and should go out
// once.  The same tile asked for again *after* its request has gone is a second
// request, deliberately: that is a tile that was asked for and did not arrive in
// time, and asking again is the only thing this module can do about it.
//
// The transmitter is shared with the loader's answers, so a frame is offered
// only while the arbiter grants it, and it keeps the grant from the first byte it
// actually gets until the last.  A byte is offered until the arbiter
// acknowledges it, which makes lost arbitration a retry rather than a hole in
// the middle of a frame: a frame with a byte missing is worse than a frame that
// is late.  `req_hold` rises on the first acknowledgement and not on the offer,
// because a lost offer has not taken the line -- claiming it there would stall
// the loader's answer that won.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_tile_req #(
    parameter int   DEPTH = 8,             // requests that can be outstanding
    parameter [7:0] CMD   = 8'h1C
) (
    input  wire        clk,
    input  wire        resetn,

    // the sequencer's miss, with the tile it was about
    input  wire        miss,
    input  wire [1:0]  miss_level,
    input  wire [14:0] miss_tx,
    input  wire [14:0] miss_ty,

    // the link's transmitter, shared with the loader's answers
    input  wire        tx_grant,      // the arbiter has given this frame the line
    input  wire        tx_ready,      // the transmitter is idle and can take a byte
    input  wire        tx_ack,        // the byte offered this cycle was taken
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    output wire        req_hold,      // this module owns the line until it drops

    // how many requests are waiting, and whether one was ever dropped
    output wire [7:0]  count,
    output reg         overflow       // a request was dropped; sticky until reset
);

localparam int PTRW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
localparam [3:0] LAST = 4'd8;          // the ninth byte of the frame

// a request is {level, tx, ty}: thirty-two bits, one array
reg  [31:0]     q [0:DEPTH-1];
reg  [PTRW-1:0] head = '0;
reg  [PTRW:0]   cnt  = '0;
reg  [PTRW-1:0] tail = '0;

wire [31:0] miss_tag = {miss_level, miss_tx, miss_ty};
assign count = cnt;                    // zero-extended; DEPTH is under 256

// is this tile already queued?
reg dup;
integer i;
always @* begin
    dup = 1'b0;
    for (i = 0; i < DEPTH; i = i + 1)
        if (i < cnt && q[(head + i[PTRW-1:0]) & (DEPTH-1)] == miss_tag) dup = 1'b1;
end

wire push = miss && !dup && (cnt < DEPTH);
wire full = miss && !dup && (cnt == DEPTH);

// the head of the queue, as the frame's own fields
wire [1:0]  q_level = q[head][31:30];
wire [14:0] q_tx    = q[head][29:15];
wire [14:0] q_ty    = q[head][14:0];

// ------------------------------------------------------------- the frame ---
function automatic [7:0] frame_byte(input [3:0] idx, input [1:0] lvl,
                                    input [14:0] tx, input [14:0] ty);
    case (idx)
        4'd0:    frame_byte = 8'hAA;
        4'd1:    frame_byte = 8'h00;                 // length high
        4'd2:    frame_byte = 8'd6;                  // length low: command + five
        4'd3:    frame_byte = CMD;
        4'd4:    frame_byte = {6'd0, lvl};
        4'd5:    frame_byte = tx[7:0];
        4'd6:    frame_byte = {1'b0, tx[14:8]};
        4'd7:    frame_byte = ty[7:0];
        default: frame_byte = {1'b0, ty[14:8]};
    endcase
endfunction

localparam [0:0] R_IDLE = 1'b0, R_SEND = 1'b1;
reg       st;
reg [3:0] bi = 4'd0;                   // which byte of the frame is being offered

// the last byte of a frame being taken retires its request.  A push can land on
// that same edge, so the depth is computed from both events at once: two
// assignments to one register in one cycle keep the last, which loses the push
// from the count while its bytes sit in the queue, and a request that is in the
// queue and not counted is a request that never goes out.
wire pop = (st == R_SEND) && tx_ack && (bi == LAST);

// the line is ours only once a byte has been taken
reg taken;
assign req_hold = (st == R_SEND) && taken;

always @(posedge clk) begin
    if (!resetn) begin
        st <= R_IDLE;
        bi <= 4'd0;
        taken <= 1'b0;
        head <= '0; tail <= '0; cnt <= '0;
        tx_start <= 1'b0; tx_data <= 8'd0;
        overflow <= 1'b0;
        for (i = 0; i < DEPTH; i = i + 1) q[i] <= 32'd0;
    end else begin
        tx_start <= 1'b0;

        // a miss that arrives mid-frame is queued, not lost
        if (push) begin
            q[tail] <= miss_tag;
            tail    <= tail + 1'b1;
        end
        if (push && !pop)      cnt <= cnt + 1'b1;
        else if (!push && pop) cnt <= cnt - 1'b1;
        if (full) overflow <= 1'b1;

        case (st)
        R_IDLE: if (cnt != 0 && tx_grant && tx_ready) begin
            taken    <= 1'b0;
            tx_start <= 1'b1;
            tx_data  <= frame_byte(4'd0, q_level, q_tx, q_ty);
            bi       <= 4'd0;
            st       <= R_SEND;
        end

        // Offer the current byte until it is taken.  The transmitter is busy for
        // ten bit times after an acknowledgement, so the next byte is offered
        // when `tx_ready` comes back rather than in the acknowledging cycle.
        R_SEND: if (tx_ack) begin
            taken <= 1'b1;
            if (bi == LAST) begin
                head <= head + 1'b1;
                st   <= R_IDLE;
            end else begin
                bi <= bi + 1'b1;
            end
        end else if (tx_ready) begin
            tx_start <= 1'b1;
            tx_data  <= frame_byte(bi, q_level, q_tx, q_ty);
        end

        default: st <= R_IDLE;
        endcase
    end
end

endmodule
