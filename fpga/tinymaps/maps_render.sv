// TinyMaps renderer: bilinear, with the next line prefetched while the current
// one is drawn.
//
// The viewport is expressed in the selected level's own pixel space (Q16.16).
// A source row is held in block RAM as 16-bit entries of two adjacent 8-bit
// pixels.  Three row buffers are kept because a bilinear line reads two rows at
// once and the row the next line will need must be fetched during this line:
// two buffers are read, the third is being written.
//
// Row rotation.  With step_y in [1,2) the source row advances by at most one
// per output line, so the pair a line needs shares one row with the pair the
// previous line needed.  A line rotates the buffers rather than refetching:
// this line's second row becomes its first, the prefetched row becomes the
// second, and the row just finished becomes the one to prefetch into.  A
// discontinuity -- frame start, a zoom or pan change -- falls back to a blocking
// fetch of both rows, which costs more than one line period; that is one line
// per frame or per gesture, not per line.
//
// The coarse fallback.  A tile that is not in the pool is not a stall and not a
// hole in the picture: the line is drawn from the next level down, which is
// resident, and sharpens when the tile arrives.  The cheap way to say that is a
// viewport at half the scale -- the coarse level's row is the fine row over two,
// its entry is the fine entry over two, and two output pixels share one coarse
// pixel -- and since the renderer already magnifies by any step, all that changes
// is where the row, the window and the parity come from.  Nothing in the pixel
// pipeline knows: it is still one row of entries, read the same way.
//
// Cost per output pixel: two block RAM reads (one per row), three 8x16
// multiplies, one palette read.  Per output line: SPAN entry fetches, overlapped
// with the OUT_W emits.
//
// The source port is a streaming row read: pulse rd_start with an address and an
// entry count, and entries arrive one per cycle on rd_valid.  That is the shape
// ahb_sdram's video channel has once an adapter issues its 256-byte line reads;
// the adapter is integration work, not here.
//
// SPDX-License-Identifier: GPL-3.0-only

