// Testbench for maps_link_rx.
//
// Drives the 0xAA frame protocol at a realistic byte rate, models the SDRAM
// write port as a 4 MiB byte array that honours the byte lanes, models the
// transmitter as busy for ten clocks per byte, and checks the SDRAM contents
// against the image that was sent.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_link_rx;

localparam integer MEM_BYTES = 4*1024*1024;
localparam integer IMG_LEN   = 20000;      // spans three 8192-byte blocks
localparam integer BYTE_GAP  = 100;        // clocks between link bytes
localparam integer CHUNK     = 1024;       // payload bytes per frame

reg clk = 0, resetn = 0;
always #5 clk = ~clk;                      // 100 MHz sim clock, does not matter

reg  [7:0] rx_data = 0;
reg        rx_valid = 0;
wire       tx_start;
wire [7:0] tx_data;
reg        tx_busy = 0;

wire        wr_req;
wire [24:3] wr_addr;
wire [7:0]  wr_lanes;
wire [63:0] wr_wdata;
reg         wr_ack = 0;

wire        busy;
wire [31:0] images, bytes_written;
wire [7:0]  last_nak;
wire [15:0] overflows, timeouts;

// ------------------------------------------------------------ write model --
reg [7:0] mem [0:MEM_BYTES-1];
reg       req_seen = 0;
reg [3:0] ack_cnt = 0;
integer   i;
localparam integer ACK_DELAY = 6;

