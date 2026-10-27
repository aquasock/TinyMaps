// TinyMaps load receiver.
//
// Takes the BL616's byte stream after iosys_bl616's 0xAA frame parser has
// selected command 0x07 ("load data, length implied by the frame header") and
// runs TinyNES's load semantics over it, with the destination being an SDRAM
// byte address rather than a program entry point.
//
//   header, 5 words, little-endian, sent least significant byte first
//     0  magic      'TML1' in memory order, the u32 0x314c4d54
//     1  address    SDRAM byte address of the image, 8-byte aligned
//     2  length     image length in bytes
//     3  image crc  CRC-32 of the whole image, complemented
//     4  header crc CRC-32 of the first 16 bytes, complemented
//   then ceil(length / 8192) blocks, each of up to 8192 bytes followed by its
//   own CRC-32 over those bytes, complemented.
//
// CRC-32 is zlib's: reflected, polynomial 0xEDB88320, initial value ~0, and
// the value on the wire is the complement of the running register.
//
// Every header, block and image is answered ACK 0x06 or NAK 0x15 then a letter:
// 'H' header CRC, 'C' block CRC, 'I' image CRC, 'T' timeout.  A NAKed block is
// re-sent from its own start address, so rewriting it is harmless.  The sender
// is stop-and-wait, so nothing arrives until it has been answered.
//
// Command 0x08 loads the palette the pixel path reads.  Its payload, all
// little-endian:
//
//     u16 start    first entry to write, 0-255
//     u16 count    entries that follow
//     count * 3    R, G, B for each entry, ascending index
//     u32 crc      CRC-32 over the bytes above, complemented
//
// Answered ACK, or NAK 'P' for a bad CRC.  Entries are written as they arrive
// rather than buffered, so a rejected palette has already been applied; the
// sender re-sends it and every entry is written again, which is idempotent.
// A palette for the whole table is 772 bytes, inside the frame limit.
//
// Command 0x0A sets the viewport, which is what selects a level.  Its payload,
// all little-endian:
//
//     u32 level_base   byte address of the level's first pixel
//     u16 level_w      level width  } one word, width low
//     u16 level_h      level height
//     u32 step         Q16.16 source pixels per output pixel
//     u32 src_x0       Q16.16 level pixel shown at output x = 0
//     u32 src_y0
//     u32 crc          CRC-32 over the twenty bytes above, complemented
//
// Answered ACK, or NAK 'V' -- the CRC, the step outside (0.25, 1], the level
// empty, or the level not inside the SDRAM.  Nothing is latched on a refusal.
// The ceiling is the renderer's: above 1 a source row can advance by two per
// output line and the row rotation cannot engage.  The floor is the finest
// level's magnification limit -- below 0.5 no finer level exists to choose, so
// the step is the zoom.
//
// Command 0x0B loads the level table the zoom reads, up to four entries:
//
//     u8 count, then count * { u32 base, u16 w, u16 h }, then u32 crc
//
// Command 0x16 is the board's mouse, six bytes as the BL616 sends it: two of
// frame number (0xffff means apply now), the buttons, then dx, dy and wheel as
// signed counts.  Command 0x17 is its keyboard, the HID boot report: a modifier
// and six usage codes, sent only when the report changes, so a held key is one
// report and not a stream.  Neither is answered: the desk task sends them at a
// poll rate and a reply per frame would be traffic nobody reads.
//
// Command 0x0C asks what the renderer is actually being told, and is answered
// with twenty-one raw bytes rather than a frame, because the pipe a host uses
// is raw: base (4), width (2), height (2), step (4), origin x and y (4 each),
// and the renderer's state (1).  It exists because a picture that freezes into
// one repeated row says the renderer is drawing the same source line every
// time, and which of those six numbers caused it cannot be seen from outside.
//
// Command 0x1D is the answer to a tile request: one block of one tile.  A tile
// is 64 KiB and a frame is at most 2047 bytes, so a tile arrives as a run of
// blocks, each of them eight-byte aligned, which is what lets the write port
// take whole words and never a lane mask.  The payload, all little-endian:
//
//     u8  level        which level's tile grid
//     u16 tx, ty       the tile, fifteen bits each in sixteen
//     u16 offset       byte offset inside the tile, a multiple of eight
//     u16 count        bytes in this block, nonzero and a multiple of eight
//     count bytes      the tile's own bytes, in storage order
//     u32 crc          CRC-32 over every byte above, complemented
//
// Answered ACK, or NAK 'D' -- the CRC, a misaligned or zero count, a misaligned
// offset, or a block that would run past the end of the tile.  The bytes are
// written as they arrive, so a rejected block has already been written and the
// host re-sends it, which is idempotent; what a rejection does *not* do is make
// the tile resident.  The page table is told a tile has landed only when the
// block that ends it has passed its CRC and every write it caused has been
// acknowledged, because a tile that is marked resident while half of it is still
// in flight is a hit on somebody else's picture.
//
// The slot is not the host's to choose: it presents coordinates and this module
// adds them to the address the page table derives, so the cache's replacement
// policy stays in the cache.
//
// Command 0x1E is one byte that says which source the picture is drawn from:
// zero is the pack, which is what runs when nothing is answering tile requests,
// and one is the tile pool.  It is answered ACK.  It exists because the pool
// cannot answer itself: until the host serves tiles, streaming mode is an empty
// pool and an empty picture, so the mode belongs to the host and not to the
// bitstream.
//
// The write port is ahb_sdram's A25 side: req, address, lanes and data held
// steady until ack pulses.  Bytes are assembled little-endian into a 64-bit
// word and issued with all eight lanes; a short tail goes out with only the
// lanes its bytes occupy.
//
// SPDX-License-Identifier: GPL-3.0-only

