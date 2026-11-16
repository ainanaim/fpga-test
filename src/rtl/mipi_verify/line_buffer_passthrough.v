`timescale 1ns / 1ps
// =============================================================================
//  line_buffer_passthrough.v
//  MIPI CSI-2 Rx Output  -  Single-Line Buffer + Re-emit  (Layer 2)
// =============================================================================
//
//  PURPOSE
//  -------
//  Layer 2 of the MIPI data-path verification flow. Captures one row of
//  pixels from the MIPI CSI-2 Rx IP into a BRAM line buffer, then re-emits
//  the row on a second AXI4-Stream output. Proves the PL can *process*
//  (capture + store + replay) the video, not just passively receive it.
//
//  This is the minimal viable "the data moves properly" proof and the
//  foundation of every real video pipeline (line buffers feed sliding
//  windows, demosaic, filters, etc.).
//
//  ARCHITECTURE  (single-line, frame-dropping — fine for bring-up)
//  ---------------------------------------------------------------
//    State W (Wait)   : accept tvalid pixels, write to BRAM[wr_addr++]
//                       until tlast -> switch to E, propagate tuser (SOF)
//    State E (Emit)   : read BRAM[rd_addr++], assert m_tvalid
//                       until rd_addr == LINE-1 -> assert m_tlast, switch to F
//    State F (Flush)  : deassert m_tvalid/tlast/tuser, switch back to W
//
//  NOTE
//  ----
//  This module intentionally drops frames while emitting (it is a single-line
//  buffer, not a full frame buffer). That is acceptable for bring-up — you
//  are verifying the *path*, not building a product. For a real pipeline,
//  use a dual-line or full-frame buffer, or stream directly without buffering.
//
//  WHAT "DATA IS MOVING PROPERLY" LOOKS LIKE
//  -----------------------------------------
//  Put an ILA on BOTH the input (s_axis_*) and output (m_axis_*) sides.
//  If the input ILA shows a clean stream and the output ILA shows the SAME
//  stream (same pixel values, same row length, same frame rate), the PL has
//  proven it can receive, store, and re-emit MIPI video.
//
//  CONNECTIONS IN THE BLOCK DESIGN
//  -------------------------------
//    [MIPI CSI-2 Rx IP]  m00_axis  ──>  [line_buffer_passthrough]  s_axis
//                                                  │
//                                                  v
//                                        [ILA / downstream / display]
//
// =============================================================================

module line_buffer_passthrough #(
    parameter DATA_W = 32,         // tdata width (pixels)
    parameter LINE   = 1920,       // pixels per line (1080p -> 1920, 800x480 -> 800)
    parameter AW     = 11          // address width = $clog2(LINE); 11 covers up to 2048
) (
    input  wire              clk,
    input  wire              rst_n,    // active-low async reset

    // AXI4-Stream slave  (from MIPI CSI-2 Rx IP)
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    input  wire              s_axis_tlast,
    input  wire              s_axis_tuser,   // [0] = SOF
    output wire              s_axis_tready,

    // AXI4-Stream master  (to next stage / ILA / display)
    output reg  [DATA_W-1:0] m_axis_tdata,
    output reg               m_axis_tvalid,
    output reg               m_axis_tlast,
    output reg               m_axis_tuser,
    input  wire              m_axis_tready
);
    // -------------------------------------------------------------------------
    //  Simple dual-port RAM  (Course 1 Ch.6 pattern)
    //  Inferred as Block RAM by Vivado when LINE is large enough.
    // -------------------------------------------------------------------------
    reg [DATA_W-1:0] ram [LINE-1:0];
    reg [AW-1:0]     wr_addr;
    reg [AW-1:0]     rd_addr;

    // -------------------------------------------------------------------------
    //  FSM
    // -------------------------------------------------------------------------
    reg [1:0] state;
    localparam W = 2'd0,   // Wait  — capture incoming line
                E = 2'd1,   // Emit  — replay captured line
                F = 2'd2;   // Flush — one-cycle deassert then back to Wait

    // Only accept input while in Wait. While Emitting/Flushing, the upstream
    // is backpressured (s_axis_tready = 0). For bring-up with the MIPI Rx IP
    // this means some frames are dropped — acceptable.
    assign s_axis_tready = (state == W);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr     <= {AW{1'b0}};
            rd_addr     <= {AW{1'b0}};
            state       <= W;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            m_axis_tdata  <= {DATA_W{1'b0}};
        end
        else begin
            case (state)
                // -------------------------------------------------------------
                //  Wait — capture one line into BRAM
                // -------------------------------------------------------------
                W: begin
                    if (s_axis_tvalid) begin
                        ram[wr_addr] <= s_axis_tdata;
                        wr_addr <= wr_addr + 1'b1;
                        if (s_axis_tlast) begin
                            // Line captured. Prepare to replay it.
                            wr_addr <= {AW{1'b0}};
                            rd_addr <= {AW{1'b0}};
                            state   <= E;
                            // Propagate the SOF flag that rode on this line
                            // (tuser[0] is asserted on the first pixel of a
                            //  frame, which is also the first pixel of row 0).
                            m_axis_tuser <= s_axis_tuser;
                        end
                    end
                end

                // -------------------------------------------------------------
                //  Emit — replay the captured line from BRAM
                // -------------------------------------------------------------
                E: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= ram[rd_addr];
                    if (m_axis_tready) begin
                        rd_addr <= rd_addr + 1'b1;
                        if (rd_addr == (LINE - 1)) begin
                            m_axis_tlast <= 1'b1;
                            state        <= F;
                        end
                    end
                end

                // -------------------------------------------------------------
                //  Flush — deassert outputs for one cycle, then return to Wait
                // -------------------------------------------------------------
                F: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tuser  <= 1'b0;
                    state         <= W;
                end

                default: state <= W;
            endcase
        end
    end
endmodule
