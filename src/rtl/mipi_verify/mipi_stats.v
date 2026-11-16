`timescale 1ns / 1ps
// =============================================================================
//  mipi_stats.v
//  MIPI CSI-2 Rx Output  -  Pixel / Line / Frame Counter  (Layer 1)
// =============================================================================
//
//  PURPOSE
//  -------
//  Layer 1 of the MIPI data-path verification flow. Counts what it receives
//  on the MIPI CSI-2 Rx IP's AXI4-Stream output. The single most useful
//  bring-up module: if the counters behave, the stream is real and complete.
//
//  COUNTERS
//  --------
//    pixel_cnt  : increments on every tvalid cycle (every pixel received)
//    line_cnt   : increments on every tlast        (every row received)
//    frame_cnt  : increments on every tuser[0]    (every frame received)
//    sof_seen   : latched high after the first SOF — proves at least one
//                 complete frame was observed
//
//  WHAT "DATA IS MOVING PROPERLY" LOOKS LIKE  (read via ILA)
//  ---------------------------------------------------------
//    frame_cnt  : ticks at the frame rate (~30/s for 30 fps)
//    line_cnt   : resets to 0 at each SOF, reaches the row count
//                 (1080 for 1080p, 480 for 800x480, etc.) just before
//                 the next SOF — proves every row of every frame is received
//    pixel_cnt  : increments monotonically — proves no pixels are dropped
//    sof_seen   : goes high on the first frame and stays high
//
//  FAILURE MODES THIS MODULE SURFACES
//  ----------------------------------
//    line_cnt reaches half the expected value  -> losing rows (tlast misconfig
//                                                  or tready stall dropping data)
//    frame_cnt never increments                -> FS short packets not decoded
//    pixel_cnt never increments                -> tvalid never asserts (link dead)
//    sof_seen never sets                       -> no SOF received (check VC config)
//
//  CONNECTIONS IN THE BLOCK DESIGN
//  -------------------------------
//    [MIPI CSI-2 Rx IP]  m00_axis  ──>  [mipi_stats]  s_axis
//                                                  │
//                                                  v
//                                                [ILA on counters]
//
// =============================================================================

module mipi_stats #(
    parameter DATA_W = 32,    // MIPI Rx IP TDATA width
    parameter USER_W = 1,     // TUSER width (bit 0 = SOF)
    parameter CW     = 32     // counter width — 32 bits holds ~24 h of 200 MHz cycles
) (
    input  wire              clk,
    input  wire              rst_n,    // active-low async reset (matches ALINX PL key)

    // AXI4-Stream slave  (from MIPI CSI-2 Rx IP m00_axis)
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    input  wire              s_axis_tlast,
    input  wire [USER_W-1:0] s_axis_tuser,
    output wire              s_axis_tready,

    // Status counters — attach ILA here
    output reg [CW-1:0] pixel_cnt,
    output reg [CW-1:0] line_cnt,
    output reg [CW-1:0] frame_cnt,
    output reg          sof_seen
);
    // During bring-up we always accept — no backpressure.
    // Replace with a FIFO or downstream-consumer tready when integrating.
    assign s_axis_tready = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_cnt <= {CW{1'b0}};
            line_cnt  <= {CW{1'b0}};
            frame_cnt <= {CW{1'b0}};
            sof_seen  <= 1'b0;
        end
        else if (s_axis_tvalid) begin
            // Count every valid pixel cycle.
            pixel_cnt <= pixel_cnt + 1'b1;

            // Start of Frame: latch flag, count the frame, reset line counter.
            if (s_axis_tuser[0]) begin
                sof_seen  <= 1'b1;
                frame_cnt <= frame_cnt + 1'b1;
                line_cnt  <= {CW{1'b0}};
            end

            // End of Line: count the row.
            // (Comes after the SOF check so the SOF-driven line_cnt reset wins
            //  if both tuser and tlast ever coincide on the same cycle.)
            if (s_axis_tlast) begin
                line_cnt <= line_cnt + 1'b1;
            end
        end
    end
endmodule
