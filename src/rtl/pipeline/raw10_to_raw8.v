`timescale 1ns / 1ps
// =============================================================================
//  raw10_to_raw8.v
//  RAW10 -> RAW8 AXI4-Stream down-converter (4 pixels/clock, both sides)
// =============================================================================
//
//  PURPOSE
//  -------
//  Bring-up stage for the capture path: drops the 2 LSBs of each RAW10 pixel
//  so the stream can feed 8-bit video IP (v_frmbuf_wr as Y8, later v_demosaic
//  at 8 bpc) with byte-aligned TDATA and no padding anywhere.
//
//  INPUT FORMAT  (CSI-2 Rx subsystem video_out, RAW10, 4 px/clk)
//  -------------------------------------------------------------
//  Per-pixel zero-padded 10-bit fields, NOT MIPI wire packing:
//    s_axis_tdata[9:0]   = pixel 0
//    s_axis_tdata[19:10] = pixel 1
//    s_axis_tdata[29:20] = pixel 2
//    s_axis_tdata[39:30] = pixel 3
//  (40 bits = 5 bytes; no padding needed at 4 px/clk.)
//  Confirmed against openISP kv260 m0/m3 build.tcl (measured on board) and the
//  PG286 Bayer input convention. The MIPI 4px/5B packing in PG232 describes the
//  CSI-2 packet payload on the wire, not this interface.
//
//  OUTPUT FORMAT (RAW8, 4 px/clk, 32 bits = 4 bytes)
//  ------------------------------------------------
//    m_axis_tdata[7:0]   = pixel 0 [9:2]
//    m_axis_tdata[15:8]  = pixel 1 [9:2]
//    m_axis_tdata[23:16] = pixel 2 [9:2]
//    m_axis_tdata[31:24] = pixel 3 [9:2]
//
//  Handshake: single register slice, full throughput when downstream accepts.
//  tlast / tuser pass through unchanged (line / frame boundaries preserved).
// =============================================================================

module raw10_to_raw8 (
    input  wire        clk,
    input  wire        rst_n,          // active-low async reset

    input  wire [39:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // bit 0 = SOF

    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser
);

    reg        valid_q;
    reg [31:0] data_q;
    reg        last_q;
    reg        user_q;

    // Accept a new beat whenever the output register is empty or draining.
    assign s_axis_tready = !valid_q || m_axis_tready;

    assign m_axis_tvalid = valid_q;
    assign m_axis_tdata  = data_q;
    assign m_axis_tlast  = last_q;
    assign m_axis_tuser  = user_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
            data_q  <= 32'b0;
            last_q  <= 1'b0;
            user_q  <= 1'b0;
        end
        else if (s_axis_tready) begin
            valid_q <= s_axis_tvalid;
            data_q  <= {s_axis_tdata[39:32],   // pixel 3 [9:2]
                        s_axis_tdata[29:22],   // pixel 2 [9:2]
                        s_axis_tdata[19:12],   // pixel 1 [9:2]
                        s_axis_tdata[9:2]};    // pixel 0 [9:2]
            last_q  <= s_axis_tlast;
            user_q  <= s_axis_tuser;
        end
    end

endmodule
