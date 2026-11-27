`timescale 1ns / 1ps
// =============================================================================
//  raw10_to_raw8_tb.v — self-checking testbench
// =============================================================================
//  Drives known RAW10 pixel patterns (per-pixel 10-bit fields, 4 px/clk) with
//  random source gaps and random sink back-pressure, and checks every accepted
//  output beat: pixel values (>>2), tlast (every 160 beats = 640 px line) and
//  tuser (SOF every 640 beats = 4-line test frame). Any mismatch, loss or
//  duplication fails the run.
//
//  Run:  iverilog -o raw10_tb.vvp raw10_to_raw8.v raw10_to_raw8_tb.v && vvp raw10_tb.vvp
// =============================================================================

module raw10_to_raw8_tb;

    localparam BEATS       = 2000;   // total beats driven
    localparam BEATS_LINE  = 160;    // 640 px / 4 px per beat
    localparam BEATS_FRAME = 640;    // 4-line test frame

    reg         clk = 0;
    reg         rst_n = 0;
    wire [39:0] s_tdata;
    wire        s_tvalid;
    wire        s_tready;
    wire        s_tlast;
    wire        s_tuser;
    wire [31:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready = 0;
    wire        m_tlast;
    wire        m_tuser;

    raw10_to_raw8 dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser)
    );

    always #5 clk = ~clk;

    // Deterministic pseudo-random stimulus / back-pressure
    reg [15:0] lfsr_src = 16'hACE1;
    reg [15:0] lfsr_snk = 16'h1234;
    always @(posedge clk) begin
        lfsr_src <= {lfsr_src[14:0], lfsr_src[15] ^ lfsr_src[13] ^ lfsr_src[12] ^ lfsr_src[10]};
        lfsr_snk <= {lfsr_snk[14:0], lfsr_snk[15] ^ lfsr_snk[13] ^ lfsr_snk[12] ^ lfsr_snk[10]};
    end

    function [9:0] pixel(input integer i);
        begin
            case (i)
                0: pixel = 10'd0;
                1: pixel = 10'd1023;
                2: pixel = 10'd512;
                3: pixel = 10'd1;
                4: pixel = 10'd1020;
                5: pixel = 10'd3;
                default: pixel = (i * 1013 + 77) & 1023;
            endcase
        end
    endfunction

    integer sent = 0;
    integer recv = 0;
    integer errors = 0;
    integer k;
    reg [7:0] expect_byte;

    // Source: stimulus is a pure function of `sent` so data and index can never
    // skew; only the counter is registered.
    assign s_tdata  = {pixel(sent * 4 + 3), pixel(sent * 4 + 2),
                       pixel(sent * 4 + 1), pixel(sent * 4 + 0)};
    assign s_tlast  = ((sent % BEATS_LINE) == BEATS_LINE - 1);
    assign s_tuser  = ((sent % BEATS_FRAME) == 0);
    assign s_tvalid = rst_n && (sent < BEATS) && lfsr_src[0];

    always @(posedge clk) begin
        if (rst_n && s_tvalid && s_tready) sent <= sent + 1;
    end

    // Sink: random back-pressure
    always @(posedge clk) begin
        if (rst_n) m_tready <= lfsr_snk[1];
    end

    // Checker: every accepted output beat must match the expected sequence
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            for (k = 0; k < 4; k = k + 1) begin
                expect_byte = pixel(recv * 4 + k) >> 2;
                if (m_tdata[k*8 +: 8] !== expect_byte) begin
                    errors = errors + 1;
                    $display("FAIL beat %0d pixel %0d: got %02x expected %02x",
                             recv, k, m_tdata[k*8 +: 8], expect_byte);
                end
            end
            if (m_tlast !== ((recv % BEATS_LINE) == BEATS_LINE - 1)) begin
                errors = errors + 1;
                $display("FAIL beat %0d: tlast=%b", recv, m_tlast);
            end
            if (m_tuser !== ((recv % BEATS_FRAME) == 0)) begin
                errors = errors + 1;
                $display("FAIL beat %0d: tuser=%b", recv, m_tuser);
            end
            recv = recv + 1;
        end
    end

    // Watchdog + finish
    initial begin
        #20 rst_n = 1;
        wait (recv == BEATS);
        #50;
        if (errors == 0 && sent == BEATS)
            $display("PASS: %0d beats, %0d pixels checked, no loss/duplication under back-pressure",
                     recv, recv * 4);
        else
            $display("FAIL: errors=%0d sent=%0d recv=%0d", errors, sent, recv);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: timeout (sent=%0d recv=%0d)", sent, recv);
        $finish;
    end

endmodule
