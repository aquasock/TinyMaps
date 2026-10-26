// Testbench for the AVI InfoFrame the core sends.
//
// The picture arrived on the Tang lifted and clipped at the top (index 236 read
// as 255), which is what a sink does when it treats full-range RGB as limited
// range.  CEA-861 carries that choice in the AVI InfoFrame's RGB quantization
// range field, and this checks the field the core actually emits.
//
// It builds the packet twice, once declaring full range and once leaving the
// module's default, and checks three things by byte: the payload's checksum is
// consistent, the range field sits where CEA-861 puts it, and the two packets
// differ in that field and nothing else.  A field in the wrong bit position
// would still "look set" to a reader of the source, so this is checked by byte.
//
// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
`include "fpga/tinymaps/hdmi/auxiliary_video_information_info_frame.sv"

module tb_avi_range;

localparam [1:0] FULL = 2'b01;

logic [23:0] hdr_full, hdr_lim;
logic [55:0] sub_full [3:0];
logic [55:0] sub_lim  [3:0];

auxiliary_video_information_info_frame #(
    .VIDEO_ID_CODE(4), .IT_CONTENT(1'b1), .RGB_QUANTIZATION_RANGE(FULL)
) u_full (.header(hdr_full), .sub(sub_full));

auxiliary_video_information_info_frame #(
    .VIDEO_ID_CODE(4), .IT_CONTENT(1'b1), .RGB_QUANTIZATION_RANGE(2'b00)
) u_lim (.header(hdr_lim), .sub(sub_lim));

// payload bytes 0..13 live in sub[0] and sub[1]
wire [111:0] pay_full = {sub_full[1], sub_full[0]};
wire [111:0] pay_lim  = {sub_lim[1],  sub_lim[0]};

function automatic [7:0] pbyte(input logic [111:0] p, input int k);
    pbyte = p[8*k +: 8];
endfunction

integer k, errors;
integer sum_full, sum_lim;

initial begin
    errors = 0;
    #1;                                   // let the continuous assignments settle

    // header: length, version, and the packet type with its top bit set
    if (hdr_full[23:16] !== 8'h0D || hdr_full[15:8] !== 8'h02 ||
        hdr_full[7:0] !== 8'h82) begin
        $display("  header is %06x, expected 0d0282", hdr_full);
        errors = errors + 1;
    end

    // the 14 payload bytes plus the three header bytes sum to zero
    sum_full = hdr_full[23:16] + hdr_full[15:8] + hdr_full[7:0];
    sum_lim  = hdr_lim[23:16] + hdr_lim[15:8] + hdr_lim[7:0];
    for (k = 0; k < 14; k = k + 1) begin
        sum_full = sum_full + pbyte(pay_full, k);
        sum_lim  = sum_lim  + pbyte(pay_lim,  k);
    end
    if (sum_full % 256 !== 0) begin
        $display("  full-range packet checksum is %02x, expected 00", sum_full % 256);
        errors = errors + 1;
    end
    if (sum_lim % 256 !== 0) begin
        $display("  default packet checksum is %02x, expected 00", sum_lim % 256);
        errors = errors + 1;
    end

    // byte 3: ITC at 7, extended colorimetry at 6:4, RGB range at 3:2,
    // non-uniform scaling at 1:0
    if (pbyte(pay_full, 3) !== 8'b1_000_01_00) begin
        $display("  byte 3 is %08b, expected 10000100 (ITC set, full range)",
                 pbyte(pay_full, 3));
        errors = errors + 1;
    end
    if (pbyte(pay_lim, 3) !== 8'b1_000_00_00) begin
        $display("  default byte 3 is %08b, expected 10000000", pbyte(pay_lim, 3));
        errors = errors + 1;
    end

    // and the two packets differ in nothing but those two bits, the checksum
    // byte excepted: it is what makes the packet's bytes sum to zero, so it has
    // to move when any other byte does
    for (k = 0; k < 14; k = k + 1) begin
        if (k == 0 || k == 3) continue;
        if (pbyte(pay_full, k) !== pbyte(pay_lim, k)) begin
            $display("  byte %0d differs between the two packets: %02x vs %02x",
                     k, pbyte(pay_full, k), pbyte(pay_lim, k));
            errors = errors + 1;
        end
    end

    if (errors) $display("RESULT: FAIL (%0d errors)", errors);
    else        $display("RESULT: PASS (AVI byte 3 = %08b, full range)", pbyte(pay_full, 3));
    $finish;
end

endmodule
