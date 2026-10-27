// The tile fetch: one window of a source row, walked in chunks across tiles.
//
// The renderer asks for `span` entries of one source row starting at an entry of
// the level.  This module splits that into chunks that each stay inside one tile,
// looks each tile up in the page table, reads the chunk from the pool and writes
// the entries into the caller's row buffer in order.  The caller sees one fetch:
// `start` in, `done` out, and a write per entry.
//
// The chunk breaks are the tile grid's, not a stride from the window start: a
// chunk runs from wherever the previous one ended to the next multiple of TENT
// entries, which is the tile boundary.  A caller that stepped by a fixed stride
// would disagree with the grid at every boundary but the first.
//
// A tile that is not resident is a `miss`: the fetch stops where it is and says
// so, and the caller decides whether to ask for the tile and retry or to draw
// that line from the coarser level.  Deliberately not handled here -- this module
// owns the sequence, not the policy.
//
// The page table answers a cycle after it is asked, so the sequence has a lookup
// state between chunks.  That is the whole cost of tiling on the fetch side: one
// cycle per tile boundary plus the SDRAM page misses the chunks themselves cause.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_tile_fetch #(
    parameter int SPAN  = 644,       // entries in a window: OUT_W/2 + 4
    parameter int TSIZE = 256,       // pixels across a tile
    parameter int TENT  = 128,       // entries across a tile row
    parameter int TW    = 8
) (
    input  wire        clk,
    input  wire        resetn,

    // one window of one source row
    input  wire        start,
    input  wire [1:0]  level,
    input  wire [11:0] row,
    input  wire [13:0] entry0,
    input  wire [15:0] span,          // entries wanted, at most SPAN
    output reg         busy,
    output reg         done,          // one cycle when the window is complete
    output reg         miss,          // one cycle when a tile was not resident

    // entries land here, in window order
    output reg         we,
    output reg  [$clog2(SPAN)-1:0] widx,
    output reg  [15:0] wdata,

    // the page table, one cycle behind the question
    output reg         lk_valid,
    output wire [14:0] lk_tx,
    output wire [14:0] lk_ty,
    input  wire        lk_hit,
    input  wire [24:0] lk_addr,

    // the pool, through the video channel's own protocol
    output reg         rd_start,
    output reg  [24:0] rd_addr,
    output reg  [15:0] rd_count,
    input  wire [15:0] rd_data,
    input  wire        rd_valid
);

localparam int AIDX = $clog2(SPAN);

// where the entry we are about to ask about lives
reg  [1:0]  f_level = 2'd0;
reg  [11:0] f_row = 12'd0;
reg  [13:0] f_entry = 14'd0;
reg  [13:0] f_end = 14'd0;
reg  [AIDX-1:0] f_j = '0;
reg  [15:0] f_left = 16'd0;          // entries still to read in this chunk
reg  [15:0] f_take = 16'd0;

wire [15:0] byte_off;
wire [7:0]  avail;

maps_tile_addr #(.TSIZE(TSIZE), .TENT(TENT), .TW(TW)) u_addr (
    .level(f_level), .row(f_row), .entry(f_entry),
    .tx(lk_tx), .ty(lk_ty), .byte_off(byte_off), .entries(avail));

localparam [2:0] F_IDLE = 3'd0, F_LOOK = 3'd1, F_ISSUE = 3'd2, F_READ = 3'd3,
                 F_WAIT = 3'd4;
reg [2:0] st;

// the chunk's length is the tile boundary or the window's end, whichever comes
// first; the window's end is a subtraction that cannot underflow because the
// fetch only asks about entries it still needs
wire [15:0] remaining = {2'd0, f_end} - {2'd0, f_entry};
wire [15:0] take = (remaining < {8'd0, avail}) ? remaining : {8'd0, avail};

always @(posedge clk) begin
    if (!resetn) begin
        st <= F_IDLE; busy <= 1'b0; done <= 1'b0; miss <= 1'b0;
        we <= 1'b0; widx <= '0; wdata <= 16'd0;
        lk_valid <= 1'b0; rd_start <= 1'b0; rd_addr <= 25'd0; rd_count <= 16'd0;
        f_level <= 2'd0; f_row <= 12'd0; f_entry <= 14'd0; f_end <= 14'd0; f_j <= '0;
        f_left <= 16'd0; f_take <= 16'd0;
    end else begin
        we <= 1'b0; done <= 1'b0; miss <= 1'b0;
        lk_valid <= 1'b0; rd_start <= 1'b0;

        case (st)
        F_IDLE: if (start) begin
            f_level <= level;
            f_row   <= row;
            f_entry <= entry0;
            f_end   <= entry0 + span[13:0];
            f_j     <= '0;
            busy    <= 1'b1;
            st      <= F_LOOK;
        end

        // Ask the page table where this entry is.  It registers the question,
        // then registers the answer, so `lk_hit` is only valid two cycles after
        // this one -- the wait state is not politeness, it is the pipeline.
        F_LOOK: begin
            lk_valid <= 1'b1;
            st       <= F_WAIT;
        end

        F_WAIT: st <= F_ISSUE;

        F_ISSUE: if (lk_hit) begin
            rd_addr  <= lk_addr + {9'd0, byte_off};
            rd_count <= take;
            f_take   <= take;
            f_left   <= take;
            rd_start <= 1'b1;
            st       <= F_READ;
        end else begin
            // not resident: stop and say so, leaving the window part filled
            miss <= 1'b1;
            busy <= 1'b0;
            st   <= F_IDLE;
        end

        F_READ: if (rd_valid) begin
            we    <= 1'b1;
            widx  <= f_j;
            wdata <= rd_data;
            f_j   <= f_j + 1'b1;
            f_left <= f_left - 16'd1;
            f_entry <= f_entry + 14'd1;
            if (f_left == 16'd1) begin
                // this chunk is done: the window, or the next tile
                if (f_entry + 14'd1 == f_end) begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    st   <= F_IDLE;
                end else begin
                    st <= F_LOOK;
                end
            end
        end

        default: st <= F_IDLE;
        endcase
    end
end

endmodule
