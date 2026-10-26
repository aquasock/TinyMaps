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
        pal_we <= 1'b0;
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

        S_TX: case (tx_step)
            2'd0: begin
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
