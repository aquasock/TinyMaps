// Testbench for maps_uart_rx and maps_uart_tx.
//
// Phase 1 drives the receiver's pin with a bit-level 8N1 sender at the link's
// 2 Mbaud, with a bounded jitter of up to 40 ns on every bit edge so the 16x
// mid-bit sampling is exercised rather than assumed, and compares the bytes
// recovered against the bytes sent.  A byte with a low stop bit, followed by
// idle, must be dropped and the line must recover for the byte after it.
//
// Phase 2 puts the transmitter on the same pin in place of the sender, so the
// bytes go out through the encoder and come back through the receiver.  The
// receiver's judgement of the wire is established in phase 1 against a sender
// written from the format, so a match here means the transmitter emits that
// format.
//
// The jitter is applied to each bit edge's position from the start of the byte,
// not added to the previous bit's duration: a real sender's baud clock does not
// drift by the sum of its own jitter, and a model that does would fail for a
// reason the hardware does not have.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_uart;

localparam int  CLK_HZ = 74_250_000;
localparam int  BAUD   = 2_000_000;
localparam real BIT_NS = 1e9 / BAUD;             // 500 ns
localparam int  NBYTES = 256;

reg clk = 0;
always #6.734 clk = ~clk;                        // 74.25 MHz

reg resetn = 0;
reg rx_drive = 1;
reg loopback = 0;

reg        tx_start = 0;
reg  [7:0] tx_data  = 0;

wire [7:0] rx_data;
wire       rx_valid;
wire       tx;
wire       tx_busy;

// the pin the receiver listens to: the stimulus sender, or the transmitter
wire rx = loopback ? tx : rx_drive;

maps_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
    .clk(clk), .resetn(resetn), .rx(rx), .data(rx_data), .valid(rx_valid));

maps_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk(clk), .resetn(resetn), .start(tx_start), .data(tx_data),
    .tx(tx), .busy(tx_busy));

// ------------------------------------------------------------------ sender ---
reg [15:0] jlfsr = 16'h1ACE;

task automatic jitter(output integer j);
begin
    jlfsr = {jlfsr[14:0], jlfsr[15] ^ jlfsr[13] ^ jlfsr[12] ^ jlfsr[10]};
    j = (jlfsr[2:0] - 3) * 10;                   // -30..+40 ns
end
endtask

task automatic idle_bit;
begin
    rx_drive = 1'b1;
    #(BIT_NS);
end
endtask

// 8N1 with every edge placed at its ideal time plus bounded jitter
task automatic send_byte(input logic [7:0] b, input logic stopbit);
    integer i, j;
    time base, target;
begin
    base     = $time;
    rx_drive = 1'b0;                              // start bit begins now
    for (i = 0; i < 9; i = i + 1) begin
        jitter(j);
        target = base + (i + 1) * BIT_NS + j;
        if (target > $time) #(target - $time);
        if (i < 8) rx_drive = b[i];
        else       rx_drive = stopbit;
    end
    #(BIT_NS);                                    // hold the stop bit
end
endtask

// -------------------------------------------------------------------- test ---
logic [7:0] sent [0:NBYTES-1];
logic [7:0] got  [0:NBYTES];
logic [7:0] back [0:NBYTES-1];
integer s_i, d_i, errors, k;
integer nv = 0;                                   // phase 1 bytes
integer nb = 0;                                   // phase 2 bytes
time    t0;

// A monitor clocked with the DUT samples the valid pulse the way any reader of
// this port would.  Polling it from the stimulus process races the same clock
// edge and silently loses pulses.
always @(posedge clk)
    if (rx_valid) begin
        if (!loopback) begin
            got[nv] = rx_data;
            nv = nv + 1;
        end else begin
            back[nb] = rx_data;
            nb = nb + 1;
        end
    end

initial begin
    // a phase that does not finish is a failed test, not a hung script
    #(BIT_NS * 20000) begin
        $display("RESULT: FAIL (timeout) nv=%0d nb=%0d d_i=%0d", nv, nb, d_i);
        $finish;
    end
end

initial begin
    errors = 0;
    for (k = 0; k < NBYTES; k = k + 1) got[k] = 8'hEE;

    sent[0] = 8'h00; sent[1] = 8'hFF; sent[2] = 8'h55; sent[3] = 8'hAA;
    for (k = 4; k < NBYTES; k = k + 1) begin
        jlfsr = {jlfsr[14:0], jlfsr[15] ^ jlfsr[13] ^ jlfsr[12] ^ jlfsr[10]};
        sent[k] = jlfsr[7:0];
    end

    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // --- phase 1: 256 bytes back to back, which is what the link carries
    fork
        begin : sender
            for (s_i = 0; s_i < NBYTES; s_i = s_i + 1)
                send_byte(sent[s_i], 1'b1);
            idle_bit;
        end
        begin : collector
            t0 = $time;
            while (nv < NBYTES && ($time - t0) < 5_000_000) @(posedge clk);
        end
    join

    for (k = 0; k < NBYTES; k = k + 1)
        if (got[k] !== sent[k]) begin
            if (errors < 5)
                $display("  byte %0d: received %02x, sent %02x", k, got[k], sent[k]);
            errors = errors + 1;
        end
    if (errors) $display("receiver: %0d of %0d bytes wrong", errors, NBYTES);
    else        $display("receiver: %0d bytes recovered from the pin", NBYTES);

    // --- a framing error on its own: the byte must be dropped, and the byte
    // after it -- once the line has idled, so the low stop bit cannot be read
    // as the next start -- must arrive intact
    t0 = $time;
    while ($time - t0 < 2000) @(posedge clk);
    begin
        integer nprev;
        nprev = nv;
        send_byte(8'h3C, 1'b0);
        repeat (20) idle_bit;
        if (nv != nprev) begin
            $display("  framing error: %0d byte(s) delivered for a bad stop bit",
                     nv - nprev);
            errors = errors + 1;
        end else
            $display("receiver: framing error dropped");

        send_byte(8'h5A, 1'b1);
        repeat (20) idle_bit;
        if (nv != nprev + 1 || got[nprev] !== 8'h5A) begin
            $display("  after the framing error: %0d byte(s), got %02x expected 5a", nv - nprev, got[nprev]);
            errors = errors + 1;
        end else
            $display("receiver: recovered after the framing error");
    end

    // --- phase 2: the same bytes out through the transmitter, back in
    loopback = 1;
    repeat (4) @(posedge clk);
    for (d_i = 0; d_i < NBYTES; d_i = d_i + 1) begin
        @(posedge clk);
        while (tx_busy) @(posedge clk);
        tx_data  = sent[d_i];
        tx_start = 1'b1;
        @(posedge clk);
        #1 tx_start = 1'b0;                       // after the edge, not on it
        @(posedge clk);                           // busy asserts on the next edge
        while (tx_busy) @(posedge clk);
    end
    t0 = $time;
    while (nb < NBYTES && ($time - t0) < 5_000_000) @(posedge clk);

    for (k = 0; k < NBYTES; k = k + 1)
        if (back[k] !== sent[k]) begin
            if (errors < 10)
                $display("  byte %0d: sent %02x, came back %02x", k, sent[k], back[k]);
            errors = errors + 1;
        end
    if (!errors) $display("transmitter: %0d bytes out and back through the pin", NBYTES);

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (%0d bytes each way at %0d baud)", NBYTES, BAUD);
    $finish;
end

endmodule