always @(posedge clk) begin
    wr_ack <= 1'b0;
    if (!wr_req) begin
        req_seen <= 1'b0;
        ack_cnt  <= 4'd0;
    end else if (!req_seen) begin
        req_seen <= 1'b1;
        ack_cnt  <= 4'd0;
    end else if (ack_cnt == ACK_DELAY) begin
        wr_ack   <= 1'b1;
        req_seen <= 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (wr_lanes[i]) mem[{wr_addr, 3'b000} + i] <= wr_wdata[i*8 +: 8];
    end else begin
        ack_cnt <= ack_cnt + 4'd1;
    end
end

// ------------------------------------------------------- transmitter model --
reg [7:0] resp [0:63];
integer   resp_n = 0;
reg [3:0] tx_cnt = 0;
always @(posedge clk) begin
    if (tx_start) begin
        resp[resp_n] <= tx_data;
        resp_n <= resp_n + 1;
        tx_busy <= 1'b1;
        tx_cnt  <= 4'd0;
    end else if (tx_busy) begin
        if (tx_cnt == 4'd9) tx_busy <= 1'b0;
        else tx_cnt <= tx_cnt + 4'd1;
    end
end

maps_link_rx dut (
    .clk(clk), .resetn(resetn),
    .rx_data(rx_data), .rx_valid(rx_valid),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_lanes(wr_lanes),
    .wr_wdata(wr_wdata), .wr_ack(wr_ack),
    .busy(busy), .images(images), .bytes_written(bytes_written),
    .last_nak(last_nak), .overflows(overflows), .timeouts(timeouts)
);

// -------------------------------------------------------------------- CRC --
function automatic [31:0] crc32_byte(input [31:0] crc, input [7:0] b);
    reg [31:0] c; integer k;
    begin
        c = crc ^ {24'd0, b};
        for (k = 0; k < 8; k = k + 1) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
        crc32_byte = c;
    end
endfunction

// ------------------------------------------------------------------ link ---
reg [7:0] txbuf [0:16383];

task send_byte(input [7:0] b);
    integer w;
    begin
        rx_data = b; rx_valid = 1;
        @(posedge clk);
        rx_valid = 0;
        for (w = 0; w < BYTE_GAP; w = w + 1) @(posedge clk);
    end
endtask

// frame carrying cmd 0x07 and len payload bytes from txbuf[off..off+len-1]
task send_frame(input integer off, input integer len);
    integer k; integer flen;
    begin
        flen = 1 + len;
        send_byte(8'hAA);
        send_byte(flen >> 8);
        send_byte(flen & 8'hFF);
        send_byte(8'h07);
        for (k = 0; k < len; k = k + 1) send_byte(txbuf[off + k]);
    end
endtask

// send len bytes from txbuf[off..] as one or more frames
task send_stream(input integer off, input integer len);
    integer done; integer k;
    begin
        done = 0;
        while (done < len) begin
            k = len - done; if (k > CHUNK) k = CHUNK;
            send_frame(off + done, k);
            done = done + k;
        end
    end
endtask

task put_word(input integer off, input [31:0] v);
    begin
        txbuf[off+0] = v[7:0];   txbuf[off+1] = v[15:8];
        txbuf[off+2] = v[23:16]; txbuf[off+3] = v[31:24];
    end
endtask

integer errors = 0;
task expect_byte(input [7:0] want, input [127:0] what);
    integer guard;
    begin
        guard = 0;
        while (resp_n == 0 && guard < 20000) begin @(posedge clk); guard = guard + 1; end
        if (guard >= 20000) begin
            $display("FAIL: %0s: no response", what); errors = errors + 1;
        end else begin
            if (resp[0] !== want) begin
                $display("FAIL: %0s: got %02x want %02x", what, resp[0], want);
                errors = errors + 1;
            end
            // A real sender waits for the byte to arrive before sending the
            // next one.  tx_busy is registered off tx_start, so let it rise
            // before waiting for it to fall.
            repeat (2) @(posedge clk);
            while (tx_busy) @(posedge clk);
            repeat (2) @(posedge clk);
            // shift the queue down
            for (i = 1; i < resp_n; i = i + 1) resp[i-1] = resp[i];
            resp_n = resp_n - 1;
        end
    end
endtask

reg [7:0] image [0:IMG_LEN-1];

// header, blocks and image CRC for one image at base
task send_image(input [31:0] base, input [31:0] len, input [31:0] force_img_crc,
                input [31:0] force_hdr_crc, input integer corrupt_block);
    integer off, blk, n;
    reg [31:0] icrc, bcrc, hcrc;
    reg [31:0] v;
    begin
        // image CRCs in the testbench, over the pattern it will send
        icrc = 32'hFFFFFFFF;
        for (n = 0; n < len; n = n + 1) icrc = crc32_byte(icrc, image[n]);
        icrc = ~icrc;
        if (force_img_crc != 0) icrc = force_img_crc;

        // header
        put_word(0, 32'h314c4d54);
        put_word(4, base);
        put_word(8, len);
        put_word(12, icrc);
        hcrc = 32'hFFFFFFFF;
        for (n = 0; n < 16; n = n + 1) hcrc = crc32_byte(hcrc, txbuf[n]);
        hcrc = ~hcrc;
        if (force_hdr_crc != 0) hcrc = force_hdr_crc;
        put_word(16, hcrc);
        send_stream(0, 20);
        if (force_hdr_crc != 0) begin
            expect_byte(8'h15, "header NAK");
            expect_byte("H", "header NAK letter");
            return;
        end
        expect_byte(8'h06, "header ACK");

        // blocks
        off = 0; blk = 0;
        while (off < len) begin
            n = len - off; if (n > 8192) n = 8192;
            for (i = 0; i < n; i = i + 1) txbuf[i] = image[off + i];
            bcrc = 32'hFFFFFFFF;
            for (i = 0; i < n; i = i + 1) bcrc = crc32_byte(bcrc, txbuf[i]);
            bcrc = ~bcrc;
            if (corrupt_block == blk) bcrc = bcrc ^ 32'h00000001;
            put_word(n, bcrc);
            send_stream(0, n + 4);
            if (corrupt_block == blk) begin
                expect_byte(8'h15, "block NAK");
                expect_byte("C", "block NAK letter");
                // re-send the same block, correct this time
                bcrc = 32'hFFFFFFFF;
                for (i = 0; i < n; i = i + 1) bcrc = crc32_byte(bcrc, txbuf[i]);
                bcrc = ~bcrc;
                put_word(n, bcrc);
                send_stream(0, n + 4);
            end
            expect_byte(8'h06, "block ACK");
            off = off + n; blk = blk + 1;
        end
        if (force_img_crc != 0) begin
            expect_byte(8'h15, "image NAK");
            expect_byte("I",  "image NAK letter");
        end else
            expect_byte(8'h06, "image ACK");
    end
endtask

integer n, bad;
initial begin
    $dumpfile("tb_maps_link_rx.vcd"); $dumpvars(0, tb_maps_link_rx);
    for (n = 0; n < IMG_LEN; n = n + 1) image[n] = (n * 37 + (n >> 8)) & 8'hFF;
    for (n = 0; n < MEM_BYTES; n = n + 1) mem[n] = 8'h00;

    repeat (20) @(posedge clk);
    resetn = 1;
    repeat (10) @(posedge clk);

    // 1. clean image at 0
    $display("--- test 1: clean image, %0d bytes at 0", IMG_LEN);
    send_image(0, IMG_LEN, 0, 0, -1);
    if (images !== 1) begin $display("FAIL: images %0d", images); errors = errors + 1; end

    bad = 0;
    for (n = 0; n < IMG_LEN; n = n + 1) if (mem[n] !== image[n]) bad = bad + 1;
    if (bad != 0) begin $display("FAIL: %0d of %0d bytes differ", bad, IMG_LEN); errors = errors + 1; end
    else $display("PASS: all %0d bytes in SDRAM match", IMG_LEN);

    // 2. a rejected block, then the retry
    $display("--- test 2: block 1 CRC corrupted, retry accepted");
    send_image(32'h00100000, IMG_LEN, 0, 0, 1);
    bad = 0;
    for (n = 0; n < IMG_LEN; n = n + 1) if (mem[32'h00100000 + n] !== image[n]) bad = bad + 1;
    if (bad != 0) begin $display("FAIL: retried block: %0d bytes differ", bad); errors = errors + 1; end
    else $display("PASS: retried block landed correctly");

    // 3. bad header CRC
    $display("--- test 3: header CRC corrupted");
    send_image(32'h00200000, IMG_LEN, 0, 32'hDeadBeef, -1);
    if (last_nak !== "H") begin $display("FAIL: last_nak %02x", last_nak); errors = errors + 1; end
    else $display("PASS: header rejected with 'H'");

    // 4. bad image CRC
    $display("--- test 4: image CRC corrupted");
    send_image(32'h00300000, IMG_LEN, 32'h12345678, 0, -1);
    if (last_nak !== "I") begin $display("FAIL: last_nak %02x", last_nak); errors = errors + 1; end
    else $display("PASS: image rejected with 'I'");

    if (overflows !== 0) begin $display("FAIL: %0d write-port overflows", overflows); errors = errors + 1; end
    else $display("PASS: no write-port overflows");

    repeat (50) @(posedge clk);
    if (errors == 0) $display("\nRESULT: PASS");
    else $display("\nRESULT: FAIL (%0d errors)", errors);
    $finish;
end

endmodule
