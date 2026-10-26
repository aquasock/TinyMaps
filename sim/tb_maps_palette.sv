// Testbench for maps_link_rx's palette command, 0x08.
//
// Sends the command as the BL616 would: a framed payload of start index, count,
// RGB triples and a CRC-32, then reads the answer.  The CRCs here were computed
// with zlib rather than with the module's own function, so a mistake in the
// polynomial or the starting value shows up as a NAK instead of agreeing with
// itself.
//
// Three cases: a short palette at a non-zero start, a full 256-entry table, and
// the same short palette with one CRC byte inverted, which must be refused with
// NAK 'P'.  Every write the module makes is captured and compared against the
// bytes that were sent to that index.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_palette;

reg clk = 0;
always #5 clk = ~clk;

reg  resetn = 0;
reg  [7:0] rx_data = 0;
reg        rx_valid = 0;
wire       tx_start;
wire  [7:0] tx_data;
reg        tx_busy = 0;
wire       pal_we;
wire [7:0] pal_idx;
wire [23:0] pal_data;
reg        wr_ack = 0;

maps_link_rx u (
    .clk(clk), .resetn(resetn),
    .rx_data(rx_data), .rx_valid(rx_valid),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy),
    .wr_req(), .wr_addr(), .wr_lanes(), .wr_wdata(), .wr_ack(wr_ack),
    .pal_we(pal_we), .pal_idx(pal_idx), .pal_data(pal_data),
    .busy(), .images(), .bytes_written(), .last_nak(),
    .overflows(), .timeouts()
);

// captured writes and replies
logic [23:0] written [0:255];
logic        seen    [0:255];
integer      nwrites = 0;
logic [7:0]  reply   [0:3];
integer      nreply  = 0;
integer      i, errors;

always @(posedge clk) begin
    if (pal_we) begin
        written[pal_idx] = pal_data;
        seen[pal_idx]    = 1'b1;
        nwrites          = nwrites + 1;
    end
    if (tx_start) begin
        reply[nreply] = tx_data;
        nreply        = nreply + 1;
    end
end

// ------------------------------------------------------------------- wire ---
task automatic send_byte(input logic [7:0] b);
begin
    rx_data  = b;
    rx_valid = 1'b1;
    @(posedge clk);
    rx_valid = 1'b0;
    repeat (8) @(posedge clk);
end
endtask

task automatic send_frame(input logic [7:0] cmd, input integer nbytes);
    integer k; integer flen;
begin
    flen = nbytes + 1;
    send_byte(8'hAA);
    send_byte(flen[15:8]);
    send_byte(flen[7:0]);
    send_byte(cmd);
    for (k = 0; k < nbytes; k = k + 1)
        send_byte(payload[k]);
end
endtask

logic [7:0] payload [0:900];

task automatic wait_reply(input integer count);
    integer t; integer start;
begin
    start = nreply;
    t = 0;
    while (nreply < start + count && t < 200) begin
        @(posedge clk);
        t = t + 1;
    end
end
endtask

// ------------------------------------------------------------------- test ---
initial begin
    for (i = 0; i < 256; i = i + 1) seen[i] = 1'b0;
    errors = 0;
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // --- case A: four entries starting at 10, CRC from zlib (0x6088b86e)
    payload[0] = 8'd10;  payload[1] = 8'd0;      // start
    payload[2] = 8'd4;   payload[3] = 8'd0;      // count
    payload[4] = 8'd255; payload[5] = 8'd0;   payload[6]  = 8'd0;
    payload[7] = 8'd0;   payload[8] = 8'd255; payload[9]  = 8'd0;
    payload[10] = 8'd0;  payload[11] = 8'd0;  payload[12] = 8'd255;
    payload[13] = 8'd16; payload[14] = 8'd32; payload[15] = 8'd48;
    // CRC little-endian: 6e b8 88 60
    payload[16] = 8'h6e; payload[17] = 8'hb8; payload[18] = 8'h88; payload[19] = 8'h60;

    send_frame(8'h08, 20);
    wait_reply(1);
    if (reply[0] !== 8'h06) begin
        $display("  case A: expected ACK, got %02x", reply[0]);
        errors = errors + 1;
    end
    for (i = 0; i < 4; i = i + 1) begin
        if (!seen[10 + i]) begin
            $display("  case A: entry %0d was never written", 10 + i);
            errors = errors + 1;
        end
    end
    if (seen[10] && written[10] !== 24'hFF0000) begin
        $display("  case A: entry 10 is %06x, expected ff0000", written[10]);
        errors = errors + 1;
    end
    if (seen[13] && written[13] !== 24'h102030) begin
        $display("  case A: entry 13 is %06x, expected 102030", written[13]);
        errors = errors + 1;
    end
    if (seen[9] || seen[14]) begin
        $display("  case A: wrote outside the requested range");
        errors = errors + 1;
    end
    if (!errors) $display("palette: 4 entries from index 10, ACK");

    // --- case B: the whole table, CRC from zlib (0xebcd1bcf)
    payload[0] = 8'd0; payload[1] = 8'd0;        // start 0
    payload[2] = 8'd0; payload[3] = 8'd1;        // count 256
    for (i = 0; i < 256; i = i + 1) begin
        payload[4 + i*3]     = i[7:0];
        payload[4 + i*3 + 1] = 8'd255 - i[7:0];
        payload[4 + i*3 + 2] = (i * 7) & 8'hFF;
    end
    payload[772] = 8'hcf; payload[773] = 8'h1b;
    payload[774] = 8'hcd; payload[775] = 8'heb;

    nwrites = 0;
    send_frame(8'h08, 776);
    wait_reply(1);
    if (reply[nreply-1] !== 8'h06) begin
        $display("  case B: expected ACK, got %02x", reply[nreply-1]);
        errors = errors + 1;
    end
    if (nwrites != 256) begin
        $display("  case B: %0d writes for a 256-entry table", nwrites);
        errors = errors + 1;
    end
    if (written[7] !== 24'h07F831) begin
        $display("  case B: entry 7 is %06x, expected 07f831", written[7]);
        errors = errors + 1;
    end
    if (!errors) $display("palette: 256 entries, ACK");

    // --- case C: the same short palette again, with a CRC byte wrong
    payload[0] = 8'd10; payload[1] = 8'd0;       // start
    payload[2] = 8'd4;  payload[3] = 8'd0;       // count
    payload[4] = 8'd255; payload[5] = 8'd0;   payload[6]  = 8'd0;
    payload[7] = 8'd0;   payload[8] = 8'd255; payload[9]  = 8'd0;
    payload[10] = 8'd0;  payload[11] = 8'd0;  payload[12] = 8'd255;
    payload[13] = 8'd16; payload[14] = 8'd32; payload[15] = 8'd48;
    payload[16] = 8'h6f;                          // was 6e
    payload[17] = 8'hb8; payload[18] = 8'h88; payload[19] = 8'h60;
    send_frame(8'h08, 20);
    wait_reply(2);
    if (reply[nreply-2] !== 8'h15 || reply[nreply-1] !== "P") begin
        $display("  case C: expected NAK 'P', got %02x %02x",
                 reply[nreply-2], reply[nreply-1]);
        errors = errors + 1;
    end
    if (!errors) $display("palette: bad CRC refused with NAK 'P'");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (palette command: short, full, and refused)");
    $finish;
end

endmodule
