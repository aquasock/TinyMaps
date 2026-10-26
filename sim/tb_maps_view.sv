// Testbench for maps_link_rx's viewport command, 0x0A.
//
// Sends a viewport as the host does -- level address, width, height, step and
// origin, with a CRC-32 computed by zlib rather than by the module's own
// function -- and checks what gets latched.  Four cases: one that must be
// accepted, a step of 0.4 that must be refused with NAK 'V', a level that would
// run past the end of the SDRAM that must also be refused with 'V', and a
// corrupted CRC that must be refused with 'C'.
//
// The refusals matter more than the acceptance: the step range is the
// renderer's operating limit, and a viewport outside it draws correctly-shaped
// rubbish, so it has to be stopped at the door.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_view;

reg clk = 0;
always #5 clk = ~clk;

reg  resetn = 0;
reg  [7:0] rx_data = 0;
reg        rx_valid = 0;
wire       tx_start;
wire  [7:0] tx_data;
reg        tx_busy = 0;
reg        wr_ack = 0;

wire        vp_we;
wire [24:0] vp_base;
wire [15:0] vp_w, vp_h;
wire [31:0] vp_step;
wire signed [31:0] vp_x0, vp_y0;

maps_link_rx u (
    .clk(clk), .resetn(resetn),
    .rx_data(rx_data), .rx_valid(rx_valid),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy),
    .wr_req(), .wr_addr(), .wr_lanes(), .wr_wdata(), .wr_ack(wr_ack),
    .pal_we(), .pal_idx(), .pal_data(),
    .vp_we(vp_we), .vp_base(vp_base), .vp_w(vp_w), .vp_h(vp_h),
    .vp_step(vp_step), .vp_x0(vp_x0), .vp_y0(vp_y0),
    .busy(), .images(), .bytes_written(), .last_nak(),
    .overflows(), .timeouts()
);

logic [24:0] got_base = 0;
logic [15:0] got_w = 0, got_h = 0;
logic [31:0] got_step = 0;
integer      nlatched = 0;
logic [7:0]  reply [0:7];
integer      nreply = 0;
integer      i, errors;

always @(posedge clk) begin
    if (vp_we) begin
        got_base <= vp_base; got_w <= vp_w; got_h <= vp_h; got_step <= vp_step;
        nlatched <= nlatched + 1;
    end
    if (tx_start) begin
        reply[nreply] <= tx_data;
        nreply <= nreply + 1;
    end
end

task automatic send_byte(input logic [7:0] b);
begin
    rx_data = b; rx_valid = 1'b1;
    @(posedge clk);
    rx_valid = 1'b0;
    repeat (8) @(posedge clk);
end
endtask

logic [7:0] pay [0:31];

task automatic send_view(input integer n);
    integer k, flen;
begin
    flen = n + 1;
    send_byte(8'hAA); send_byte(flen[15:8]); send_byte(flen[7:0]); send_byte(8'h0A);
    for (k = 0; k < n; k = k + 1) send_byte(pay[k]);
end
endtask

task automatic settle(input integer clocks);
    begin
        repeat (clocks) @(posedge clk);
    end
endtask

initial begin
    errors = 0;
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // --- a viewport that must be accepted: 768x768 at 0x100000, step 0.6
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h10; pay[3]=8'h00;   // base 0x00100000
    pay[4]=8'h00; pay[5]=8'h03;                              // width 768
    pay[6]=8'h00; pay[7]=8'h03;                              // height 768
    pay[8]=8'h9a; pay[9]=8'h99; pay[10]=8'h00; pay[11]=8'h00; // step 0.6
    pay[12]=8'h00; pay[13]=8'h00; pay[14]=8'h00; pay[15]=8'h00;
    pay[16]=8'h00; pay[17]=8'h00; pay[18]=8'h00; pay[19]=8'h00;
    pay[20]=8'h8e; pay[21]=8'h64; pay[22]=8'h73; pay[23]=8'ha9; // crc
    send_view(24);
    settle(40);
    if (reply[0] !== 8'h06) begin
        $display("  accepted case: expected ACK, got %02x", reply[0]);
        errors = errors + 1;
    end
    if (nlatched !== 1 || got_base !== 25'h100000 || got_w !== 16'd768 ||
        got_h !== 16'd768 || got_step !== 32'd39322) begin
        $display("  accepted case: latched base %h size %0dx%0d step %0d after %0d writes",
                 got_base, got_w, got_h, got_step, nlatched);
        errors = errors + 1;
    end
    if (!errors) $display("viewport: accepted, 768x768 step 0.6 latched");

    // --- step 0.4: the renderer cannot draw it, so it must not be latched
    pay[8]=8'h66; pay[9]=8'h66;                               // step 0.4
    pay[20]=8'hb1; pay[21]=8'h54; pay[22]=8'hcf; pay[23]=8'hf2; // its own crc
    send_view(24);
    settle(40);
    if (reply[1] !== 8'h15 || reply[2] !== "V") begin
        $display("  step 0.4: expected NAK 'V', got %02x %02x", reply[1], reply[2]);
        errors = errors + 1;
    end
    if (nlatched !== 1) begin
        $display("  step 0.4: latched anyway (%0d writes)", nlatched);
        errors = errors + 1;
    end
    if (errors === 0) $display("viewport: step 0.4 refused with NAK 'V'");

    // --- a level that would run past the end of the SDRAM
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'hff; pay[3]=8'h01;   // base 0x01ff0000
    pay[8]=8'h9a; pay[9]=8'h99;                               // step 0.6 again
    pay[20]=8'h74; pay[21]=8'h25; pay[22]=8'h0a; pay[23]=8'h91; // its own crc
    send_view(24);
    settle(40);
    if (reply[3] !== 8'h15 || reply[4] !== "V") begin
        $display("  base past the end: expected NAK 'V', got %02x %02x", reply[3], reply[4]);
        errors = errors + 1;
    end
    if (nlatched !== 1) begin
        $display("  base past the end: latched anyway (%0d writes)", nlatched);
        errors = errors + 1;
    end

    // --- a corrupted CRC on an otherwise good viewport
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h10; pay[3]=8'h00;
    pay[8]=8'h9a; pay[9]=8'h99;
    pay[20]=8'h8f; pay[21]=8'h64; pay[22]=8'h73; pay[23]=8'ha9;  // was 8e
    send_view(24);
    settle(40);
    if (reply[5] !== 8'h15 || reply[6] !== "C") begin
        $display("  bad crc: expected NAK 'C', got %02x %02x", reply[5], reply[6]);
        errors = errors + 1;
    end
    if (nlatched !== 1) begin
        $display("  bad crc: latched anyway (%0d writes)", nlatched);
        errors = errors + 1;
    end
    if (!errors) $display("viewport: bad CRC refused with NAK 'C'");

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (viewport: latched once, three refusals)");
    $finish;
end

endmodule
