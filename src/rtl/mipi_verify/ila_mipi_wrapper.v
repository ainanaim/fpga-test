`timescale 1ns / 1ps
// =============================================================================
//  ila_mipi_wrapper.v
//  MIPI CSI-2 Rx Output  -  ILA Probe Wrapper  (Layer 0)
// =============================================================================
//
//  PURPOSE
//  -------
//  Layer 0 of the MIPI data-path verification flow. Wraps the MIPI CSI-2
//  Receiver Subsystem IP's AXI4-Stream master output with an ILA so you can
//  observe the four signals that prove the link is alive, *before* writing
//  any processing logic. No data is consumed — tready is tied high so the
//  IP never backpressures (the stream is observed but otherwise unused).
//
//  WHAT TO CHECK IN THE ILA  (see wiki/12_OV5647_MIPI_CAMERA_PATH.md §11)
//  --------------------------------------------------------------------
//    1. Trigger on tvalid rising  -> link alive, sensor streaming.
//    2. Trigger on tuser[0] = 1   -> Frame Start packets decoded.
//    3. Count tlast between two tuser pulses -> row count matches resolution.
//    4. Inspect tdata             -> non-zero, varying, Bayer-patterned.
//    5. Watch for tready stalls   -> should be none (we tie it to 1).
//
//  CONNECTIONS IN THE BLOCK DESIGN
//  -------------------------------
//    [MIPI CSI-2 Rx IP]  m00_axis  ──>  [ila_mipi_wrapper]  s_axis
//                                                    │
//                                                    v
//                                                  [ILA core]
//
//  USAGE
//  -----
//  Instantiate this module in your block-design wrapper (or as the top for
//  a PL-only bring-up build) and connect s_axis_* to the MIPI Rx IP output.
//  The ILA is instantiated inside; after programming, open Hardware Manager
//  -> Run Trigger (ILA).
//
// =============================================================================

module ila_mipi_wrapper #(
    parameter DATA_W = 32,    // MIPI Rx IP TDATA width (8 for RAW8, 32 for RAW10 packed)
    parameter USER_W = 1      // TUSER width (bit 0 = SOF)
) (
    input  wire             aclk,
    input  wire             areset_n,

    // AXI4-Stream slave  (from MIPI CSI-2 Rx IP m00_axis)
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    input  wire              s_axis_tlast,
    input  wire [USER_W-1:0] s_axis_tuser,
    output wire              s_axis_tready
);
    // During bring-up we always accept — no backpressure.
    assign s_axis_tready = 1'b1;

    // -------------------------------------------------------------------------
    //  ILA instantiation
    //  Probe 0 : tdata   (DATA_W bits)
    //  Probe 1 : tvalid  (1 bit)
    //  Probe 2 : tlast   (1 bit)
    //  Probe 3 : tuser   (USER_W bits, bit 0 = SOF)
    //  Probe 4 : tready  (1 bit, always 1 — included so you can see it)
    //
    //  The ILA IP must be generated separately in Vivado (IP Catalog -> ila)
    //  with: C_NUM_OF_PROBES = 5, probe widths = (DATA_W,1,1,USER_W,1),
    //  C_DATA_DEPTH = 1024 (or deeper). Name it ila_0.
    // -------------------------------------------------------------------------
    ila_0 ila_inst (
        .clk     (aclk),
        .probe0  (s_axis_tdata),
        .probe1  (s_axis_tvalid),
        .probe2  (s_axis_tlast),
        .probe3  (s_axis_tuser),
        .probe4  (s_axis_tready)
    );

endmodule