`timescale 1ns / 1ps

module maps_link_rx #(
    parameter [31:0] MAGIC       = 32'h314c_4d54,   // 'TML1'
    parameter int    BLOCK_BYTES = 8192,
    parameter int    TBYTES      = 65536,          // bytes in a pool tile
    // Whether command 0x1D is accepted at all.  Off in the top until the pool
    // has a home: the pack occupies 27.62 MiB of the dock's 32 and the pool's
    // base is inside it, so a tile written now would land on the picture.  The
    // testbench turns it on; the top turns it on with the page table.
    parameter bit    TILES       = 1'b0,
    // Idle frame-parser cycles before the transfer is abandoned.  2^20 at
    // 21.49 MHz is about 49 ms, generous against a 2 Mbaud link's 5 us a byte.
    parameter int    TIMEOUT     = 20
) (
    input  wire        clk,
    input  wire        resetn,

    // command 0x07 payload bytes, from iosys_bl616's frame parser
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // response byte, stop-and-wait
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    input  wire        tx_busy,

    // SDRAM write port, ahb_sdram's A25 side
    output reg         wr_req,
    output reg  [24:3] wr_addr,
    output reg  [7:0]  wr_lanes,
    output reg  [63:0] wr_wdata,
    input  wire        wr_ack,

    // palette writes, straight into the table the pixel path reads
    output reg         pal_we,
    output reg  [7:0]  pal_idx,
    output reg  [23:0] pal_data,

    // tile blocks: the pool is filled here, at the slot the page table chose
    output reg  [1:0]  fill_level,
    output reg  [14:0] fill_tx,
    output reg  [14:0] fill_ty,
    input  wire [24:0] fill_addr,      // where those coordinates' bytes belong
    output reg         fill_commit,    // this tile's last block is in the pool

    // viewport, latched only when the command's own guard accepts it
    output reg         vp_we,
    output reg  [24:0] vp_base,
    output reg  [15:0] vp_w,
    output reg  [15:0] vp_h,
    output reg  [31:0] vp_step,
    output reg  signed [31:0] vp_x0,
    output reg  signed [31:0] vp_y0,

    // level table for the zoom, in SDRAM order, coarsest last
    output reg  [3:0]  lv_valid,
    output wire [24:0] lv_base0, lv_base1, lv_base2, lv_base3,
    output wire [15:0] lv_w0, lv_w1, lv_w2, lv_w3,
    output wire [15:0] lv_h0, lv_h1, lv_h2, lv_h3,

    // which source the picture is drawn from: 0 pack, 1 tile pool
    output reg         stream_on,

    // one navigation event: output pixels to pan, and a zoom step
    output reg         nav_ev,
    output reg  signed [15:0] nav_px,
    output reg  signed [15:0] nav_py,
    output reg  signed [1:0]  nav_zoom,
    output reg  [2:0]  nav_btn,        // the mouse's buttons, bit 0 left
    output reg         nav_mouse,      // the event is the mouse, not the keyboard

    // what the renderer is being told, for command 0x0C
    input  wire [24:0] st_base,
    input  wire [15:0] st_w, st_h,
    input  wire [31:0] st_step,
    input  wire signed [31:0] st_x0, st_y0,
    input  wire [2:0]  st_rstate,

    // how many tile requests are waiting, for the status command
    input  wire [7:0]  req_depth,

    // status
    output reg         busy,
    output reg  [31:0] images,
    output reg  [31:0] bytes_written,
    output reg  [7:0]  last_nak,
    output reg  [15:0] overflows,
    output reg  [15:0] timeouts
);

localparam [7:0] ACK = 8'h06;
localparam [7:0] NAK = 8'h15;

// ---------------------------------------------------------------- CRC-32 ----
// Eight rounds in one cycle.  Nothing here is on a fast path: the link delivers
// one byte per ~107 clocks at 2 Mbaud.
function automatic [31:0] crc32_byte(input [31:0] crc, input [7:0] b);
    reg [31:0] c;
    integer i;
    begin
        c = crc ^ {24'd0, b};
        for (i = 0; i < 8; i = i + 1)
            c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
        crc32_byte = c;
    end
endfunction

// -------------------------------------------------------- frame receiver ----
// 0xAA len[15:0] cmd payload[len-1], len_hi < 8 so a frame is at most 2047
// bytes including the command byte.
localparam [2:0] F_IDLE = 3'd0, F_LENH = 3'd1, F_LENL = 3'd2,
                 F_CMD  = 3'd3, F_DATA = 3'd4;

reg  [2:0]  fs;
reg  [15:0] flen;
reg  [7:0]  fcmd;
reg  [11:0] fleft;
reg         pl_valid;
reg  [7:0]  pl_data;

// ---------------------------------------------------------------- palette ----
// Command 0x08.  The payload is walked a byte at a time: two for the start
// index, two for the count, three per entry, four for the CRC.
localparam [2:0] P_IDLE = 3'd0, P_START_LO = 3'd1, P_START_HI = 3'd2,
                 P_CNT_LO = 3'd3, P_CNT_HI = 3'd4, P_ENTRY = 3'd5, P_CRC = 3'd6;

reg  [2:0]  ps;
reg         pal_valid;
reg  [7:0]  pal_byte;
reg  [15:0] pal_start, pal_count, pal_ent;
reg  [1:0]  pal_b;                  // byte within an entry, or within the CRC
reg  [7:0]  pal_r, pal_g;
reg  [31:0] pal_crc;                // running CRC over start, count and entries
reg  [31:0] pal_rx;                 // the CRC as it arrives
reg  [31:0] palettes;

// ------------------------------------------------------------------ tiles ----
// Command 0x1D.  Nine header bytes, then the block, then four CRC bytes.  The
// header is checked before the data is taken: a block that is not whole words,
// or that would run past the end of the tile, is refused while its payload is
// still arriving, which is what the image loader does with a bad header too.
localparam [3:0] T_IDLE = 4'd0, T_LEVEL = 4'd1, T_TX_LO = 4'd2, T_TX_HI = 4'd3,
                 T_TY_LO = 4'd4, T_TY_HI = 4'd5, T_OFF_LO = 4'd6, T_OFF_HI = 4'd7,
                 T_CNT_LO = 4'd8, T_CNT_HI = 4'd9, T_DATA = 4'd10,
                 T_CRC = 4'd11, T_FIN = 4'd12;

reg  [3:0]  ts;
reg         tile_valid;
reg  [7:0]  tile_byte;
reg  [1:0]  t_level;
reg  [14:0] t_tx, t_ty;
reg  [15:0] t_off, t_count, t_left;
reg  [2:0]  t_wc;                   // bytes gathered into the current word
reg  [2:0]  t_b;                    // byte within the CRC
reg  [31:0] t_crc;                  // running CRC over the header and the data
reg  [31:0] t_rx;                   // the CRC as it arrives
reg  [63:0] t_wbuf;
reg  [24:0] t_addr;
reg         t_last;                 // this block ends the tile
reg         t_commit_pending;
reg         t_ovf;                  // a word was lost to a busy write port
reg  [31:0] tiles;
reg         m_got;                  // a 0x1E byte has arrived
reg  [7:0]  m_byte;

// the block's count as it is being received, the last header byte included
wire [15:0] t_cnt_n = {tile_byte, t_count[7:0]};
localparam [16:0] TB_MAX = TBYTES;

function automatic [16:0] blk_end(input [15:0] off, input [15:0] cnt);
    blk_end = {1'b0, off} + {1'b0, cnt};
endfunction

// ---------------------------------------------------------------- status ----
reg        ss_active;
reg [4:0]  ss_i;
reg [4:0]  ss_wait;

// the base is twenty-five bits, and a byte taken from it has to be zero-extended
// or the top byte reads out of range: the status command reported 0xafaee3d8 for
// a base of 0x01aee3d8 until the pool's addresses passed sixteen megabytes
wire [31:0] st_base32 = {7'd0, st_base};

wire [7:0] ss_byte =
    (ss_i <  5'd4)  ? st_base32[8*ss_i[1:0] +: 8] :
    (ss_i == 5'd4)  ? st_w[7:0] :
    (ss_i == 5'd5)  ? st_w[15:8] :
    (ss_i == 5'd6)  ? st_h[7:0] :
    (ss_i == 5'd7)  ? st_h[15:8] :
    (ss_i <  5'd12) ? st_step[8*(ss_i - 5'd8) +: 8] :
    (ss_i <  5'd16) ? st_x0[8*(ss_i - 5'd12) +: 8] :
    (ss_i <  5'd20) ? st_y0[8*(ss_i - 5'd16) +: 8] :
    (ss_i == 5'd20) ? {5'd0, st_rstate} :
    (ss_i == 5'd21) ? {7'd0, stream_on} :
                      req_depth;

// --------------------------------------------------------------- viewport ----
// Command 0x0A.  Twenty bytes of body then its CRC, walked a byte at a time.
localparam [1:0] V_IDLE = 2'd0, V_BODY = 2'd1, V_CRC = 2'd2;

reg  [1:0]  vs;
reg         vp_valid;
reg  [7:0]  vp_byte;
reg  [4:0]  vb;                     // byte within the payload
reg  [31:0] vw;                     // the word being assembled
reg  [31:0] v_base, v_wh, v_step, v_x0, v_y0;
reg  [31:0] v_crc, v_rx;
reg  [31:0] viewports;

// The step guard, and the level's room in the SDRAM, checked before anything is
// latched: 0.5 < step <= 1.0, a level that is not empty, and a level that fits.
//
// Registered in two stages, because computed in one it is a 16x16 multiply and a
// 32-bit add in the same cone, and that alone took the pixel clock from 93 MHz
// to 57.  The bytes settle four clocks before the decision, so the pipeline has
// all the time it needs; the command is stop-and-wait and answered once.
wire [31:0] v_size = {16'd0, v_wh[15:0]} * {16'd0, v_wh[31:16]};
reg  [31:0] v_size_q;
reg         vp_ok_q;

always @(posedge clk) begin
    v_size_q <= v_size;
    vp_ok_q  <= (v_step > 32'h0000_4000) && (v_step <= 32'h0001_0000) &&
                (v_wh[15:0] != 16'd0) && (v_wh[31:16] != 16'd0) &&
                ({7'd0, v_base} + v_size_q <= 32'h0200_0000);
end

// ----------------------------------------------------------- level table ----
// Command 0x0B.  A count byte, then eight bytes a level, then the CRC.
localparam [1:0] L_IDLE = 2'd0, L_BODY = 2'd1, L_CRC = 2'd2;

reg  [1:0]  ls;
reg         lv_en;
reg  [7:0]  lv_byte;
reg  [7:0]  lv_cnt;                 // bytes seen
reg  [2:0]  lv_n;                   // levels the sender promised, 0 means 4
reg  [7:0]  rb0, rb1, rb2, rb3, rb4, rb5, rb6, rb7;
reg  [31:0] l_crc, l_rx;
reg  [24:0] lvb0, lvb1, lvb2, lvb3;
reg  [15:0] lvw0, lvw1, lvw2, lvw3;
reg  [15:0] lvh0, lvh1, lvh2, lvh3;

// --------------------------------------------------------------- buttons ----
// Commands 0x16 and 0x17: the board's mouse and keyboard, unanswered.  The
// mouse report is ff ff buttons dx dy wheel; the keyboard is the HID boot
// report, a modifier and six usage codes.
localparam [1:0] I_IDLE = 2'd0, I_MOUSE = 2'd1, I_KEY = 2'd2;
localparam signed [15:0] KEY_PAN = 16'sd64;

reg  [1:0]  is;
reg         in_en;
reg  [7:0]  in_byte;
reg  [2:0]  in_cnt;
integer     k;
reg  [7:0]  in_b0, in_b1, in_b2, in_b3, in_b4, in_b5, in_b6;
reg  signed [15:0] key_px, key_py;
reg  signed [1:0]  key_zoom;

// The table the zoom crosses with.  These were declared as outputs and never
// assigned, which left the table zero: a width of zero makes every row address
// the same address, so the renderer drew one line and repeated it down the
// frame, and a pan -- which reads the table -- produced exactly that.
assign lv_base0 = lvb0; assign lv_base1 = lvb1;
assign lv_base2 = lvb2; assign lv_base3 = lvb3;
assign lv_w0 = lvw0; assign lv_w1 = lvw1; assign lv_w2 = lvw2; assign lv_w3 = lvw3;
assign lv_h0 = lvh0; assign lv_h1 = lvh1; assign lv_h2 = lvh2; assign lv_h3 = lvh3;

// Which level record the byte belongs to, and which byte within it.
wire [1:0]  lrec = (lv_cnt - 8'd1) >> 3;

// The seven usages of the keyboard report, newest byte first.
wire [55:0] usages = {in_b6, in_b5, in_b4, in_b3, in_b2, in_b1, in_byte};

// ----------------------------------------------------------------- loader ----
localparam [3:0] S_MAGIC = 4'd0, S_ADDR = 4'd1, S_LEN  = 4'd2, S_ICRC = 4'd3,
                 S_HCRC  = 4'd4, S_BLK  = 4'd5, S_BCRC = 4'd6, S_ICMP = 4'd7,
                 S_TX    = 4'd8;

reg [3:0]  st, after_tx;
reg [1:0]  bidx, cidx;
reg [31:0] word;
reg [31:0] img_addr, img_len, img_left, blk_left, blk_size, blk_addr;
reg [31:0] img_crc, img_crc_mark, blk_crc, hdr_crc, exp_crc;
reg [63:0] wbuf;
reg [2:0]  wbytes;
reg [31:0] waddr;
reg        wr_pending;
reg        tail_pending;

reg [7:0]  tx_b0, tx_b1;
reg        tx_two;
reg [1:0]  tx_step;
reg        tx_i;

reg [19:0] idle_cnt;

wire [31:0] n_img_crc = crc32_byte(img_crc, pl_data);
wire [31:0] n_blk_crc = crc32_byte(blk_crc, pl_data);
wire [31:0] n_hdr_crc = crc32_byte(hdr_crc, pl_data);
wire [63:0] n_wbuf    = {pl_data, wbuf[63:8]};
wire [31:0] word_next = {pl_data, word[31:8]};

// A byte in a data state is consumed in the cycle it is presented.  The link is
// two orders of magnitude slower than this logic, so no back-pressure is
// needed; a write still outstanding when a word completes is counted instead of
// being allowed to corrupt the image.
wire take = pl_valid && (st == S_MAGIC || st == S_ADDR || st == S_LEN ||
                         st == S_ICRC  || st == S_HCRC || st == S_BLK  ||
                         st == S_BCRC);

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        fs <= F_IDLE; flen <= 16'd0; fcmd <= 8'd0; fleft <= 12'd0;
        pl_valid <= 1'b0; pl_data <= 8'd0;
        ps <= P_IDLE; pal_valid <= 1'b0; pal_byte <= 8'd0;
        pal_start <= 16'd0; pal_count <= 16'd0; pal_ent <= 16'd0;
        pal_b <= 2'd0; pal_r <= 8'd0; pal_g <= 8'd0;
        pal_crc <= 32'hFFFFFFFF; pal_rx <= 32'd0; palettes <= 32'd0;
        pal_we <= 1'b0; pal_idx <= 8'd0; pal_data <= 24'd0;
        ts <= T_IDLE; tile_valid <= 1'b0; tile_byte <= 8'd0;
        t_level <= 2'd0; t_tx <= 15'd0; t_ty <= 15'd0;
        t_off <= 16'd0; t_count <= 16'd0; t_left <= 16'd0;
        t_wc <= 3'd0; t_b <= 3'd0; t_crc <= 32'hFFFFFFFF; t_rx <= 32'd0;
        t_wbuf <= 64'd0; t_addr <= 25'd0; t_last <= 1'b0;
        t_commit_pending <= 1'b0; t_ovf <= 1'b0; tiles <= 32'd0;
        fill_level <= 2'd0; fill_tx <= 15'd0; fill_ty <= 15'd0;
        fill_commit <= 1'b0;
        stream_on <= 1'b0; m_got <= 1'b0; m_byte <= 8'd0;
        vs <= V_IDLE; vp_valid <= 1'b0; vp_byte <= 8'd0; vb <= 5'd0;
        vw <= 32'd0; v_base <= 32'd0; v_wh <= 32'd0; v_step <= 32'd0;
        v_x0 <= 32'd0; v_y0 <= 32'd0; v_crc <= 32'hFFFFFFFF; v_rx <= 32'd0;
        viewports <= 32'd0; vp_we <= 1'b0;
        vp_base <= 25'd0; vp_w <= 16'd768; vp_h <= 16'd768;
        vp_step <= 32'd39322; vp_x0 <= 32'sd0; vp_y0 <= 32'sd0;
        ls <= L_IDLE; lv_en <= 1'b0; lv_byte <= 8'd0; lv_cnt <= 8'd0;
        lv_n <= 3'd0; l_crc <= 32'hFFFFFFFF; l_rx <= 32'd0;
        lv_valid <= 4'd0;
        lvb0 <= 25'd0; lvb1 <= 25'd0; lvb2 <= 25'd0; lvb3 <= 25'd0;
        lvw0 <= 16'd0; lvw1 <= 16'd0; lvw2 <= 16'd0; lvw3 <= 16'd0;
        lvh0 <= 16'd0; lvh1 <= 16'd0; lvh2 <= 16'd0; lvh3 <= 16'd0;
        is <= I_IDLE; in_en <= 1'b0; in_byte <= 8'd0; in_cnt <= 3'd0;
        in_b0 <= 8'd0; in_b1 <= 8'd0; in_b2 <= 8'd0; in_b3 <= 8'd0;
        in_b4 <= 8'd0; in_b5 <= 8'd0; in_b6 <= 8'd0;
        key_px <= 16'sd0; key_py <= 16'sd0; key_zoom <= 2'sd0;
        nav_ev <= 1'b0; nav_px <= 16'sd0; nav_py <= 16'sd0; nav_zoom <= 2'sd0;
        ss_active <= 1'b0; ss_i <= 5'd0; ss_wait <= 5'd0;
        st <= S_MAGIC; after_tx <= S_MAGIC;
        bidx <= 2'd0; cidx <= 2'd0; word <= 32'd0;
        img_addr <= 32'd0; img_len <= 32'd0; img_left <= 32'd0;
        blk_left <= 32'd0; blk_size <= 32'd0; blk_addr <= 32'd0;
        img_crc <= 32'hFFFFFFFF; img_crc_mark <= 32'hFFFFFFFF;
        blk_crc <= 32'hFFFFFFFF;
        hdr_crc <= 32'hFFFFFFFF; exp_crc <= 32'd0;
        wbuf <= 64'd0; wbytes <= 3'd0; waddr <= 32'd0;
        wr_pending <= 1'b0; tail_pending <= 1'b0;
        wr_req <= 1'b0; wr_addr <= 21'd0; wr_lanes <= 8'd0; wr_wdata <= 64'd0;
        tx_start <= 1'b0; tx_data <= 8'd0; tx_b0 <= 8'd0; tx_b1 <= 8'd0;
        tx_two <= 1'b0; tx_step <= 2'd0; tx_i <= 1'b0;
        busy <= 1'b0; images <= 32'd0; bytes_written <= 32'd0;
        last_nak <= 8'd0; overflows <= 16'd0; timeouts <= 16'd0;
        idle_cnt <= 20'd0;
    end else begin
        pl_valid <= 1'b0;
        pal_valid <= 1'b0;
        tile_valid <= 1'b0;
        fill_commit <= 1'b0;
        pal_we <= 1'b0;
        vp_valid <= 1'b0;
        vp_we <= 1'b0;
        lv_en <= 1'b0;
        in_en <= 1'b0;
        nav_ev <= 1'b0;
        tx_start <= 1'b0;

        // ---------------------------------------------------- frame parser --
        if (rx_valid) begin
            idle_cnt <= 20'd0;
            case (fs)
                F_IDLE: if (rx_data == 8'hAA) fs <= F_LENH;
                F_LENH: if (rx_data < 8) begin
                            flen[15:8] <= rx_data; fs <= F_LENL;
                        end else fs <= F_IDLE;
                F_LENL: begin flen[7:0] <= rx_data; fs <= F_CMD; end
                F_CMD:  if (flen > 16'd1) begin
                            fcmd  <= rx_data;
                            fleft <= flen[11:0] - 12'd1;
                            fs    <= F_DATA;
                            if (rx_data == 8'h0B) begin
                                ls <= L_BODY;
                                lv_cnt <= 8'd0;

                                l_crc <= 32'hFFFFFFFF;
                                l_rx <= 32'd0;
                                lv_valid <= 4'd0;
                            end
                            if (rx_data == 8'h0C) begin
                                ss_active <= 1'b1;
                                ss_i      <= 5'd0;
                            end
                            if (rx_data == 8'h16) is <= I_MOUSE;
                            if (rx_data == 8'h17) is <= I_KEY;
                            if (rx_data == 8'h1D && TILES) begin
                                ts      <= T_LEVEL;
                                t_crc   <= 32'hFFFFFFFF;
                                t_ovf   <= 1'b0;
                                t_wc    <= 3'd0;
                                t_wbuf  <= 64'd0;
                            end
                            if (rx_data == 8'h16 || rx_data == 8'h17) in_cnt <= 3'd0;
                            if (rx_data == 8'h0A) begin
                                vs <= V_BODY;
                                vb <= 5'd0;
                                vw <= 32'd0;
                                v_crc <= 32'hFFFFFFFF;
                                v_rx <= 32'd0;
                            end
                            if (rx_data == 8'h08) begin
                                ps      <= P_START_LO;
                                pal_ent <= 16'd0;
                                pal_b   <= 2'd0;
                                pal_crc <= 32'hFFFFFFFF;
                                pal_rx  <= 32'd0;
                            end
                        end else fs <= F_IDLE;
                F_DATA: begin
                            if (fcmd == 8'h07) begin
                                pl_valid <= 1'b1;
                                pl_data  <= rx_data;
                            end else if (fcmd == 8'h08) begin
                                pal_valid <= 1'b1;
                                pal_byte  <= rx_data;
                            end else if (fcmd == 8'h0A) begin
                                vp_valid <= 1'b1;
                                vp_byte  <= rx_data;
                            end else if (fcmd == 8'h0B) begin
                                lv_en   <= 1'b1;
                                lv_byte <= rx_data;
                            end else if (fcmd == 8'h16 || fcmd == 8'h17) begin
                                in_en   <= 1'b1;
                                in_byte <= rx_data;
                            end else if (fcmd == 8'h1D && TILES) begin
                                tile_valid <= 1'b1;
                                tile_byte  <= rx_data;
                            end else if (fcmd == 8'h1E) begin
                                m_byte <= rx_data;
                                m_got  <= 1'b1;
                            end
                            if (fleft == 12'd1) fs <= F_IDLE;
                            else fleft <= fleft - 12'd1;
                        end
                default: fs <= F_IDLE;
            endcase
        end else if (fs != F_IDLE) begin
            if (idle_cnt != 20'hFFFFF) idle_cnt <= idle_cnt + 20'd1;
            else begin
                fs <= F_IDLE;
                if (busy) begin
                    timeouts <= timeouts + 16'd1;
                    last_nak <= "T";
                    tx_b0 <= NAK; tx_b1 <= "T"; tx_two <= 1'b1;
                    tx_step <= 2'd0; tx_i <= 1'b0;
                    after_tx <= S_MAGIC; st <= S_TX;
                    busy <= 1'b0;
                end
            end
        end

        // -------------------------------------------------------- palette --
        // Entries are written as their third byte arrives, so the table is
        // updated a cycle after each triple rather than at the end.  The reply
        // borrows the loader's sender: a palette command and an image transfer
        // cannot be in flight together, because the host is stop-and-wait.
        if (pal_valid) begin
            case (ps)
                P_START_LO: begin
                    pal_start[7:0] <= pal_byte;
                    pal_crc <= crc32_byte(pal_crc, pal_byte);
                    ps <= P_START_HI;
                end
                P_START_HI: begin
                    pal_start[15:8] <= pal_byte;
                    pal_crc <= crc32_byte(pal_crc, pal_byte);
                    ps <= P_CNT_LO;
                end
                P_CNT_LO: begin
                    pal_count[7:0] <= pal_byte;
                    pal_crc <= crc32_byte(pal_crc, pal_byte);
                    ps <= P_CNT_HI;
                end
                P_CNT_HI: begin
                    pal_count[15:8] <= pal_byte;
                    pal_crc <= crc32_byte(pal_crc, pal_byte);
                    pal_b  <= 2'd0;
                    ps <= ({pal_byte, pal_count[7:0]} == 16'd0) ? P_CRC : P_ENTRY;
                end
                P_ENTRY: begin
                    pal_crc <= crc32_byte(pal_crc, pal_byte);
                    case (pal_b)
                        2'd0: begin pal_r <= pal_byte; pal_b <= 2'd1; end
                        2'd1: begin pal_g <= pal_byte; pal_b <= 2'd2; end
                        default: begin
                            pal_we   <= 1'b1;
                            pal_idx  <= pal_start[7:0] + pal_ent[7:0];
                            pal_data <= {pal_r, pal_g, pal_byte};
                            pal_b    <= 2'd0;
                            pal_ent  <= pal_ent + 16'd1;
                            if (pal_ent + 16'd1 >= pal_count) ps <= P_CRC;
                        end
                    endcase
                end
                P_CRC: begin
                    pal_rx[8*pal_b +: 8] <= pal_byte;
                    pal_b <= pal_b + 2'd1;
                    if (pal_b == 2'd3) begin
                        if (~pal_crc == {pal_byte, pal_rx[23:0]}) begin
                            palettes <= palettes + 32'd1;
                            tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
                        end else begin
                            last_nak <= "P";
                            tx_b0 <= NAK; tx_b1 <= "P"; tx_two <= 1'b1;
                        end
                        tx_step  <= 2'd0;
                        tx_i     <= 1'b0;
                        after_tx <= S_MAGIC;
                        st       <= S_TX;
                        ps       <= P_IDLE;
                    end
                end
                default: ps <= P_IDLE;
            endcase
        end

        // ------------------------------------------------------- picture source --
        if (m_got) begin
            m_got     <= 1'b0;
            stream_on <= m_byte[0];
            tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
            tx_step <= 2'd0; tx_i <= 1'b0;
            after_tx <= S_MAGIC; st <= S_TX;
        end

        // ---------------------------------------------------------- tiles --
        // Command 0x1D, one block of one tile.  The header is checked before a
        // byte of it is written, and the write goes to the slot the page table
        // derives from the coordinates -- the host never names an address.
        if (tile_valid) begin
            case (ts)
                T_LEVEL: begin
                    fill_level <= tile_byte[1:0];
                    t_crc      <= crc32_byte(t_crc, tile_byte);
                    ts         <= T_TX_LO;
                end
                T_TX_LO: begin
                    t_tx[7:0] <= tile_byte;
                    t_crc     <= crc32_byte(t_crc, tile_byte);
                    ts        <= T_TX_HI;
                end
                T_TX_HI: begin
                    t_tx[14:8] <= tile_byte[6:0];
                    fill_tx    <= {tile_byte[6:0], t_tx[7:0]};
                    t_crc      <= crc32_byte(t_crc, tile_byte);
                    ts         <= T_TY_LO;
                end
                T_TY_LO: begin
                    t_ty[7:0] <= tile_byte;
                    t_crc     <= crc32_byte(t_crc, tile_byte);
                    ts        <= T_TY_HI;
                end
                T_TY_HI: begin
                    t_ty[14:8] <= tile_byte[6:0];
                    fill_ty    <= {tile_byte[6:0], t_ty[7:0]};
                    t_crc      <= crc32_byte(t_crc, tile_byte);
                    ts         <= T_OFF_LO;
                end
                T_OFF_LO: begin
                    t_off[7:0] <= tile_byte;
                    t_crc      <= crc32_byte(t_crc, tile_byte);
                    ts         <= T_OFF_HI;
                end
                T_OFF_HI: begin
                    t_off[15:8] <= tile_byte;
                    t_crc       <= crc32_byte(t_crc, tile_byte);
                    ts          <= T_CNT_LO;
                end
                T_CNT_LO: begin
                    t_count[7:0] <= tile_byte;
                    t_crc        <= crc32_byte(t_crc, tile_byte);
                    ts           <= T_CNT_HI;
                end
                // the last header byte decides the whole block: whole words,
                // inside the tile, and something to write
                T_CNT_HI: begin
                    t_crc <= crc32_byte(t_crc, tile_byte);
                    if (t_cnt_n == 16'd0 || t_cnt_n[2:0] != 3'd0 ||
                        t_off[2:0] != 3'd0 ||
                        blk_end(t_off, t_cnt_n) > TB_MAX) begin
                        last_nak <= "D";
                        tx_b0 <= NAK; tx_b1 <= "D"; tx_two <= 1'b1;
                        tx_step <= 2'd0; tx_i <= 1'b0;
                        after_tx <= S_MAGIC; st <= S_TX;
                        ts <= T_IDLE;
                    end else begin
                        t_left  <= t_cnt_n;
                        t_addr  <= fill_addr + {9'd0, t_off};
                        t_last  <= (blk_end(t_off, t_cnt_n) == TB_MAX);
                        t_wc    <= 3'd0;
                        t_wbuf  <= 64'd0;
                        ts      <= T_DATA;
                    end
                end
                // eight bytes make a word, and every word is whole: the block's
                // offset and count are both multiples of eight, so there is no
                // lane mask and no tail
                T_DATA: begin
                    t_crc  <= crc32_byte(t_crc, tile_byte);
                    t_wbuf <= {tile_byte, t_wbuf[63:8]};
                    t_left <= t_left - 16'd1;
                    if (t_wc == 3'd7) begin
                        t_wc <= 3'd0;
                        t_addr <= t_addr + 25'd8;
                        if (wr_pending || tail_pending) begin
                            // the port is still busy: this word is lost, so the
                            // block cannot be committed.  The host re-sends it
                            t_ovf <= 1'b1;
                            overflows <= overflows + 16'd1;
                        end else begin
                            wr_req     <= 1'b1;
                            wr_addr    <= t_addr[24:3];
                            wr_lanes   <= 8'hFF;
                            wr_wdata   <= {tile_byte, t_wbuf[63:8]};
                            wr_pending <= 1'b1;
                        end
                    end else begin
                        t_wc <= t_wc + 3'd1;
                    end
                    if (t_left == 16'd1) begin
                        t_b  <= 3'd0;
                        t_rx <= 32'd0;
                        ts   <= T_CRC;
                    end
                end
                T_CRC: begin
                    t_rx[8*t_b +: 8] <= tile_byte;
                    if (t_b == 3'd3) begin
                        if (~t_crc == {tile_byte, t_rx[23:0]} && !t_ovf) begin
                            t_commit_pending <= t_last;
                            ts <= T_FIN;
                        end else begin
                            last_nak <= "D";
                            tx_b0 <= NAK; tx_b1 <= "D"; tx_two <= 1'b1;
                            tx_step <= 2'd0; tx_i <= 1'b0;
                            after_tx <= S_MAGIC; st <= S_TX;
                            ts <= T_IDLE;
                        end
                    end else begin
                        t_b <= t_b + 3'd1;
                    end
                end
                default: ts <= T_IDLE;
            endcase
        end

        // The finish is a wait, not a byte: the last byte of the block has
        // already gone by the time it is entered, so it cannot live inside the
        // per-byte guard above or nothing would ever run it.  Nothing is
        // answered, and no tile is made resident, until every write this block
        // caused has been acknowledged -- a tile marked resident while half of
        // it is still in the port is a hit on somebody else's picture.
        if (ts == T_FIN && !wr_pending && !tail_pending) begin
            fill_commit <= t_commit_pending;
            if (t_commit_pending) tiles <= tiles + 32'd1;
            t_commit_pending <= 1'b0;
            tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
            tx_step <= 2'd0; tx_i <= 1'b0;
            after_tx <= S_MAGIC; st <= S_TX;
            ts <= T_IDLE;
        end

        // --------------------------------------------------------- status ----
        // One byte at a time through the same sender the replies use: hold
        // tx_start until the transmitter takes it, then wait for it to finish.
        if (ss_active) begin
            if (ss_wait == 5'd0) begin
                tx_data  <= ss_byte;
                tx_start <= 1'b1;
                ss_wait  <= 5'd1;
            end else if (ss_wait == 5'd1) begin
                tx_start <= 1'b0;
                ss_wait  <= 5'd2;
            end else if (!tx_busy) begin
                ss_wait <= 5'd0;
                ss_i    <= ss_i + 5'd1;
                if (ss_i == 5'd22) ss_active <= 1'b0;
            end
        end

        // ---------------------------------------------------- level table --
        if (lv_en) begin
            case (ls)
                L_BODY: begin
                    l_crc <= crc32_byte(l_crc, lv_byte);
                    if (lv_cnt == 8'd0) begin
                        lv_n  <= lv_byte[2:0];
                        lv_cnt <= 8'd1;
                    end else begin
                        // Hold the record's eight bytes, then take the fields
                        // out by name.  Reading sixteen-bit halves out of a
                        // word that had only shifted twice is what put the
                        // width in the height and a 1 into the table.
                        case ((lv_cnt - 8'd1) & 8'd7)
                            3'd0: rb0 <= lv_byte;
                            3'd1: rb1 <= lv_byte;
                            3'd2: rb2 <= lv_byte;
                            3'd3: rb3 <= lv_byte;
                            3'd4: rb4 <= lv_byte;
                            3'd5: rb5 <= lv_byte;
                            3'd6: rb6 <= lv_byte;
                            default: rb7 <= lv_byte;
                        endcase
                        if (((lv_cnt - 8'd1) & 8'd7) == 8'd7) begin
                            case (lrec)
                                2'd0: begin lvb0 <= {rb3, rb2, rb1, rb0}; lvw0 <= {rb5, rb4}; lvh0 <= {lv_byte, rb6}; end
                                2'd1: begin lvb1 <= {rb3, rb2, rb1, rb0}; lvw1 <= {rb5, rb4}; lvh1 <= {lv_byte, rb6}; end
                                2'd2: begin lvb2 <= {rb3, rb2, rb1, rb0}; lvw2 <= {rb5, rb4}; lvh2 <= {lv_byte, rb6}; end
                                default: begin lvb3 <= {rb3, rb2, rb1, rb0}; lvw3 <= {rb5, rb4}; lvh3 <= {lv_byte, rb6}; end
                            endcase
                            lv_valid <= lv_valid | (4'd1 << lrec);
                        end
                        lv_cnt <= lv_cnt + 8'd1;
                        if (lv_cnt == ({5'd0, lv_n} << 3)) begin
                            ls     <= L_CRC;
                            lv_cnt <= 8'd0;
                        end
                    end
                end
                L_CRC: begin
                    l_rx[8*lv_cnt[1:0] +: 8] <= lv_byte;
                    lv_cnt <= lv_cnt + 8'd1;
                    if (lv_cnt[1:0] == 2'd3) begin
                        if (~l_crc != {lv_byte, l_rx[23:0]}) begin
                            last_nak <= "L";
                            tx_b0 <= NAK; tx_b1 <= "L"; tx_two <= 1'b1;
                        end else begin
                            tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
                        end
                        tx_step <= 2'd0; tx_i <= 1'b0; after_tx <= S_MAGIC;
                        st <= S_TX; ls <= L_IDLE;
                    end
                end
                default: ls <= L_IDLE;
            endcase
        end

        // ------------------------------------------------------- buttons ----
        if (in_en) begin
            case (is)
                I_MOUSE: begin
                    case (in_cnt)
                        3'd0: in_b0 <= in_byte;
                        3'd1: in_b1 <= in_byte;
                        3'd2: in_b2 <= in_byte;
                        3'd3: nav_px <= {{8{in_byte[7]}}, in_byte};
                        3'd4: nav_py <= {{8{in_byte[7]}}, in_byte};
                        default: begin
                            nav_zoom <= in_byte[7] ? 2'sd1 : (in_byte[6:0] != 7'd0 ? -2'sd1 : 2'sd0);
                            nav_btn  <= in_b2[2:0];
                            nav_mouse <= 1'b1;
                            nav_ev   <= 1'b1;
                        end
                    endcase
                    if (in_cnt != 3'd5) in_cnt <= in_cnt + 3'd1;
                    else is <= I_IDLE;
                end
                I_KEY: begin
                    if (in_cnt == 3'd6) begin
                        nav_px <= 16'sd0; nav_py <= 16'sd0; nav_zoom <= 2'sd0;
                        for (k = 0; k < 7; k = k + 1) begin
                            case (usages[8*k +: 8])
                                8'h50: nav_px <= -KEY_PAN;      // left
                                8'h4F: nav_px <= KEY_PAN;       // right
                                8'h52: nav_py <= -KEY_PAN;      // up
                                8'h51: nav_py <= KEY_PAN;       // down
                                8'h2E: nav_zoom <= -2'sd1;      // '=' zoom in
                                8'h2D: nav_zoom <= 2'sd1;       // '-' zoom out
                                default: ;
                            endcase
                        end
                        nav_mouse <= 1'b0;
                        nav_ev <= 1'b1;
                        is <= I_IDLE;
                    end else begin
                        case (in_cnt)
                            3'd0: in_b0 <= in_byte;
                            3'd1: in_b1 <= in_byte;
                            3'd2: in_b2 <= in_byte;
                            3'd3: in_b3 <= in_byte;
                            3'd4: in_b4 <= in_byte;
                            default: in_b5 <= in_byte;
                        endcase
                        in_cnt <= in_cnt + 3'd1;
                    end
                end
                default: is <= I_IDLE;
            endcase
        end

        // ------------------------------------------------------- viewport --
        // Twenty bytes of body, then the CRC.  Nothing is latched until the CRC
        // matches and the guard accepts it, so a refused command leaves the
        // picture exactly as it was.
        if (vp_valid) begin
            case (vs)
                V_BODY: begin
                    vw    <= {vp_byte, vw[31:8]};        // little-endian
                    v_crc <= crc32_byte(v_crc, vp_byte);
                    if (vb[1:0] == 2'd3) begin
                        case (vb[4:2])
                            3'd0: v_base <= {vp_byte, vw[31:8]};
                            3'd1: v_wh   <= {vp_byte, vw[31:8]};
                            3'd2: v_step <= {vp_byte, vw[31:8]};
                            3'd3: v_x0   <= {vp_byte, vw[31:8]};
                            3'd4: v_y0   <= {vp_byte, vw[31:8]};
                            default: ;
                        endcase
                    end
                    vb <= vb + 5'd1;
                    if (vb == 5'd19) vs <= V_CRC;
                end
                V_CRC: begin
                    v_rx[8*vb[1:0] +: 8] <= vp_byte;
                    vb <= vb + 5'd1;
                    if (vb[1:0] == 2'd3) begin
                        if (~v_crc != {vp_byte, v_rx[23:0]}) begin
                            last_nak <= "C";
                            tx_b0 <= NAK; tx_b1 <= "C"; tx_two <= 1'b1;
                        end else if (vp_ok_q) begin
                            vp_we   <= 1'b1;
                            vp_base <= v_base[24:0];
                            vp_w    <= v_wh[15:0];
                            vp_h    <= v_wh[31:16];
                            vp_step <= v_step;
                            vp_x0   <= v_x0;
                            vp_y0   <= v_y0;
                            viewports <= viewports + 32'd1;
                            tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
                        end else begin
                            last_nak <= "V";
                            tx_b0 <= NAK; tx_b1 <= "V"; tx_two <= 1'b1;
                        end
                        tx_step  <= 2'd0;
                        tx_i     <= 1'b0;
                        after_tx <= S_MAGIC;
                        st       <= S_TX;
                        vs       <= V_IDLE;
                    end
                end
                default: vs <= V_IDLE;
            endcase
        end

        // Write port acknowledge.  Held until ack, which ahb_sdram pulses as
        // soon as it accepts the transfer.
        if (wr_pending && wr_ack) begin
            wr_req <= 1'b0; wr_pending <= 1'b0;
        end
        if (tail_pending && !wr_pending) begin
            wr_req   <= 1'b1;
            wr_addr  <= waddr[24:3];
            wr_lanes <= (8'h01 << wbytes) - 8'h01;
            wr_wdata <= wbuf;
            wr_pending <= 1'b1;
            tail_pending <= 1'b0;
            wbytes <= 3'd0;
            wbuf   <= 64'd0;
            waddr  <= waddr + 32'd8;
        end

        // --------------------------------------------------------- loader --
        case (st)
        S_MAGIC: if (take) begin
            if (bidx == 2'd3) begin
                bidx <= 2'd0;
                word <= 32'd0;
                if (word_next == MAGIC) begin
                    hdr_crc <= n_hdr_crc;
                    st <= S_ADDR;
                end else begin
                    hdr_crc <= 32'hFFFFFFFF;      // not a header; keep hunting
                end
            end else begin
                bidx <= bidx + 2'd1;
                word <= word_next;
                hdr_crc <= n_hdr_crc;
            end
        end

        S_ADDR: if (take) begin
            hdr_crc <= n_hdr_crc;
            if (bidx == 2'd3) begin
                bidx <= 2'd0; img_addr <= word_next; word <= 32'd0; st <= S_LEN;
            end else begin bidx <= bidx + 2'd1; word <= word_next; end
        end

        S_LEN: if (take) begin
            hdr_crc <= n_hdr_crc;
            if (bidx == 2'd3) begin
                bidx <= 2'd0; img_len <= word_next; word <= 32'd0; st <= S_ICRC;
            end else begin bidx <= bidx + 2'd1; word <= word_next; end
        end

        S_ICRC: if (take) begin
            hdr_crc <= n_hdr_crc;
            if (bidx == 2'd3) begin
                bidx <= 2'd0; exp_crc <= word_next; word <= 32'd0; st <= S_HCRC;
            end else begin bidx <= bidx + 2'd1; word <= word_next; end
        end

        // The header CRC covers the four words above and excludes its own field.
        S_HCRC: if (take && bidx != 2'd3) begin
            bidx <= bidx + 2'd1; word <= word_next;
        end else if (take) begin
            bidx <= 2'd0; word <= 32'd0;
            // the running header CRC starts again with the next header
            hdr_crc <= 32'hFFFFFFFF;
            if (word_next == ~hdr_crc && img_addr[2:0] == 3'd0) begin
                waddr <= img_addr; wbytes <= 3'd0; wbuf <= 64'd0;
                blk_addr <= img_addr;
                img_left <= img_len;
                blk_size <= (img_len > BLOCK_BYTES) ? BLOCK_BYTES[31:0] : img_len;
                blk_left <= (img_len > BLOCK_BYTES) ? BLOCK_BYTES[31:0] : img_len;
                blk_crc  <= 32'hFFFFFFFF;
                img_crc  <= 32'hFFFFFFFF;
                img_crc_mark <= 32'hFFFFFFFF;
                busy <= 1'b1;
                tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
                tx_step <= 2'd0; tx_i <= 1'b0; after_tx <= S_BLK; st <= S_TX;
                if (img_len == 32'd0) begin after_tx <= S_ICMP; end
            end else begin
                last_nak <= "H";
                tx_b0 <= NAK; tx_b1 <= "H"; tx_two <= 1'b1;
                tx_step <= 2'd0; tx_i <= 1'b0; after_tx <= S_MAGIC; st <= S_TX;
            end
        end

        S_BLK: if (take) begin
            blk_crc <= n_blk_crc;
            img_crc <= n_img_crc;
            bytes_written <= bytes_written + 32'd1;
            img_left <= img_left - 32'd1;
            blk_left <= blk_left - 32'd1;
            if (wbytes == 3'd7) begin
                if (wr_pending) overflows <= overflows + 16'd1;
                wr_req   <= 1'b1;
                wr_addr  <= waddr[24:3];
                wr_lanes <= 8'hFF;
                wr_wdata <= n_wbuf;
                wr_pending <= 1'b1;
                waddr <= waddr + 32'd8;
                wbuf  <= 64'd0;
                wbytes <= 3'd0;
            end else begin
                wbuf  <= n_wbuf;
                wbytes <= wbytes + 3'd1;
            end
            if (blk_left == 32'd1) begin
                st <= S_BCRC;
                cidx <= 2'd0;
                word <= 32'd0;
            end
        end

        S_BCRC: if (take) begin
            if (cidx == 2'd3) begin
                cidx <= 2'd0; word <= 32'd0;
                if (word_next == ~blk_crc) begin
                    tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
                    tx_step <= 2'd0; tx_i <= 1'b0;
                    if (img_left == 32'd0) begin
                        after_tx <= S_ICMP;
                        if (wbytes != 3'd0) tail_pending <= 1'b1;
                        st <= S_TX;
                    end else begin
                        blk_addr <= blk_addr + BLOCK_BYTES[31:0];
                        blk_size <= (img_left > BLOCK_BYTES) ? BLOCK_BYTES[31:0] : img_left;
                        blk_left <= (img_left > BLOCK_BYTES) ? BLOCK_BYTES[31:0] : img_left;
                        blk_crc  <= 32'hFFFFFFFF;
                        img_crc_mark <= img_crc;
                        after_tx <= S_BLK;
                        st <= S_TX;
                    end
                end else begin
                    last_nak <= "C";
                    // rewind to this block's start and take it again; the bytes
                    // already accepted here are given back to img_left
                    blk_left <= blk_size;
                    img_left <= img_left + blk_size;
                    // the re-sent block's bytes must not be counted twice
                    img_crc <= img_crc_mark;
                    waddr  <= blk_addr;
                    wbytes <= 3'd0;
                    wbuf   <= 64'd0;
                    blk_crc <= 32'hFFFFFFFF;
                    tx_b0 <= NAK; tx_b1 <= "C"; tx_two <= 1'b1;
                    tx_step <= 2'd0; tx_i <= 1'b0; after_tx <= S_BLK; st <= S_TX;
                end
            end else begin
                cidx <= cidx + 2'd1;
                word <= word_next;
            end
        end

        // The header carries the complemented image CRC, as TinyNES's does.
        S_ICMP: begin
            if (~img_crc == exp_crc) begin
                images <= images + 32'd1;
                tx_b0 <= ACK; tx_b1 <= 8'd0; tx_two <= 1'b0;
            end else begin
                last_nak <= "I";
                tx_b0 <= NAK; tx_b1 <= "I"; tx_two <= 1'b1;
            end
            tx_step <= 2'd0; tx_i <= 1'b0; after_tx <= S_MAGIC;
            busy <= 1'b0; st <= S_TX;
        end

        // Wait for the line before offering the byte: `tx_busy` includes the
        // tile request queue's hold, since the two share this transmitter, and a
        // reply that starts in the middle of a request frame corrupts both.
        S_TX: case (tx_step)
            2'd0: if (!tx_busy) begin
                tx_data <= tx_i ? tx_b1 : tx_b0;
                tx_start <= 1'b1;
                tx_step <= 2'd1;
            end
            2'd1: tx_step <= 2'd2;
            2'd2: if (!tx_busy) begin
                if (tx_two && !tx_i) begin tx_i <= 1'b1; tx_step <= 2'd0; end
                else begin tx_i <= 1'b0; st <= after_tx; end
            end
            default: tx_step <= 2'd0;
        endcase

        default: st <= S_MAGIC;
        endcase
    end
end

endmodule