`timescale 1ns / 1ps

module maps_render #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    // entries fetched per row; one entry is two source pixels.  With step_x < 2
    // a line spans at most 2*OUT_W source pixels, i.e. OUT_W entries, and four
    // more cover the straddle at the edges.
    parameter integer SPAN  = OUT_W + 4,
    // How long the blocking fetch waits after a tile it needs is missing before
    // it asks again, in clocks.  A request is not acknowledged, so this is the
    // only thing that re-asks when the answer has not come; too short and the
    // link carries a request per line, too long and a tile that arrived leaves
    // the picture waiting on a timer.  2^21 clocks is about 28 ms at 74.25 MHz,
    // roughly a fifth of the time a 64 KiB tile takes over the link.  It is a
    // parameter so a testbench can shorten the wait to something watchable.
    parameter int TILE_RETRY = 21'h1F_FFFF
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire signed [31:0] src_x0,
    input  wire signed [31:0] src_y0,
    input  wire        [31:0] step_x,
    input  wire        [31:0] step_y,
    input  wire        bilinear,
    input  wire [24:0] level_base,
    input  wire [15:0] level_w,
    input  wire [15:0] level_h,

    output reg         rd_start,
    output reg  [24:0] rd_addr,
    output reg  [15:0] rd_count,
    input  wire [15:0] rd_data,
    input  wire        rd_valid,

    input  wire        pal_we,
    input  wire [7:0]  pal_idx,
    input  wire [23:0] pal_data,

    input  wire [10:0] cx,
    input  wire [9:0]  cy,

    // diagnostic: complete row fetches performed, so a test can tell row reuse
    // and overlapped prefetch from a blocking refetch every line
    output reg  [15:0] fetch_count,
    output wire [2:0]  dbg_state,      // the line engine's state, for the link's status command

    output reg  [11:0] out_x,
    output reg  [23:0] out_rgb,      // palette-resolved, for the testbench
    output reg  [7:0]  out_idx,      // the palette index, for a cross-domain line store
    output reg         out_valid,

    // Tile mode.  When `stream` is high the fetch engine stops computing a
    // linear byte address and instead asks maps_tile_fetch for the window; the
    // sequencer reads it in per-tile chunks and hands back one entry at a time.
    // The linear path is still here and still what runs when `stream` is low,
    // because until a host can answer a request a tile pool is an empty pool --
    // so which path the picture comes from is the host's choice, not the
    // bitstream's.  Both paths are built; one of them runs.
    input  wire        stream,
    input  wire [1:0]  tile_level,     // the finest level the view is over
    // the level the sequencer is being asked about: the view's own, or the one
    // below it when the line is being drawn from the fallback
    output wire [1:0]  seq_level,
    output reg         seq_start,
    output reg  [13:0] seq_entry,
    output wire [11:0] seq_row,
    output wire [15:0] seq_span,
    input  wire        seq_we,
    input  wire [AIDX-1:0] seq_widx,
    input  wire [15:0] seq_wdata,
    input  wire        seq_done,
    input  wire        seq_miss,
    output reg  [15:0] tile_misses
);

localparam integer AIDX = $clog2(SPAN);

// one source of entries for the row buffers, whichever mode is on
wire             src_we   = stream ? seq_we    : rd_valid;
wire [AIDX-1:0]  src_idx  = stream ? seq_widx  : f_j;
wire [15:0]      src_data = stream ? seq_wdata : rd_data;
wire             src_done = stream ? seq_done  : (f_j == f_cnt[AIDX-1:0] - 1'b1);
wire             src_miss = stream ? seq_miss  : 1'b0;

// ------------------------------------------------------------------ palette --
reg [23:0] pal [0:255];
always @(posedge clk) if (pal_we) pal[pal_idx] <= pal_data;

// ------------------------------------------------------- buffers and fetch ---
reg [15:0] lb0 [0:SPAN-1];
reg [15:0] lb1 [0:SPAN-1];
reg [15:0] lb2 [0:SPAN-1];
reg [31:0] brow [0:2];
reg [2:0]  bval;
reg [31:0] col_tag;

// read stage: the three arrays are read together and the two live rows are
// muxed combinationally, so an entry is available one cycle after rd_idx.
reg [AIDX-1:0] rd_idx, rd_idx_d;
reg [15:0] q0, q1, q2, qc_d, qn_d;
reg [1:0]  cur, nxt;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        q0 <= 16'd0; q1 <= 16'd0; q2 <= 16'd0; qc_d <= 16'd0; qn_d <= 16'd0;
        rd_idx_d <= {AIDX{1'b0}};
    end else begin
        q0 <= lb0[rd_idx];
        q1 <= lb1[rd_idx];
        q2 <= lb2[rd_idx];
        // The entry *before* the current one is only the previous cycle's read
        // when the index advanced.  At magnification it stalls, and reloading
        // qc_d/qn_d every cycle would replace it with the current entry.
        rd_idx_d <= rd_idx;
        if (rd_idx != rd_idx_d) begin
            qc_d <= (cur == 2'd0) ? q0 : (cur == 2'd1) ? q1 : q2;
            qn_d <= (nxt == 2'd0) ? q0 : (nxt == 2'd1) ? q1 : q2;
        end
    end
end

wire [15:0] qcw = (cur == 2'd0) ? q0 : (cur == 2'd1) ? q1 : q2;
wire [15:0] qnw = (nxt == 2'd0) ? q0 : (nxt == 2'd1) ? q1 : q2;

// ------------------------------------------------------------- line engine ---
localparam [2:0] S_IDLE = 3'd0, S_PLAN = 3'd1, S_BFETCH = 3'd2,
                 S_EMIT = 3'd3, S_DONE  = 3'd4,
                 S_ROWS = 3'd5,        // the row pair
                 S_RADDR = 3'd6;       // that row's byte address in the level

reg [2:0]  st;
reg [9:0]  cy_d;
reg [31:0] acc_y;
reg [31:0] r0, r1;
reg [15:0] wy;
reg [31:0] k0;
reg [15:0] emit_x;
reg [31:0] acc_x;
reg [1:0]  fre;
reg [2:0]  block_step;
reg [2:0]  block_retry;                // where the blocking fetch resumes

// fetch engine, serviced every cycle by the block below so it runs under S_EMIT
reg        f_req;
reg        f_busy;
reg        f_ack;
reg [1:0]  f_buf;
reg [AIDX-1:0] f_j;
reg [31:0] f_row, f_col;
reg        f_missed;                  // a fetch was refused by the pool
reg [20:0] retry_cnt;                 // and this is how long before it asks again

// The fallback: `cfall` is the scale the picture is being drawn at, and the
// buffers remember which scale their contents are, because a line may only mix
// rows that came from the same level.
reg        cfall;
reg        stream_d;                  // the source the picture was being drawn from
reg  [2:0] bcrs;                      // per row buffer: fetched from the level below
reg [24:0] f_base;
reg [15:0] f_cnt;

assign seq_row  = f_row[11:0];
assign seq_span = f_cnt;

reg        p1_v, p1_odd, p1_bil;
reg        p1b_v, p1b_odd, p1b_bil;
reg [11:0] p1b_x;
reg [15:0] p1b_fx, p1b_wy;
reg [11:0] p1_x;
reg [15:0] p1_fx, p1_wy;
reg        p2_v, p2_bil;
reg [11:0] p2_x;
reg [7:0]  p2_h0, p2_h1;
reg [15:0] p2_wy;
reg        p3_v;
reg [11:0] p3_x;
reg [7:0]  p3_idx;

// 32-bit intermediate on purpose: written as a single expression the product is
// evaluated at the 8-bit width of the return value and every blend truncates.
function automatic [7:0] blend(input [7:0] a, input [7:0] b, input [15:0] w);
    reg [31:0] t;
    begin
        t = a * (16'hFFFF - w) + b * w + 32'h8000;
        blend = t[23:16];
    end
endfunction

wire [7:0] a0 = p1b_odd ? qc_d[15:8] : qcw[7:0];
wire [7:0] a1 = p1b_odd ? qcw[7:0]   : qcw[15:8];
wire [7:0] b0 = p1b_odd ? qn_d[15:8] : qnw[7:0];
wire [7:0] b1 = p1b_odd ? qnw[7:0]   : qnw[15:8];

// The two rows this line needs, clamped at the bottom of the level.  Registered
// in S_ROWS, one cycle before they are used: written combinationally from r0
// they put a 32-bit add, a compare and a mux in front of the `pf_row * level_w`
// multiply and the fetch base, and that chain was the critical path of the
// whole design -- 13.22 ns of a 13.47 ns period at placement seed 7, with
// eighteen carry-chain steps and 2.57 ns of routing in it.
wire [31:0] row_ok = (r0 + 32'd1 >= level_h) ? level_h - 32'd1 : r0 + 32'd1;
wire [31:0] pf_row = (r0 + 32'd2 >= level_h) ? level_h - 32'd1 : r0 + 32'd2;
reg  [31:0] r_ok, r_pf;
// r_pf * level_w, registered: with the row pair it was a multiply and a 25-bit
// add chain into f_base inside one clock, which is what the critical path became
// once the row pair moved out of it.
reg  [31:0] r_addr;
// A buffer satisfies a row only if it also came from the level the picture is
// being drawn at.  Without the scale here a coarse row would satisfy a fine
// line for ever: the epoch would end, the picture would ask for the view's own
// level, and every buffer would say "I already have that row".
wire        pf_want = !(bval[0] && brow[0] == r_pf && bcrs[0] == cfall) &&
                      !(bval[1] && brow[1] == r_pf && bcrs[1] == cfall) &&
                      !(bval[2] && brow[2] == r_pf && bcrs[2] == cfall);
wire [31:0] e_now  = (acc_x + 32'd65536) >>> 17;
// the coarse pass works in half-scale coordinates: the row, the window's first
// entry and the pixel's own position are all the fine ones halved.  r0/r_ok/r_pf
// and brow stay in fine units -- they name the source row the picture wants, not
// the row the bytes came from.
wire [31:0] r0_e   = cfall ? (r0   >> 1) : r0;
wire [31:0] r_ok_e = cfall ? (r_ok >> 1) : r_ok;
wire [31:0] r_pf_e = cfall ? (r_pf >> 1) : r_pf;
wire [31:0] k0_e   = cfall ? (k0_pf >> 1) : k0_pf;
wire [15:0] cnt_e  = cfall ? ((SPAN[15:0] >> 1) + 16'd2) : SPAN[15:0];
wire [31:0] x_e    = bcrs[cur] ? (acc_x >> 1) : acc_x;
wire [31:0] e_new  = (x_e + 32'd65536) >>> 17;

// The level table is finest first, so the level below the view is one higher;
// level 3 is the coarsest there is and falls back to nothing.
wire       can_fall = (tile_level != 2'd3);
assign seq_level = cfall ? (tile_level + 2'd1) : tile_level;
wire [31:0] k0_now = (src_x0 + 32'd65536) >>> 17;
// the window starts one entry early so the first pixel's previous entry is real
wire [31:0] k0_pf  = (k0_now == 32'd0) ? 32'd0 : k0_now - 32'd1;
wire        win_ok = (col_tag == k0_pf);

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        st <= S_IDLE; cy_d <= 10'h3FF; acc_y <= 32'd0; r0 <= 32'd0; r1 <= 32'd0;
        wy <= 16'd0; k0 <= 32'd0; emit_x <= 16'd0; acc_x <= 32'd0;
        cur <= 2'd0; nxt <= 2'd1; fre <= 2'd2; block_step <= 3'd0;
        rd_idx <= {AIDX{1'b0}};
        rd_start <= 1'b0; rd_addr <= 25'd0; rd_count <= 16'd0;
        brow[0] <= 32'hFFFFFFFF; brow[1] <= 32'hFFFFFFFF; brow[2] <= 32'hFFFFFFFF;
        bval <= 3'b000; col_tag <= 32'hFFFFFFFF;
        f_req <= 1'b0; f_busy <= 1'b0; f_ack <= 1'b0; f_buf <= 2'd0;
        f_missed <= 1'b0; retry_cnt <= 21'd0; block_retry <= 3'd0;
        cfall <= 1'b0; bcrs <= 3'b000;
        stream_d <= 1'b0;
        f_j <= {AIDX{1'b0}}; f_row <= 32'd0; f_col <= 32'd0;
        f_base <= 25'd0; f_cnt <= 16'd0;
        p1_v <= 1'b0; p1_odd <= 1'b0; p1_bil <= 1'b0; p1_x <= 12'd0;
        p1_fx <= 16'd0; p1_wy <= 16'd0;
        p1b_v <= 1'b0; p1b_odd <= 1'b0; p1b_bil <= 1'b0; p1b_x <= 12'd0;
        p1b_fx <= 16'd0; p1b_wy <= 16'd0;
        p2_v <= 1'b0; p2_bil <= 1'b0; p2_x <= 12'd0;
        p2_h0 <= 8'd0; p2_h1 <= 8'd0; p2_wy <= 16'd0;
        p3_v <= 1'b0; p3_x <= 12'd0; p3_idx <= 8'd0;
        seq_start <= 1'b0; seq_entry <= 14'd0; tile_misses <= 16'd0;
        out_x <= 12'd0; out_rgb <= 24'd0; out_idx <= 8'd0; out_valid <= 1'b0; fetch_count <= 16'd0;
        // The row buffers are deliberately not reset: a reset forces them out
        // of block RAM into flip-flops, and they are only read once bval says
        // the row has landed.
    end else begin
        out_valid <= 1'b0;
        p1_v     <= 1'b0;
        rd_start <= 1'b0;
        if (retry_cnt != 21'd0) retry_cnt <= retry_cnt - 21'd1;
        seq_start <= 1'b0;
        f_ack    <= 1'b0;

        // ------------------------------------------------------- fetch engine --
        if (f_busy) begin
            if (src_we) begin
                case (f_buf)
                    2'd0: lb0[src_idx] <= src_data;
                    2'd1: lb1[src_idx] <= src_data;
                    default: lb2[src_idx] <= src_data;
                endcase
            end
            if (src_done) begin
                f_busy      <= 1'b0;
                f_ack       <= 1'b1;
                fetch_count <= fetch_count + 16'd1;
                bval[f_buf] <= 1'b1;
                brow[f_buf] <= f_row;
                bcrs[f_buf] <= cfall;
                col_tag     <= f_col;
            end else if (src_miss && !cfall && can_fall) begin
                // the view's own level could not answer: draw this line from the
                // level below, which is the whole point of the fallback, and let
                // the retry timer bring the fine attempt back
                f_busy      <= 1'b0;
                f_missed    <= 1'b1;
                cfall       <= 1'b1;
                retry_cnt   <= TILE_RETRY[20:0];
                tile_misses <= tile_misses + 16'd1;
            end else if (src_miss) begin
                // the tile is not in the pool: leave the row unmarked, so the
                // line engine does not treat it as landed, count it, and start
                // the wait before asking again.  The blocking path waits for
                // `f_ack`, so without this a miss is a permanent stall.
                f_busy      <= 1'b0;
                f_missed    <= 1'b1;
                retry_cnt   <= TILE_RETRY[20:0];
                tile_misses <= tile_misses + 16'd1;
            end else if (!stream && rd_valid) begin
                f_j <= f_j + 1'b1;
            end
        end else if (f_req) begin
            f_req <= 1'b0;
            f_busy <= 1'b1;
            f_j    <= {AIDX{1'b0}};
            if (stream) begin
                seq_entry <= k0_e[13:0];
                seq_start <= 1'b1;
            end else begin
                rd_start <= 1'b1;
                rd_addr  <= f_base;
                rd_count <= f_cnt;
            end
        end

        // ----------------------------------------------------- pixel pipeline --
        // the block RAM read lands one cycle after rd_idx, so the pixel's
        // control has to be held one cycle longer to meet it
        p1b_v <= p1_v; p1b_odd <= p1_odd; p1b_bil <= p1_bil; p1b_x <= p1_x;
        p1b_fx <= p1_fx; p1b_wy <= p1_wy;
        p2_v <= p1b_v;
        if (p1b_v) begin
            p2_h0  <= p1b_bil ? blend(a0, a1, p1b_fx) : a0;
            p2_h1  <= p1b_bil ? blend(b0, b1, p1b_fx) : b0;
            p2_wy  <= p1b_wy;
            p2_bil <= p1b_bil;
            p2_x   <= p1b_x;
        end
        p3_v <= p2_v;
        if (p2_v) begin
            p3_idx <= p2_bil ? blend(p2_h0, p2_h1, p2_wy) : p2_h0;
            p3_x   <= p2_x;
        end
        if (p3_v) begin
            out_rgb   <= pal[p3_idx];
            out_idx   <= p3_idx;
            out_x     <= p3_x;
            out_valid <= 1'b1;
        end

        // ------------------------------------------------------- line engine --
        case (st)
        S_IDLE: if (cy != cy_d) begin
            cy_d <= cy;
            // the epoch ends at a line boundary, not mid-line: the next line
            // tries the view's own level again and falls back once more if it is
            // still not there.  The counter runs down on its own, whether or not
            // anything is waiting on it.
            if (retry_cnt == 21'd0) cfall <= 1'b0;
            if (cy == 0) begin
                r0    <= src_y0 >>> 16;
                wy    <= bilinear ? src_y0[15:0] : 16'd0;
                acc_y <= src_y0 + step_y;
            end else begin
                r0    <= acc_y >>> 16;
                wy    <= bilinear ? acc_y[15:0] : 16'd0;
                acc_y <= acc_y + step_y;
            end
            if (cy < OUT_H) st <= S_ROWS;
        end

        S_ROWS: begin
            r_ok <= row_ok;
            r_pf <= pf_row;
            st   <= S_RADDR;
        end

        S_RADDR: begin
            r_addr <= r_pf[15:0] * level_w;
            st     <= S_PLAN;
        end

        S_PLAN: begin
            r1 <= r_ok;
            k0 <= k0_pf;
            if (win_ok && bval[cur] && brow[cur] == r0 &&
                bval[nxt] && brow[nxt] == r_ok &&
                bcrs[cur] == cfall && bcrs[nxt] == cfall) begin
                // pair present: prefetch the third row while this line draws
                if (!f_busy && !f_req && pf_want) begin
                    f_req  <= 1'b1; f_buf <= fre; f_row <= r_pf_e; f_cnt <= cnt_e;
                    f_col  <= k0_e;
                    f_base <= level_base + r_addr + {1'b0, k0_pf[22:0], 1'b0};
                end
                emit_x <= 16'd0; acc_x <= src_x0; rd_idx <= {AIDX{1'b0}};
                st <= S_EMIT;
            end else if (win_ok && bval[nxt] && brow[nxt] == r0 &&
                         bval[fre] && brow[fre] == r_ok &&
                         bcrs[nxt] == cfall && bcrs[fre] == cfall) begin
                // one line on: rotate; the prefetched row becomes this line's second
                cur <= nxt; nxt <= fre; fre <= cur;
                if (!f_busy && !f_req && pf_want) begin
                    f_req  <= 1'b1; f_buf <= cur; f_row <= r_pf_e; f_cnt <= cnt_e;
                    f_col  <= k0_e;
                    f_base <= level_base + r_addr + {1'b0, k0_pf[22:0], 1'b0};
                end
                emit_x <= 16'd0; acc_x <= src_x0; rd_idx <= {AIDX{1'b0}};
                st <= S_EMIT;
            end else begin
                cur <= 2'd0; nxt <= 2'd1; fre <= 2'd2;
                block_step <= 3'd0;
                st <= S_BFETCH;
            end
        end

        // blocking fetch of both rows, used at a discontinuity
        S_BFETCH: begin
            case (block_step)
            3'd0: if (!f_busy) begin
                f_req  <= 1'b1; f_buf <= 2'd0; f_row <= r0_e; f_cnt <= cnt_e;
                f_col  <= k0_e;
                f_base <= level_base + (r0 * level_w) + {1'b0, k0_pf[22:0], 1'b0};
                block_step <= 3'd1;
            end
            3'd1: if (f_ack) block_step <= 3'd2;
                  else if (f_missed) begin f_missed <= 1'b0;
                                          block_retry <= 3'd0; block_step <= 3'd7; end
            3'd2: block_step <= 3'd3;               // one clear cycle between requests
            3'd3: if (!f_busy) begin
                f_req  <= 1'b1; f_buf <= 2'd1; f_row <= (cfall ? (r1 >> 1) : r1);
                f_cnt  <= cnt_e;
                f_col  <= k0_e;
                f_base <= level_base + (r1 * level_w) + {1'b0, k0_pf[22:0], 1'b0};
                block_step <= 3'd4;
            end
            3'd4: if (f_ack) block_step <= 3'd5;
                  else if (f_missed) begin f_missed <= 1'b0;
                                          block_retry <= 3'd3; block_step <= 3'd7; end
            // Prime the third buffer for the next line and *wait* for it.  It
            // was issued and left running while this line drew, which loses the
            // race: a row fetch takes about 1340 clocks and the emit takes
            // 1280, so the next line arrived with the buffer still empty, took
            // the blocking path itself, and the cascade ran for four lines.
            // That is the corruption at the top of every frame and after every
            // pan; paying for the fetch here costs one row on the single line
            // that had to block anyway.
            3'd5: if (!f_busy && !f_req) begin
                f_req  <= 1'b1; f_buf <= 2'd2; f_row <= r_pf_e; f_cnt <= cnt_e;
                f_col  <= k0_e;
                f_base <= level_base + r_addr + {1'b0, k0_pf[22:0], 1'b0};
                block_step <= 3'd6;
            end
            3'd6: if (f_missed) begin
                f_missed    <= 1'b0;
                block_retry <= 3'd5;
                block_step  <= 3'd7;
            end else if (f_ack) begin
                emit_x     <= 16'd0;
                acc_x      <= src_x0;
                rd_idx     <= {AIDX{1'b0}};
                block_step <= 3'd0;
                st         <= S_EMIT;
            end
            // wait after a miss, then try the same fetch again
            3'd7: if (retry_cnt == 21'd0) block_step <= block_retry;
            default: st <= S_BFETCH;
            endcase
        end

        S_EMIT: begin
            rd_idx <= (e_new - k0);
            acc_x  <= acc_x + step_x;

            p1_v   <= 1'b1;
            p1_x   <= {1'b0, emit_x[10:0]};
            p1_fx  <= x_e[15:0];
            p1_wy  <= bcrs[cur] ? (wy >> 1) : wy;
            p1_odd <= x_e[16];
            p1_bil <= bilinear;

            emit_x <= emit_x + 16'd1;
            if (emit_x == OUT_W - 1) st <= S_DONE;
        end

        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
        endcase

        // Changing the picture's source abandons whatever fetch was in flight.
        // The video channel is muxed on the same signal, so a linear fetch that
        // was in flight when the host switched to the pool would wait for a
        // completion that can never arrive: `f_busy` would stay set, the fetch
        // engine would never issue again, and no miss would ever reach the
        // request queue -- a board that draws nothing and asks for nothing.
        // It costs one line to give up cleanly instead.
        stream_d <= stream;
        if (stream != stream_d) begin
            f_req     <= 1'b0;
            f_busy    <= 1'b0;
            f_missed  <= 1'b0;
            retry_cnt <= 21'd0;
            rd_start  <= 1'b0;
            seq_start <= 1'b0;
            block_step <= 3'd0;
            bval      <= 3'b000;
            cfall     <= 1'b0;
            st        <= S_IDLE;
        end
    end
end

assign dbg_state = st;

endmodule
