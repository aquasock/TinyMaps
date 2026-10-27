// Testbench for the UART at 12 Mbaud, on the clock the design already has.
//
// The link's 2 Mbaud is set by the divider when the UART runs on the 74.25 MHz
// pixel clock, and 16x oversampling needs sixteen clocks a bit, so that clock
// cannot reach much past 4.6 Mbaud.  The FPGA already has a 371.25 MHz clock for
// the TMDS serialiser, and on that the same 16x accumulator is exact at any rate
// up to 23 Mbaud: the accumulator adds 16*BAUD every clock and takes a tick when
// it passes CLK_HZ, so the average bit is exact however the two divide.
//
// This proves the PHY at 12 Mbaud -- the rate that would give about 1.2 MB/s --
// with the same bounded jitter as the 2 Mbaud test, proportionally scaled: 8% of
// a bit, which is 6.7 ns here against 500 ns bits at 2 Mbaud.  A byte with a low
// stop bit must still be dropped and the line must recover.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

module tb_maps_uart_fast;

localparam int  CLK_HZ   = 371_250_000;
localparam int  BAUD     = 12_000_000;
localparam real BIT_NS   = 1e9 / BAUD;            // 83.33 ns
localparam real JIT_MAX  = BIT_NS * 0.08;         // 8% of a bit, as at 2 Mbaud
localparam int  NBYTES   = 256;

reg clk = 0;
always #1.3468 clk = ~clk;                        // 371.25 MHz

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

maps_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .ACC_SHIFT(18), .ACC_W(12)) u_rx (
    .clk(clk), .resetn(resetn), .rx(rx), .data(rx_data), .valid(rx_valid));

maps_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .ACC_SHIFT(18), .ACC_W(12)) u_tx (
    .clk(clk), .resetn(resetn), .start(tx_start), .data(tx_data),
    .tx(tx), .busy(tx_busy));

// ------------------------------------------------------------------ sender ---
reg [15:0] jlfsr = 16'h1ACE;

task automatic jitter(output real j);
    integer r;
begin
    jlfsr = {jlfsr[14:0], jlfsr[15] ^ jlfsr[13] ^ jlfsr[12] ^ jlfsr[10]};
    // through an int: a 3-bit field minus 3 is unsigned arithmetic and wraps to
    // four billion when the field is zero, which becomes a jitter of seconds
    r = jlfsr[2:0];
    j = (r - 3) * JIT_MAX / 3.0;                  // -8%..+11% of a bit
end
endtask

// 8N1, each edge placed at its ideal time plus bounded jitter.  The delay is
// accumulated from the previous edge rather than computed from an absolute
// time: mixing $time with a real bit period truncated to the time unit and put
// a byte 170 times too long, and this needs no absolute time at all.
task automatic send_byte(input logic [7:0] b, input logic stopbit);
    integer i;
    real j, prev;
begin
    rx_drive = 1'b0;                              // start bit begins now
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
integer s_i, d_i, errors, k;
integer nv = 0;
integer nb = 0;

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

    // --- phase 1: the wire into the receiver, at 12 Mbaud with jitter
    for (s_i = 0; s_i < NBYTES; s_i = s_i + 1) begin
        send_byte(sent[s_i], 1'b1);
        idle_bit_fast();
    end
    // a byte with a low stop bit must be dropped, and the next must arrive
    send_byte(8'h5A, 1'b0);
    idle_bit_fast();
    send_byte(8'hA5, 1'b1);
    idle_bit_fast();
    repeat (64) @(posedge clk);

    if (nv != NBYTES + 1) begin
        $display("  received %0d bytes at 12 Mbaud, expected %0d", nv, NBYTES + 1);
        errors = errors + 1;
    end
    for (d_i = 0; d_i < NBYTES; d_i = d_i + 1)
        if (got[d_i] !== sent[d_i]) begin
            if (errors < 4)
                $display("  byte %0d: got %02h want %02h", d_i, got[d_i], sent[d_i]);
            errors = errors + 1;
        end
    if (nv == NBYTES + 1 && got[NBYTES] !== 8'hA5) begin
        $display("  after the framing error got %02h want a5", got[NBYTES]);
        errors = errors + 1;
    end

    // --- phase 2: the transmitter on the wire, read back by the receiver
    loopback = 1;
    repeat (8) @(posedge clk);
    for (s_i = 0; s_i < NBYTES; s_i = s_i + 1) begin
        // a byte is ten bit times, 310 clocks here, so waiting for the
        // transmitter to be free needs a longer cap than the bit clock suggests
        k = 0;
        while (tx_busy && k < 600) begin @(posedge clk); k = k + 1; end
        tx_data  = sent[s_i];
        tx_start = 1;
        @(posedge clk);
        tx_start = 0;
    end
    k = 0;
    while (tx_busy && k < 600) begin @(posedge clk); k = k + 1; end
    repeat (64) @(posedge clk);

    if (nb != NBYTES) begin
        $display("  loopback received %0d bytes, expected %0d", nb, NBYTES);
        errors = errors + 1;
    end
    for (d_i = 0; d_i < NBYTES; d_i = d_i + 1)
        if (back[d_i] !== sent[d_i]) begin
            if (errors < 4)
                $display("  loopback byte %0d: got %02h want %02h", d_i, back[d_i], sent[d_i]);
            errors = errors + 1;
        end

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (256 bytes each way at 12 Mbaud, jitter and a framing error)");
    $finish;
end

task automatic idle_bit_fast;
begin
    rx_drive = 1'b1;
    #(BIT_NS);
end
endtask

endmodule
