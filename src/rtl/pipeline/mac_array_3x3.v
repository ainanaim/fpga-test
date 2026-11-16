`timescale 1ns / 1ps
// =============================================================================
//  mac_array_3x3.v
//  3x3 Multiply-Accumulate (MAC) Array  -  CNN Convolution Kernel
// =============================================================================
//
//  PURPOSE
//  -------
//  Core compute unit for one output channel of a CNN convolutional layer.
//  For every 3x3 pixel neighborhood arriving from the upstream sliding-window
//  module, computes:
//
//      output = ReLU( sum(pixel[i] * weight[i], i=0..8) + bias )
//
//  PIPELINE ARCHITECTURE  (5 clock cycles latency, 1 result/cycle throughput)
//
//    Cycle 1 | Stage 1 | Input registration
//    Cycle 2 | Stage 2 | 9x parallel INT8 x INT8 multiplications  (DSP48)
//    Cycle 3 | Stage 3 | Adder tree level 1  (9 products -> 5 terms)
//    Cycle 4 | Stage 4 | Adder tree level 2  (5 terms   -> 3 terms)
//    Cycle 5 | Stage 5 | Final sum + bias + ReLU + saturation -> output
//
//  DATA TYPES
//  ----------
//    pixels   : unsigned  8-bit  (0..255)       from image sensor
//    weights  : signed    8-bit  (-128..127)    CNN layer parameters
//    products : signed   17-bit                 pixel * weight
//    bias     : signed   32-bit                 CNN layer parameter
//    accum    : signed   32-bit                 sum-of-products + bias
//    output   : unsigned  8-bit                 after ReLU + saturation
//
//  RESOURCE ESTIMATE (Xilinx Zynq-7020 XC7Z020, 100 MHz target)
//  ---------------------------------------------------------------
//    DSP48E1 slices : 9   (one per multiplier, tool-inferred via use_dsp attr)
//    LUTs           : ~80
//    Flip-flops     : ~380
//    BRAM           : 0
//
//  CONNECTIONS IN THE VIDEO PIPELINE
//  -----------------------------------
//
//    [Camera / DMA]
//         |
//    [Sliding Window Module]   <- provides the 9-pixel 3x3 neighborhood
//         |  p00..p22 (9 pixels)
//         v
//    [mac_array_3x3]  <-- w00..w22 from weight BRAM, bias from bias reg
//         |  m_data (1 pixel output)
//         v
//    [Next pipeline stage / HDMI display]
//
// =============================================================================

module mac_array_3x3 #(
    parameter DATA_W   = 8,    // pixel and output bit-width (unsigned)
    parameter WEIGHT_W = 8,    // weight bit-width (signed)
    parameter ACCUM_W  = 32    // accumulator and bias bit-width (signed)
) (
    input  wire clk,
    input  wire rst,            // synchronous, active-high reset

    // -------------------------------------------------------------------------
    //  Valid handshake
    //  s_valid is asserted when a new 3x3 window is presented on the inputs.
    //  m_valid is asserted exactly 5 clock cycles later, aligned with m_data.
    //  No backpressure (TREADY) in this module — the pipeline never stalls.
    //  Insert a FIFO upstream if the source can outrun the pipeline.
    // -------------------------------------------------------------------------
    input  wire s_valid,
    output wire m_valid,

    // -------------------------------------------------------------------------
    //  3x3 Pixel window  (unsigned INT8)
    //  Naming: p[row][col], row 0 = topmost (oldest) line in the line buffer.
    //  These 9 values come simultaneously from the sliding-window module.
    // -------------------------------------------------------------------------
    input  wire [DATA_W-1:0] p00, p01, p02,   // top row    (oldest line)
    input  wire [DATA_W-1:0] p10, p11, p12,   // middle row
    input  wire [DATA_W-1:0] p20, p21, p22,   // bottom row (current pixel)

    // -------------------------------------------------------------------------
    //  3x3 Kernel weights  (signed INT8)
    //  One set of 9 weights per output channel.  In a multi-channel CNN layer,
    //  you would instantiate one mac_array_3x3 per output channel (or
    //  time-multiplex a single instance across channels).
    //  These are stable for the entire duration of a feature map — they come
    //  from a BRAM weight store loaded once per layer.
    // -------------------------------------------------------------------------
    input  wire signed [WEIGHT_W-1:0] w00, w01, w02,
    input  wire signed [WEIGHT_W-1:0] w10, w11, w12,
    input  wire signed [WEIGHT_W-1:0] w20, w21, w22,

    // -------------------------------------------------------------------------
    //  Bias  (signed INT32)
    //  One scalar per output channel, added after the MAC accumulation.
    // -------------------------------------------------------------------------
    input  wire signed [ACCUM_W-1:0] bias,

    // -------------------------------------------------------------------------
    //  Output  (unsigned INT8, after ReLU and saturation)
    // -------------------------------------------------------------------------
    output reg [DATA_W-1:0] m_data
);

// =============================================================================
//  LOCAL PARAMETERS  -  derived bit widths, computed at synthesis time
// =============================================================================

// Unsigned pixels must be sign-extended by ONE zero bit before multiplication
// so the synthesiser treats them as positive signed numbers.
//   e.g.  8'hFF (255 unsigned) -> 9'h0FF (+255 signed)  (correct)
//   Without this:  8'hFF * signed_weight would sign-extend to -1 (wrong!)
localparam PIX_SX  = DATA_W   + 1;          //  9  signed pixel width
localparam PROD_W  = PIX_SX   + WEIGHT_W;   // 17  product width (9+8)
localparam SUM1_W  = PROD_W   + 1;          // 18  level-1 pair sum
localparam SUM2_W  = SUM1_W   + 1;          // 19  level-2 pair sum

// Saturation ceiling for ReLU output: 2^DATA_W - 1 = 255
// Expressed as a signed 32-bit constant so comparisons are signed-clean.
localparam signed [ACCUM_W-1:0] SAT_MAX =
    {{(ACCUM_W - DATA_W){1'b0}}, {DATA_W{1'b1}}};   // 32'h0000_00FF = 255


// =============================================================================
//  VALID SHIFT REGISTER
//
//  s_valid shifts through 5 flip-flops, one per pipeline stage.
//  Because the pipeline never stalls (no TREADY), valid simply follows
//  the data with a fixed 5-cycle delay.
// =============================================================================

reg [4:0] valid_sr;

always @(posedge clk) begin
    if (rst) valid_sr <= 5'b0;
    else     valid_sr <= {valid_sr[3:0], s_valid};
end

assign m_valid = valid_sr[4];   // asserted when m_data is valid


// =============================================================================
//  STAGE 1  -  Input Registration
//
//  Absorbs routing delay from the upstream sliding-window module so it
//  does not eat into the multiply's timing budget.
//
//  KEY: pixels are zero-extended from DATA_W to PIX_SX bits here.
//  "{1'b0, p00}" concatenates a literal 0-bit in front of the 8-bit pixel,
//  producing a 9-bit value whose sign bit (MSB) is always 0 -> positive.
// =============================================================================

reg signed [PIX_SX-1:0]   s1_p00, s1_p01, s1_p02;
reg signed [PIX_SX-1:0]   s1_p10, s1_p11, s1_p12;
reg signed [PIX_SX-1:0]   s1_p20, s1_p21, s1_p22;

reg signed [WEIGHT_W-1:0] s1_w00, s1_w01, s1_w02;
reg signed [WEIGHT_W-1:0] s1_w10, s1_w11, s1_w12;
reg signed [WEIGHT_W-1:0] s1_w20, s1_w21, s1_w22;

reg signed [ACCUM_W-1:0]  s1_bias;

always @(posedge clk) begin
    // Zero-extend unsigned pixels -> positive signed (prepend '0' MSB)
    s1_p00 <= {1'b0, p00};  s1_p01 <= {1'b0, p01};  s1_p02 <= {1'b0, p02};
    s1_p10 <= {1'b0, p10};  s1_p11 <= {1'b0, p11};  s1_p12 <= {1'b0, p12};
    s1_p20 <= {1'b0, p20};  s1_p21 <= {1'b0, p21};  s1_p22 <= {1'b0, p22};

    // Weights pass through unchanged (already declared signed)
    s1_w00 <= w00;  s1_w01 <= w01;  s1_w02 <= w02;
    s1_w10 <= w10;  s1_w11 <= w11;  s1_w12 <= w12;
    s1_w20 <= w20;  s1_w21 <= w21;  s1_w22 <= w22;

    s1_bias <= bias;
end


// =============================================================================
//  STAGE 2  -  9x Parallel Multiplications
//
//  All 9 multiplications execute simultaneously in dedicated hardware.
//  Signed (9-bit) x signed (8-bit) = signed 17-bit result.
//
//  FPGA MAPPING:
//  Vivado maps each registered multiply whose operands fit within 25x18 bits
//  to one DSP48E1 slice automatically.  The (* use_dsp = "yes" *) attribute
//  is an explicit hint: never fall back to LUT-based multiplication.
//  Verify in Vivado: Reports -> Utilization Summary -> DSP column.
//
//  At 100 MHz on Zynq-7020 this stage uses exactly 9 DSP48E1 slices
//  (9 out of 220 available = 4%).
// =============================================================================

(* use_dsp = "yes" *) reg signed [PROD_W-1:0] s2_m00, s2_m01, s2_m02;
(* use_dsp = "yes" *) reg signed [PROD_W-1:0] s2_m10, s2_m11, s2_m12;
(* use_dsp = "yes" *) reg signed [PROD_W-1:0] s2_m20, s2_m21, s2_m22;

reg signed [ACCUM_W-1:0] s2_bias;

always @(posedge clk) begin
    // 9 concurrent multiplications — each becomes one DSP48E1 slice
    s2_m00 <= s1_p00 * s1_w00;   s2_m01 <= s1_p01 * s1_w01;
    s2_m02 <= s1_p02 * s1_w02;

    s2_m10 <= s1_p10 * s1_w10;   s2_m11 <= s1_p11 * s1_w11;
    s2_m12 <= s1_p12 * s1_w12;

    s2_m20 <= s1_p20 * s1_w20;   s2_m21 <= s1_p21 * s1_w21;
    s2_m22 <= s1_p22 * s1_w22;

    s2_bias <= s1_bias;
end


// =============================================================================
//  STAGE 3  -  Adder Tree Level 1  (9 products -> 5 terms)
//
//  Pairwise addition of adjacent products.  Adding two N-bit signed values
//  requires N+1 bits to hold the carry without overflow.
//
//    Pair A : m00 + m01  (17+17 -> 18-bit result)
//    Pair B : m02 + m10
//    Pair C : m11 + m12
//    Pair D : m20 + m21
//    Lone E : m22         (no partner; sign-extended 17->18 and passed through)
//
//  WHY pair this way (not a sequential chain)?
//  A sequential chain (((m00+m01)+m02)+m03...)  has 8 adders in series ->
//  very long critical path.  A tree halves depth each level:
//    Level 1: 4 adders in parallel  (9->5 terms)
//    Level 2: 2 adders in parallel  (5->3 terms)
//    Final  : combined in stage 5
// =============================================================================

reg signed [SUM1_W-1:0] s3_a, s3_b, s3_c, s3_d;
reg signed [SUM1_W-1:0] s3_e;           // passthrough, sign-extended 17->18
reg signed [ACCUM_W-1:0] s3_bias;

always @(posedge clk) begin
    s3_a <= s2_m00 + s2_m01;
    s3_b <= s2_m02 + s2_m10;
    s3_c <= s2_m11 + s2_m12;
    s3_d <= s2_m20 + s2_m21;
    // Sign-extend the lone product from PROD_W (17) to SUM1_W (18) bits.
    // "{{N{sign_bit}}, value}" is Verilog's sign-extension idiom.
    s3_e <= {{(SUM1_W - PROD_W){s2_m22[PROD_W-1]}}, s2_m22};

    s3_bias <= s2_bias;
end


// =============================================================================
//  STAGE 4  -  Adder Tree Level 2  (5 terms -> 3 terms)
//
//    F = A + B  (18+18 -> 19-bit)
//    G = C + D  (18+18 -> 19-bit)
//    H = E      (passthrough, sign-extended 18->19-bit)
//
//  After this stage we have 3 terms left.  They are combined in Stage 5.
// =============================================================================

reg signed [SUM2_W-1:0] s4_f, s4_g, s4_h;
reg signed [ACCUM_W-1:0] s4_bias;

always @(posedge clk) begin
    s4_f <= s3_a + s3_b;
    s4_g <= s3_c + s3_d;
    s4_h <= {{(SUM2_W - SUM1_W){s3_e[SUM1_W-1]}}, s3_e};  // sign-extend 18->19

    s4_bias <= s3_bias;
end


// =============================================================================
//  STAGE 5  -  Final Sum + Bias + ReLU + Saturation  ->  8-bit output
//
//  5a. Sign-extend F, G, H to ACCUM_W (32 bits) before adding.
//      This prevents overflow when summing numbers of different widths.
//
//  5b. Sum all three terms and add the bias.
//      mac_sum and mac_biased are WIRES (combinational), not registers.
//      The final result is registered in the output flip-flop below.
//
//  5c. ReLU activation:
//      If the MSB (sign bit) of mac_biased is 1, the value is negative.
//      ReLU maps all negatives to 0: max(0, x).
//
//  5d. Saturation:
//      If mac_biased > 255 (SAT_MAX), output 255 instead of wrapping.
//      Without this, a value of 256 would output 0 (wrong).
//
//  5e. Normal case: take the lower DATA_W bits of the 32-bit accumulator.
//
//  NOTE ON TIMING:
//  mac_biased is two combinational additions (3-way + bias) before the
//  output register.  At 100 MHz (10 ns) this is fine.  At 150+ MHz you
//  should split this into two registered stages (6 cycles total latency).
// =============================================================================

// Sign-extend all three stage-4 terms to full ACCUM_W width
wire signed [ACCUM_W-1:0] f_ext = {{(ACCUM_W-SUM2_W){s4_f[SUM2_W-1]}}, s4_f};
wire signed [ACCUM_W-1:0] g_ext = {{(ACCUM_W-SUM2_W){s4_g[SUM2_W-1]}}, s4_g};
wire signed [ACCUM_W-1:0] h_ext = {{(ACCUM_W-SUM2_W){s4_h[SUM2_W-1]}}, s4_h};

// Combinational: sum of products, then add bias
wire signed [ACCUM_W-1:0] mac_sum    = f_ext + g_ext + h_ext;
wire signed [ACCUM_W-1:0] mac_biased = mac_sum + s4_bias;

// Registered output with ReLU activation and saturation
always @(posedge clk) begin
    if (rst) begin
        m_data <= {DATA_W{1'b0}};
    end else begin
        if (mac_biased[ACCUM_W-1]) begin
            // Sign bit = 1 -> negative value -> ReLU clamps to 0
            m_data <= {DATA_W{1'b0}};          // 8'h00
        end else if (mac_biased > SAT_MAX) begin
            // Positive overflow -> saturate to maximum (255)
            m_data <= {DATA_W{1'b1}};          // 8'hFF
        end else begin
            // Normal range [0, 255]: lower 8 bits are the output
            m_data <= mac_biased[DATA_W-1:0];
        end
    end
end

endmodule
