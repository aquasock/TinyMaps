// TinyMaps UART receiver: 8N1, the BL616 link's 2 Mbaud.
//
// The link the board wires to the core is a plain UART; the frame protocol
// (0xAA len type payload) is parsed in the fabric, upstream of anything here.
// This module recovers bytes from the pin and nothing else.
//
// Sampling is 16x oversampled from a fractional baud tick: the accumulator
// adds 16 * BAUD every clock and takes a tick when it passes CLK_HZ, so the
// average rate is exact however the two frequencies divide. At 74.25 MHz and
// 2 Mbaud that is 37.125 clocks a bit, and no single tick is off by more than
// one clock, so the mid-bit sample stays inside the bit for the whole frame.
//
// A byte with a low stop bit is dropped rather than delivered: on this link a
// framing error means the sender's clock and ours disagree, and a byte taken
// anyway would corrupt a CRC that is checked further up.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_uart_rx #(
    parameter int CLK_HZ = 74_250_000,
    parameter int BAUD   = 2_000_000
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);

localparam int INC = 16 * BAUD;          // 16 samples per bit
localparam int ACC_W = 28;

// 16x baud tick
reg  [ACC_W-1:0] acc = '0;
wire [ACC_W-1:0] acc_next = acc + INC[ACC_W-1:0];
wire             tick     = acc_next >= CLK_HZ[ACC_W-1:0];

always @(posedge clk)
    if (!resetn) acc <= '0;
    else         acc <= tick ? acc_next - CLK_HZ[ACC_W-1:0] : acc_next;

// two-flop synchroniser: the pin is asynchronous to this clock
reg [1:0] rx_s = 2'b11;
always @(posedge clk)
    if (!resetn) rx_s <= 2'b11;
    else         rx_s <= {rx_s[0], rx};

// ------------------------------------------------------------------ receiver --
localparam [1:0] R_IDLE = 2'd0, R_START = 2'd1, R_BITS = 2'd2, R_STOP = 2'd3;

reg [1:0]  st;
reg [3:0]  cnt;              // ticks within the current bit, 0..15
reg [2:0]  bitn;
reg [7:0]  shift;

always @(posedge clk) begin
    valid <= 1'b0;
    if (!resetn) begin
        st <= R_IDLE; cnt <= 4'd0; bitn <= 3'd0; shift <= 8'd0; data <= 8'd0;
    end else begin
        case (st)
            R_IDLE: if (!rx_s[1]) begin
                        st  <= R_START;
                        cnt <= 4'd0;
                    end

            // eight ticks from the falling edge is the middle of the start bit
            R_START: if (tick) begin
                        if (cnt == 4'd7) begin
                            if (!rx_s[1]) begin
                                st   <= R_BITS;
                                cnt  <= 4'd0;
                                bitn <= 3'd0;
                            end else st <= R_IDLE;   // a glitch, not a start bit
                        end else cnt <= cnt + 4'd1;
                    end

            // middle of each data bit, least significant first
            R_BITS: if (tick) begin
                        if (cnt == 4'd15) begin
                            cnt   <= 4'd0;
                            shift <= {rx_s[1], shift[7:1]};
                            if (bitn == 3'd7) st <= R_STOP;
                            else              bitn <= bitn + 3'd1;
                        end else cnt <= cnt + 4'd1;
                    end

            // middle of the stop bit: high means the byte is good
            R_STOP: if (tick) begin
                        if (cnt == 4'd15) begin
                            cnt <= 4'd0;
                            st  <= R_IDLE;
                            if (rx_s[1]) begin
                                data  <= shift;
                                valid <= 1'b1;
                            end
                        end else cnt <= cnt + 4'd1;
                    end
        endcase
    end
end

endmodule
