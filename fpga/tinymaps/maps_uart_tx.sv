// TinyMaps UART transmitter: 8N1, the BL616 link's 2 Mbaud.
//
// One byte at a time, stop-and-wait: the loader answers a frame and waits for
// the next, so nothing here needs a queue. `busy` is high from the clock the
// byte is accepted until the stop bit has finished, which is what the loader
// holds tx_start off with.
//
// The baud tick is the receiver's, a 16x fractional accumulator, so the two
// ends of the link divide the clock the same way.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns / 1ps

module maps_uart_tx #(
    parameter int CLK_HZ = 74_250_000,
    parameter int BAUD   = 2_000_000
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx  = 1'b1,
    output wire       busy
);

localparam int INC = 16 * BAUD;
localparam int ACC_W = 28;

reg  [ACC_W-1:0] acc = '0;
wire [ACC_W-1:0] acc_next = acc + INC[ACC_W-1:0];
wire             tick     = acc_next >= CLK_HZ[ACC_W-1:0];

always @(posedge clk)
    if (!resetn) acc <= '0;
    else         acc <= tick ? acc_next - CLK_HZ[ACC_W-1:0] : acc_next;

localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_BITS = 2'd2, T_STOP = 2'd3;

reg [1:0] st;
reg [4:0] cnt;
reg [2:0] bitn;
reg [7:0] shift;

assign busy = st != T_IDLE;

always @(posedge clk) begin
    if (!resetn) begin
        st <= T_IDLE; cnt <= 5'd0; bitn <= 3'd0; shift <= 8'd0; tx <= 1'b1;
    end else begin
        case (st)
            T_IDLE: if (start) begin
                        shift <= data;
                        tx    <= 1'b0;          // start bit
                        cnt   <= 5'd0;
                        st    <= T_START;
                    end

            T_START: if (tick) begin
                        if (cnt == 5'd15) begin
                            cnt   <= 5'd0;
                            bitn  <= 3'd0;
                            tx    <= shift[0];  // least significant bit first
                            shift <= {1'b1, shift[7:1]};
                            st    <= T_BITS;
                        end else cnt <= cnt + 5'd1;
                    end

            T_BITS: if (tick) begin
                        if (cnt == 5'd15) begin
                            cnt   <= 5'd0;
                            tx    <= shift[0];
                            shift <= {1'b1, shift[7:1]};
                            if (bitn == 3'd7) st <= T_STOP;
                            else              bitn <= bitn + 3'd1;
                        end else cnt <= cnt + 5'd1;
                    end

            // The bit-7 value loaded on entry holds for sixteen ticks, then the
            // line goes high for the stop bit's sixteen; without the second
            // sixteen the frame would end exactly as the stop began and
            // back-to-back bytes would arrive a bit early.
            T_STOP: if (tick) begin
                        if (cnt == 5'd15) begin
                            tx  <= 1'b1;
                            cnt <= cnt + 5'd1;
                        end else if (cnt == 5'd31) begin
                            cnt <= 5'd0;
                            st  <= T_IDLE;
                        end else cnt <= cnt + 5'd1;
                    end
        endcase
    end
end

endmodule
