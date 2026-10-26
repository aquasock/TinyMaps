// SPDX-License-Identifier: MIT
// Vendored from TinyNES fpga/ae350_soc/ahb_sdram.sv by aquasock; renamed only.
// TinyMaps uses its A25 write port for the pack loader and its video channel
// for the renderer's source rows.  Nothing about the engine changed.
//
// SDRAM back end for the AE350 RAM port: one 16-bit Winbond W9825G6KH-6
// (32 MiB: 4 banks of 8192 rows of 512 columns) on the dock's J9 connector,
// run from the bus clock. ahb_ram's front end hands it one 64-bit transfer
// at a time on a request/acknowledge pair:
//
//   req stays high, with addr, write, lanes and wdata steady, until ack
//   pulses; for a read, rdata is valid while ack is high. A request is
//   never accepted in the cycle ack is high.
//
// Reads go through a one-line buffer holding the 32-byte line (the A25's
// cache line) last read. A miss reads the whole line, the requested
// doubleword first and the rest wrapping round after it, and acknowledges
// as soon as the requested doubleword is in, so the remaining beats of a
// cache-line fill are answered from the buffer while it fills. A write is
// acknowledged when it is accepted, which is as soon as nothing else is in
// progress; it is merged into the buffer if it hits the buffered line and
// then written to the SDRAM, only its own byte lanes changing.
//
// The video channel reads one 256-byte line for the video unit:
//
//   vstart pulses with vaddr, which stays steady until vdone; the line's
//   128 halfwords come back in order, each on vdata with its index while
//   vvalid is high, and vdone pulses once after the last.
//
// A pending video line goes ahead of a waiting A25 transfer, and refresh
// ahead of both; a line takes about 140 clocks, so the A25 waits at most
// that long for one.
//
// Every access opens its row and closes it again when done (ACTIVE,
// READ/WRITE one column at a time, PRECHARGE), so all banks are idle
// between accesses and AUTO REFRESH can be issued then. Byte address bits
// [9:1] are the column, [11:10] the bank and [24:12] the row, so a video
// line is always within one row.
//
// The SDRAM clock is the bus clock inverted (an ODDR at the pin), so the
// SDRAM samples commands and write data half a bus clock after they leave
// their registers. Read data is captured on the falling bus clock edge,
// which is the SDRAM clock edge CL cycles after the READ, and re-registered
// on the rising edge.
module sdram_ctrl #(
    parameter integer CL = 3,
    // 200 us of clocks before the first command, as the datasheet requires.
    parameter integer INIT_CYCLES = 15000,
    // 8192 refreshes per 64 ms is one per 7.8 us; refresh every 7 us.
    parameter integer REFRESH_CYCLES = 525
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        req,
    input  wire        write,
    input  wire [24:3] addr,
    input  wire [7:0]  lanes,
    input  wire [63:0] wdata,
    output reg         ack,
    output reg  [63:0] rdata,
    output reg         ready,

    input  wire        vstart,
    input  wire [24:8] vaddr,
    output reg         vvalid,
    output reg  [6:0]  vindex,
    output reg  [15:0] vdata,
    output reg         vdone,

    output wire        sdram_clk,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg  [1:0]  sdram_ba,
    output reg  [12:0] sdram_a,
    output reg  [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_dq
);
    // {CS#, RAS#, CAS#, WE#}
    localparam [3:0] CMD_NOP = 4'b0111;
    localparam [3:0] CMD_ACTIVE = 4'b0011;
    localparam [3:0] CMD_READ = 4'b0101;
    localparam [3:0] CMD_WRITE = 4'b0100;
    localparam [3:0] CMD_PRECHARGE = 4'b0010;
    localparam [3:0] CMD_REFRESH = 4'b0001;
    localparam [3:0] CMD_MODE = 4'b0000;

    // Burst length 1, sequential, CAS latency CL, single-location writes.
    localparam [12:0] MODE = {6'b000000, CL[2:0], 4'b0000};

    // Timing in bus clocks at 75 MHz (13.3 ns): tRCD and tRP 15 ns, tRC and
    // tRFC 60 ns, tRAS 42 ns, tWR 2 clocks, tMRD 2 clocks. S_WAIT with
    // wait_count N puts N + 2 clocks between two commands: N = 0 gives two
    // (tRCD, tRP, tWR, tMRD), T_RC - 2 gives T_RC (tRC, tRFC). tRAS is
    // always met, the shortest access (a write) closing its row after seven.
    localparam integer T_RC = 5;
    localparam integer CAPTURE = CL + 2;

    localparam [3:0] S_INIT = 4'd0;
    localparam [3:0] S_INIT_PRE = 4'd1;
    localparam [3:0] S_INIT_REF = 4'd2;
    localparam [3:0] S_INIT_MODE = 4'd3;
    localparam [3:0] S_IDLE = 4'd4;
    localparam [3:0] S_ACTIVE = 4'd5;
    localparam [3:0] S_READ = 4'd6;
    localparam [3:0] S_WRITE = 4'd7;
    localparam [3:0] S_PRECHARGE = 4'd8;
    localparam [3:0] S_REFRESH = 4'd9;
    localparam [3:0] S_WAIT = 4'd10;
    localparam [3:0] S_VREAD = 4'd11;

    ODDR sdram_clk_oddr (
        .D0(1'b0),
        .D1(1'b1),
        .TX(1'b0),
        .CLK(clk),
        .Q0(sdram_clk),
        .Q1()
    );

    reg [15:0] dq_out = 16'd0;
    reg dq_oe = 1'b0;
    assign sdram_dq = dq_oe ? dq_out : 16'bz;

    reg [15:0] dq_fall = 16'd0;
    reg [15:0] dq_rise = 16'd0;
    always @(negedge clk)
        dq_fall <= sdram_dq;
    always @(posedge clk)
        dq_rise <= dq_fall;

    // The line buffer: 16 halfwords, line tag, a valid bit per doubleword.
    reg [255:0] line = 256'd0;
    reg [24:5] line_tag = 20'd0;
    reg line_tagged = 1'b0;
    reg [3:0] line_valid = 4'd0;

    // The access in progress.
    reg [3:0] state = S_INIT;
    reg [3:0] after_wait = S_IDLE;
    reg [15:0] wait_count = INIT_CYCLES[15:0];
    reg [6:0] step = 7'd0;
    reg op_write = 1'b0;
    reg op_video = 1'b0;
    reg video_pending = 1'b0;
    reg [24:3] op_addr = 22'd0;
    reg [7:0] op_lanes = 8'd0;
    reg [63:0] op_wdata = 64'd0;

    // Reads in flight: a valid bit, a video bit and the halfword index per
    // clock.
    reg [CAPTURE-1:0] pipe_valid = 0;
    reg [CAPTURE-1:0] pipe_video = 0;
    reg [6:0] pipe_index [0:CAPTURE-1];

    reg [9:0] refresh_count = 10'd0;
    reg refresh_due = 1'b0;

    wire idle = state == S_IDLE && pipe_valid == 0;
    wire line_hit = line_tagged && line_tag == addr[24:5];
    wire [3:0] read_index = {op_addr[4:3], 2'b00} + step[3:0];

    integer k;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_INIT;
            after_wait <= S_IDLE;
            wait_count <= INIT_CYCLES[15:0];
            step <= 7'd0;
            op_write <= 1'b0;
            op_video <= 1'b0;
            video_pending <= 1'b0;
            vvalid <= 1'b0;
            vindex <= 7'd0;
            vdata <= 16'd0;
            vdone <= 1'b0;
            ready <= 1'b0;
            ack <= 1'b0;
            rdata <= 64'd0;
            line_tagged <= 1'b0;
            line_valid <= 4'd0;
            pipe_valid <= 0;
            pipe_video <= 0;
            refresh_count <= 10'd0;
            refresh_due <= 1'b0;
            {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
            sdram_ba <= 2'd0;
            sdram_a <= 13'd0;
            sdram_dqm <= 2'b11;
            dq_oe <= 1'b0;
        end else begin
            ack <= 1'b0;
            {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_NOP;
            dq_oe <= 1'b0;
            sdram_dqm <= 2'b00;

            vvalid <= 1'b0;
            vdone <= 1'b0;
            if (vstart)
                video_pending <= 1'b1;

            pipe_valid <= {pipe_valid[CAPTURE-2:0], 1'b0};
            pipe_video <= {pipe_video[CAPTURE-2:0], 1'b0};
            for (k = CAPTURE - 1; k > 0; k = k - 1)
                pipe_index[k] <= pipe_index[k - 1];
            if (pipe_valid[CAPTURE-1] && pipe_video[CAPTURE-1]) begin
                vvalid <= 1'b1;
                vindex <= pipe_index[CAPTURE-1];
                vdata <= dq_rise;
                vdone <= pipe_index[CAPTURE-1] == 7'd127;
            end else if (pipe_valid[CAPTURE-1]) begin
                line[16 * pipe_index[CAPTURE-1][3:0] +: 16] <= dq_rise;
                if (pipe_index[CAPTURE-1][1:0] == 2'd3)
                    line_valid[pipe_index[CAPTURE-1][3:2]] <= 1'b1;
            end

            if (ready) begin
                if (refresh_count == REFRESH_CYCLES - 1) begin
                    refresh_count <= 10'd0;
                    refresh_due <= 1'b1;
                end else begin
                    refresh_count <= refresh_count + 1'b1;
                end
            end

            // Reads of the buffered line, even while the rest of it fills.
            if (req && !ack && !write && line_hit && line_valid[addr[4:3]]) begin
                ack <= 1'b1;
                rdata <= line[64 * addr[4:3] +: 64];
            end

            case (state)
                S_INIT: begin
                    if (wait_count == 0)
                        state <= S_INIT_PRE;
                    else
                        wait_count <= wait_count - 1'b1;
                end
                S_INIT_PRE: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_a[10] <= 1'b1;
                    step <= 7'd0;
                    wait_count <= 16'd0;
                    after_wait <= S_INIT_REF;
                    state <= S_WAIT;
                end
                S_INIT_REF: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
                    step <= step + 1'b1;
                    wait_count <= T_RC - 2;
                    after_wait <= step == 7'd7 ? S_INIT_MODE : S_INIT_REF;
                    state <= S_WAIT;
                end
                S_INIT_MODE: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_MODE;
                    sdram_ba <= 2'd0;
                    sdram_a <= MODE;
                    wait_count <= 16'd0;
                    after_wait <= S_IDLE;
                    state <= S_WAIT;
                end
                S_IDLE: begin
                    ready <= 1'b1;
                    if (refresh_due && pipe_valid == 0) begin
                        refresh_due <= 1'b0;
                        state <= S_REFRESH;
                    end else if ((video_pending || vstart) && idle) begin
                        video_pending <= 1'b0;
                        op_video <= 1'b1;
                        op_write <= 1'b0;
                        op_addr <= {vaddr, 5'd0};
                        state <= S_ACTIVE;
                    end else if (req && !ack && idle && (write || !line_hit)) begin
                        op_video <= 1'b0;
                        op_write <= write;
                        op_addr <= addr;
                        op_lanes <= lanes;
                        op_wdata <= wdata;
                        if (write) begin
                            ack <= 1'b1;
                            if (line_hit)
                                for (k = 0; k < 8; k = k + 1)
                                    if (lanes[k])
                                        line[64 * addr[4:3] + 8 * k +: 8] <= wdata[8 * k +: 8];
                        end else begin
                            line_tag <= addr[24:5];
                            line_tagged <= 1'b1;
                            line_valid <= 4'd0;
                        end
                        state <= S_ACTIVE;
                    end
                end
                S_ACTIVE: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_ACTIVE;
                    sdram_ba <= op_addr[11:10];
                    sdram_a <= op_addr[24:12];
                    step <= 7'd0;
                    wait_count <= 16'd0;
                    after_wait <= op_video ? S_VREAD : op_write ? S_WRITE : S_READ;
                    state <= S_WAIT;
                end
                S_READ: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                    sdram_a <= {4'b0000, op_addr[9:5], read_index};
                    pipe_valid[0] <= 1'b1;
                    pipe_index[0] <= {3'd0, read_index};
                    step <= step + 1'b1;
                    if (step == 7'd15)
                        state <= S_PRECHARGE;
                end
                S_VREAD: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_READ;
                    sdram_a <= {4'b0000, op_addr[9:8], step};
                    pipe_valid[0] <= 1'b1;
                    pipe_video[0] <= 1'b1;
                    pipe_index[0] <= step;
                    step <= step + 1'b1;
                    if (step == 7'd127)
                        state <= S_PRECHARGE;
                end
                S_WRITE: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_WRITE;
                    sdram_a <= {4'b0000, op_addr[9:3], step[1:0]};
                    sdram_dqm <= ~op_lanes[2 * step[1:0] +: 2];
                    dq_out <= op_wdata[16 * step[1:0] +: 16];
                    dq_oe <= 1'b1;
                    step <= step + 1'b1;
                    if (step == 7'd3) begin
                        // tWR: PRECHARGE two clocks after the last WRITE.
                        wait_count <= 16'd0;
                        after_wait <= S_PRECHARGE;
                        state <= S_WAIT;
                    end
                end
                S_PRECHARGE: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_PRECHARGE;
                    sdram_a[10] <= 1'b0;
                    sdram_ba <= op_addr[11:10];
                    wait_count <= 16'd0;
                    after_wait <= S_IDLE;
                    state <= S_WAIT;
                end
                S_REFRESH: begin
                    {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= CMD_REFRESH;
                    wait_count <= T_RC - 2;
                    after_wait <= S_IDLE;
                    state <= S_WAIT;
                end
                S_WAIT: begin
                    if (wait_count == 0)
                        state <= after_wait;
                    else
                        wait_count <= wait_count - 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
