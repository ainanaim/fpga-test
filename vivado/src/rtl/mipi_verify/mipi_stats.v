`timescale 1ns / 1ps
// =============================================================================
//  mipi_stats.v
//  MIPI CSI-2 Rx Output  -  Pixel / Line / Frame Counter  (Layer 1)
// =============================================================================
//
//  PURPOSE
//  -------
//  Passive monitor for the existing MIPI CSI-2 Rx to AXI4-Stream FIFO path.
//  Counts accepted transfers and exposes results through registers that can be
//  connected to AXI GPIO for UART readout, without requiring an ILA.
//
//  COUNTERS
//  --------
//  All events are qualified by an accepted AXI transfer (tvalid && tready).
//    beat_cnt         : cumulative accepted AXI beats
//    pixel_cnt        : cumulative represented pixels (PIXELS_PER_BEAT per beat)
//    line_cnt         : accepted TLAST events in the current frame
//    frame_cnt        : cumulative accepted SOF events
//    beats_last_line  : beats in the most recently completed line
//    lines_last_frame : lines in the frame preceding the latest SOF
//    beats_last_frame : beats in the frame preceding the latest SOF
//    sof_seen         : latched high after the first SOF
//
//  For 640x480 RAW10 at 4 pixels/clock, a complete frame has 160 beats/line,
//  480 lines/frame, and 76800 beats/frame. Wait for the second SOF after reset
//  before using the last-frame results.
//
//  CONNECTIONS IN THE BLOCK DESIGN
//  -------------------------------
//  Monitor the same signals as the CSI RX -> FIFO connection. The
//  s_axis_tready input must observe the real FIFO ready output; this module
//  does not drive ready. Connect selected counters to AXI GPIO for UART readout.
//
// =============================================================================

module mipi_stats #(
    parameter DATA_W = 40,          // CSI RX AXI4-Stream TDATA width
    parameter USER_W = 1,           // TUSER width (bit 0 = SOF)
    parameter PIXELS_PER_BEAT = 4,  // Active pixels in every accepted beat
    parameter CW     = 32           // Counter width
) (
    input  wire              clk,
    input  wire              rst_n,    // active-low async reset

    // Passive observation of the CSI RX -> FIFO AXI4-Stream interface
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    input  wire              s_axis_tlast,
    input  wire [USER_W-1:0] s_axis_tuser,
    input  wire              s_axis_tready,

    // Status counters — connect selected outputs to AXI GPIO
    output reg [CW-1:0] beat_cnt,
    output reg [CW-1:0] pixel_cnt,
    output reg [CW-1:0] line_cnt,
    output reg [CW-1:0] frame_cnt,
    output reg          sof_seen,
    output reg [CW-1:0] beats_last_line,
    output reg [CW-1:0] lines_last_frame,
    output reg [CW-1:0] beats_last_frame
);
    reg [CW-1:0] line_beat_cnt;
    reg [CW-1:0] frame_beat_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_cnt         <= {CW{1'b0}};
            pixel_cnt        <= {CW{1'b0}};
            line_cnt         <= {CW{1'b0}};
            frame_cnt        <= {CW{1'b0}};
            sof_seen         <= 1'b0;
            beats_last_line  <= {CW{1'b0}};
            lines_last_frame <= {CW{1'b0}};
            beats_last_frame <= {CW{1'b0}};
            line_beat_cnt    <= {CW{1'b0}};
            frame_beat_cnt   <= {CW{1'b0}};
        end
        else if (s_axis_tvalid && s_axis_tready) begin
            beat_cnt  <= beat_cnt + 1'b1;
            pixel_cnt <= pixel_cnt + PIXELS_PER_BEAT;

            if (s_axis_tuser[0]) begin
                // The current beat belongs to the new frame. Results latched
                // here describe the frame that has just finished.
                sof_seen         <= 1'b1;
                frame_cnt        <= frame_cnt + 1'b1;
                line_cnt         <= s_axis_tlast ? 1'b1 : {CW{1'b0}};
                lines_last_frame <= line_cnt;
                beats_last_frame <= frame_beat_cnt;
                frame_beat_cnt   <= 1'b1;

                // Recover line counting at SOF even if the previous line was
                // malformed. Normally the current beat is the first of 160.
                line_beat_cnt <= s_axis_tlast ? {CW{1'b0}} : 1'b1;
                if (s_axis_tlast) begin
                    beats_last_line <= 1'b1;
                end
            end
            else begin
                frame_beat_cnt <= frame_beat_cnt + 1'b1;

                if (s_axis_tlast) begin
                    line_cnt        <= line_cnt + 1'b1;
                    beats_last_line <= line_beat_cnt + 1'b1;
                    line_beat_cnt   <= {CW{1'b0}};
                end
                else begin
                    line_beat_cnt <= line_beat_cnt + 1'b1;
                end
            end
        end
    end
endmodule
