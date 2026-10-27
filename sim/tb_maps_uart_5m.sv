// Testbench for the link at 5 Mbaud with eight samples a bit.
//
// This is the configuration the core ships with when the link is pushed: a bit is
// 14.85 clocks at 74.25 MHz, which is too few for sixteen samples and ample for
// eight, and eight still puts the mid-bit sample a quarter of a bit from either
// edge.  Sixteen samples a bit cannot reach past 4.64 Mbaud on this clock, and
// the 371.25 MHz clock the TMDS serialiser owns cannot host the receiver at all
// (it closes at 189 MHz against 371), so this is the fastest the link can be
// with the clocks this design has.
//
// The jitter is 8% of a bit, the same fraction the 2 Mbaud test applies, so the
// two are comparable rather than the faster one being flattered.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_uart_5m;

localparam int  CLK_HZ     = 74_250_000;
localparam int  BAUD       = 5_000_000;
localparam int  OVERSAMPLE = 8;
localparam real BIT_NS     = 1e9 / BAUD;          // 200 ns
localparam real JIT_MAX    = BIT_NS * 0.08;       // 16 ns
localparam int  NBYTES     = 256;

reg clk = 0;
always #6.734 clk = ~clk;                         // 74.25 MHz

reg resetn = 0;
reg rx_drive = 1;
reg loopback = 0;

reg        tx_start = 0;
reg  [7:0] tx_data  = 0;

wire [7:0] rx_data;
wire       rx_valid;
wire       tx;
wire       tx_busy;

wire rx = loopback ? tx : rx_drive;

maps_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OVERSAMPLE)) u_rx (
    .clk(clk), .resetn(resetn), .rx(rx), .data(rx_data), .valid(rx_valid));

maps_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OVERSAMPLE)) u_tx (
    .clk(clk), .resetn(resetn), .start(tx_start), .data(tx_data),
    .tx(tx), .busy(tx_busy));

// ------------------------------------------------------------------ sender ---
reg [15:0] jlfsr = 16'h1ACE;

task automatic jitter(output real j);
    integer r;
begin
    jlfsr = {jlfsr[14:0], jlfsr[15] ^ jlfsr[13] ^ jlfsr[12] ^ jlfsr[10]};
    r = jlfsr[2:0];                                // through an int: unsigned
    j = (r - 3) * JIT_MAX / 3.0;                    // arithmetic wraps otherwise
end
endtask

task automatic send_byte(input logic [7:0] b, input logic stopbit);
    integer i;
    real j, prev;
begin
    rx_drive = 1'b0;                                // start bit begins now
    prev     = 0.0;
    for (i = 0; i < 9; i = i + 1) begin
        jitter(j);
        #(BIT_NS + j - prev);
        prev = j;
        if (i < 8) rx_drive = b[i];
        else       rx_drive = stopbit;
    end
    #(BIT_NS - prev);
end
endtask

// -------------------------------------------------------------------- test ---
logic [7:0] sent [0:NBYTES-1];
logic [7:0] got  [0:NBYTES];
logic [7:0] back [0:NBYTES-1];
integer s_i, d_i, k, errors;
integer nv = 0, nb = 0;

always @(posedge clk)
    if (rx_valid) begin
        if (!loopback) begin got[nv]  = rx_data; nv = nv + 1; end
        else           begin back[nb] = rx_data; nb = nb + 1; end
    end

initial begin
    #(BIT_NS * 20000) begin
        $display("RESULT: FAIL (timeout) nv=%0d nb=%0d", nv, nb);
        $finish;
    end
end

initial begin
    errors = 0;
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    for (s_i = 0; s_i < NBYTES; s_i = s_i + 1)
        sent[s_i] = 8'((s_i * 37) ^ (s_i >> 1));

    for (s_i = 0; s_i < NBYTES; s_i = s_i + 1)
        send_byte(sent[s_i], 1'b1);
    // a byte with a low stop bit must be dropped and the line must recover
    send_byte(8'h5A, 1'b0);
    send_byte(8'hA5, 1'b1);
    repeat (64) @(posedge clk);

    if (nv != NBYTES + 1) begin
        $display("  received %0d bytes, expected %0d", nv, NBYTES + 1);
        errors = errors + 1;
    end
    for (d_i = 0; d_i < NBYTES && d_i < nv; d_i = d_i + 1)
        if (got[d_i] !== sent[d_i]) begin
            if (errors < 4) $display("  byte %0d: got %02h want %02h", d_i, got[d_i], sent[d_i]);
            errors = errors + 1;
        end
    if (nv == NBYTES + 1 && got[NBYTES] !== 8'hA5) begin
        $display("  after the framing error got %02h want a5", got[NBYTES]);
        errors = errors + 1;
    end

    // the transmitter, read back through the receiver
    loopback = 1;
    repeat (8) @(posedge clk);
    for (s_i = 0; s_i < NBYTES; s_i = s_i + 1) begin
        k = 0;
        while (tx_busy && k < 600) begin @(posedge clk); k = k + 1; end
        tx_data  = sent[s_i];
        tx_start = 1'b1;
        @(posedge clk);
        tx_start = 1'b0;
    end
    k = 0;
    while (tx_busy && k < 600) begin @(posedge clk); k = k + 1; end
    repeat (64) @(posedge clk);

    if (nb != NBYTES) begin
        $display("  loopback received %0d bytes, expected %0d", nb, NBYTES);
        errors = errors + 1;
    end
    for (d_i = 0; d_i < NBYTES && d_i < nb; d_i = d_i + 1)
        if (back[d_i] !== sent[d_i]) begin
            if (errors < 4) $display("  loopback %0d: got %02h want %02h", d_i, back[d_i], sent[d_i]);
            errors = errors + 1;
        end

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (256 bytes each way at 5 Mbaud, 8 samples a bit)");
    $finish;
end

endmodule
