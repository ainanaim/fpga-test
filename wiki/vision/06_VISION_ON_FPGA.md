# 06 — Vision on FPGAs

> The practical guide to building image and video processing pipelines on FPGA hardware — from pixel formats to CNN inference.

---

## Table of Contents
1. [How Images are Represented Digitally](#1-how-images-are-represented-digitally)
2. [Video Timing Signals](#2-video-timing-signals)
3. [The FPGA Vision Pipeline Architecture](#3-the-fpga-vision-pipeline-architecture)
4. [Core Image Processing Operations](#4-core-image-processing-operations)
5. [Spatial Filtering and Convolution on FPGAs](#5-spatial-filtering-and-convolution-on-fpgas)
6. [Color Space Conversions](#6-color-space-conversions)
7. [Feature Detection Algorithms](#7-feature-detection-algorithms)
8. [Deep Learning Inference on FPGAs](#8-deep-learning-inference-on-fpgas)
9. [Algorithm Complexity vs FPGA Resources](#9-algorithm-complexity-vs-fpga-resources)
10. [Open-Source IP Cores for Vision](#10-open-source-ip-cores-for-vision)
11. [Image Processing vs Video Processing — What Changes](#11-image-processing-vs-video-processing--what-changes)
12. [Fixed-Point Arithmetic for Image Processing](#12-fixed-point-arithmetic-for-image-processing)
13. [ISP Pipeline — Camera RAW to Displayable Output](#13-isp-pipeline--camera-raw-to-displayable-output)
14. [Morphological Operations](#14-morphological-operations)
15. [Real-Time Timing Budget Analysis](#15-real-time-timing-budget-analysis)
16. [Pipeline Flow Control and Backpressure](#16-pipeline-flow-control-and-backpressure)
17. [Histogram and Statistics Operations](#17-histogram-and-statistics-operations)
18. [Debugging Vision Pipelines on FPGA](#18-debugging-vision-pipelines-on-fpga)

---

## 1. How Images are Represented Digitally

### Pixel Formats

| Format | Bits/pixel | Channel layout | FPGA use |
|--------|-----------|----------------|---------|
| Grayscale (Y) | 8 or 10 | Single channel | Most processing algorithms |
| RGB888 | 24 | R[7:0] G[7:0] B[7:0] | Display output |
| BGR | 24 | B, G, R order | OpenCV default (not relevant on FPGA) |
| YCbCr 4:4:4 | 24 | Y[8] Cb[8] Cr[8] | Professional video |
| YCbCr 4:2:2 | 16 | Y0 Cb Y1 Cr interleaved | HDMI, compressed |
| RAW Bayer | 8/10/12 | RGGB pattern | Direct from camera sensor |
| RGB565 | 16 | R[4:0] G[5:0] B[4:0] | Embedded displays |
| RGB1010102 | 32 | R[10] G[10] B[10] | HDR |

### Bayer Pattern (What Camera Sensors Actually Output)

Most camera sensors use a **Bayer color filter array**:

```
R  G  R  G  R  G
G  B  G  B  G  B
R  G  R  G  R  G
G  B  G  B  G  B
```

Each pixel has only ONE color. The other two must be **interpolated** from neighbors — this is called **demosaicing** (or debayering). The Bayer pattern used (RGGB, BGGR, GRBG, GBRG) depends on the specific sensor.

**Demosaicing is typically the first processing step** in a camera pipeline, before any other image processing.

### Common Image Resolutions

| Name | Width × Height | Pixels | Frame size (RGB24) |
|------|----------------|--------|--------------------|
| QVGA | 320 × 240 | 76.8K | 230 KB |
| VGA | 640 × 480 | 307K | 922 KB |
| 720p | 1280 × 720 | 921K | 2.76 MB |
| 1080p (FHD) | 1920 × 1080 | 2.07M | 6.22 MB |
| 4K (UHD) | 3840 × 2160 | 8.29M | 24.9 MB |

**Note**: Even 720p frames at ~2.76 MB do not fit in BRAM (most FPGAs have 2–8 Mb = 0.25–1 MB). DDR is required for full-frame buffering.

---

## 2. Video Timing Signals

### Traditional VGA/HDMI Timing

Video signals include both visible and blanking periods:

```
Horizontal timing (one scan line):
|<────── Active ──────>|<── Front ──>|< Sync >|<── Back ──>|
     visible pixels       porch               porch

Vertical timing (one frame):
|<────── Active ──────>|<── Front ──>|< Sync >|<── Back ──>|
      visible lines        porch               porch
```

For 1920×1080 @ 60 Hz:
- H total: 2200 pixels (1920 visible + 280 blanking)
- V total: 1125 lines (1080 visible + 45 blanking)
- Pixel clock: 148.5 MHz

### Key Video Signals in FPGA Designs

| Signal | Description |
|--------|-------------|
| `pclk` | Pixel clock — one rising edge per pixel |
| `vsync` | Vertical sync — one pulse per frame |
| `hsync` | Horizontal sync — one pulse per line |
| `de` or `active` | Data Enable — high during visible pixels only |
| `pixel_data` | The actual pixel value |

### AXI4-Stream Video Convention (Xilinx)

Modern Xilinx video IP uses AXI4-Stream instead of raw sync signals:
- `TVALID` = DE (data enable)
- `TLAST` = end of line (EOL)
- `TUSER[0]` = start of frame (SOF) — asserted on first pixel of frame only

---

## 3. The FPGA Vision Pipeline Architecture

### Generic Pipeline Structure

```
                                     ┌──────────────────────────────────────────┐
                                     │          FPGA FABRIC                      │
                                     │                                           │
  ┌────────────┐  MIPI/parallel      │  ┌──────────┐  ┌──────────┐  ┌───────┐  │
  │  Camera    │─────────────────────►  │  Sensor  │  │ Debayer  │  │ Color │  │
  │  Sensor    │                     │  │  IF      ├─►│ (Bayer   ├─►│ Conv. │  │
  └────────────┘                     │  │  (MIPI   │  │ →RGB)    │  │ (RGB  │  │
                                     │  │  Rx)     │  └──────────┘  │ →YCbCr│  │
                                     │  └──────────┘                └───┬───┘  │
                                     │                                   │      │
                                     │  ┌───────────────────────────────▼───┐  │
                                     │  │          Processing Pipeline        │  │
                                     │  │  ┌────────┐ ┌────────┐ ┌────────┐ │  │
                                     │  │  │ Filter │►│ Detect │►│  Post  │ │  │
                                     │  │  │ (blur, │ │(edges, │ │process │ │  │
                                     │  │  │ noise) │ │ canny) │ │(scale, │ │  │
                                     │  │  └────────┘ └────────┘ │overlay)│ │  │
                                     │  │                         └────────┘ │  │
                                     │  └───────────────────────────────┬───┘  │
                                     │                                   │      │
                                     │  ┌──────────┐  ┌──────────┐      │      │
                                     │  │  HDMI TX │  │  AXI DMA │◄─────┘      │
                                     │  │  (display│  │  (to DDR │             │
                                     │  │  output) │  │  or Host)│             │
                                     │  └──────────┘  └──────────┘             │
                                     └──────────────────────────────────────────┘
                                                │                │
                                            Monitor           Host PC /
                                                              ARM CPU
```

### Pixel Counter Pattern (Essential)

Every vision module needs to track its position in the frame:

```systemverilog
module pixel_position_tracker #(
    parameter H_ACTIVE = 1920,
    parameter V_ACTIVE = 1080
) (
    input  logic clk, rst,
    input  logic s_axis_tvalid,
    input  logic s_axis_tready,
    input  logic s_axis_tlast,
    input  logic s_axis_tuser,  // SOF
    output logic [10:0] col,    // 0 to H_ACTIVE-1
    output logic [10:0] row     // 0 to V_ACTIVE-1
);

always_ff @(posedge clk) begin
    if (rst) begin
        col <= 0; row <= 0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        if (s_axis_tuser) begin  // start of frame
            col <= 0; row <= 0;
        end else if (s_axis_tlast) begin  // end of line
            col <= 0;
            row <= row + 1;
        end else begin
            col <= col + 1;
        end
    end
end

endmodule
```

---

## 4. Core Image Processing Operations

### A. Point Operations (No Neighborhood, 1 pixel → 1 pixel)

These are the simplest — no line buffers needed. Pure combinational or 1-cycle registered.

| Operation | Description | FPGA cost |
|-----------|-------------|-----------|
| **Threshold** | if pixel > T → 255 else 0 | 1 comparator |
| **Gamma correction** | LUT-based tone curve | 1 BRAM |
| **Histogram equalization** | ~~Remap intensities~~ — **not a point op**: needs full-frame CDF → see Global tier (Section 4D) | — |
| **Brightness/Contrast** | pixel × gain + offset | 1 DSP |
| **Clamp/Saturate** | min/max limit | 2 comparators |
| **Bit-depth conversion** | 10-bit → 8-bit (shift) | 0 LUTs |

### B. Geometric Operations (Full Frame Required)

| Operation | Description | FPGA cost |
|-----------|-------------|-----------|
| **Flip (H/V)** | Mirror address computation | Minimal |
| **Crop/Scale down** | Drop pixels | Counter |
| **Bilinear scaling** | Interpolated resize | 4 multipliers + BRAM |
| **Affine transform** | Rotate/shear/scale | 6 multipliers + 2D address |
| **Warp/undistort** | Correct lens distortion | LUT or polynomial |

**Important**: geometric transforms that read pixels out-of-order require random access to the full frame → **DDR required**.

### C. Neighborhood Operations (Line Buffer Required)

These require surrounding pixels → **BRAM line buffers** are essential.

| Operation | Kernel size | Line buffers needed | DSPs |
|-----------|------------|---------------------|------|
| 3×3 convolution | 3×3 | 2 | 9 |
| 5×5 convolution | 5×5 | 4 | 25 |
| Median filter 3×3 | 3×3 | 2 | ~0 (sort network) |
| Gaussian blur | 3×3 or 5×5 | 2 or 4 | 4–8 (separable) |
| Sobel edge detect | 3×3 | 2 | 0 (coefficients are ±1 and ±2 — shifts and adds only, no multiplier) |
| Box filter | N×N | N-1 | 0 (running sum of adds only, no multiply) |

### D. Global Operations (Full Frame — DDR Required)

These cannot stream — they need to see the whole frame before producing an output.

| Operation | Why it needs the full frame | PL role | PS role |
|-----------|----------------------------|---------|---------|
| **Histogram equalization** | Must compute CDF across all pixels first | Writes raw frame to DDR | Computes CDF + remap table, PL re-reads on second pass |
| **Optical flow** | Compares current frame to previous frame | Writes both frames to DDR | Computes motion vectors |
| **Background subtraction** | Maintains a background model | Writes frames to DDR | Updates background model, computes foreground mask |
| **Canny (hysteresis step)** | Edge connectivity — must traverse connected regions | Streams steps 1–3 to DDR | Runs hysteresis on the full edge map |
| **Global auto-exposure** | Average brightness over whole frame | Accumulates pixel sum in BRAM, dumps to DDR | Reads sum, computes new exposure setting, writes back via I2C |

---

## 5. Spatial Filtering and Convolution on FPGAs

### The Sliding Window

A 3×3 filter needs 9 pixels simultaneously. You collect them using a sliding window:

```
Input stream: p0, p1, p2, p3, p4, p5, p6, p7, p8, ...  (row-major order)

After filling 2 line buffers + shift register:

Window at column 2, row 1:
┌─────────────────┐
│ p(0,0) p(0,1) p(0,2) │  ← from line buffer 0 (oldest row)
│ p(1,0) p(1,1) p(1,2) │  ← from line buffer 1
│ p(2,0) p(2,1) p(2,2) │  ← from shift register (current row)
└─────────────────┘
```

### Separable Filters (Critical Optimization)

Many common filters (Gaussian, Box, Sobel) are **separable**: a 2D filter can be decomposed into two 1D passes (horizontal then vertical). This reduces DSP count dramatically.

```
2D Gaussian (5×5): 25 multiplications
Separable Gaussian: 5 (horizontal) + 5 (vertical) = 10 multiplications

Savings: 2.5× fewer DSPs
```

### Pipeline Architecture for 3×3 Convolution

```
Pixel in
  │
  ▼
[Shift register]  → p_col_n, p_col_n-1, p_col_n-2 (3 pixels, current row)
  │
  ▼ (write)
[Line buffer 0]   → p_row_n-1_col_n, _n-1, _n-2 (3 pixels, previous row)
  │
  ▼ (write)
[Line buffer 1]   → p_row_n-2_col_n, _n-1, _n-2 (3 pixels, two rows up)

All 9 pixels available simultaneously → multiply by kernel coefficients → sum → output
Pipeline latency = 2 × (image_width) + 2 cycles
```

### Convolution Resource Estimate

For a fully parallel 3×3 int8 convolution:
- 9 multipliers (8-bit × 8-bit) → 9 DSPs
- 8 adders (16-bit) → ~8–16 LUTs or use DSP cascade
- 2 × BRAM line buffers
- Throughput: 1 output pixel per clock cycle (fully pipelined)

---

## 6. Color Space Conversions

### RGB → Grayscale

Luminance: `Y = 0.299R + 0.587G + 0.114B`

**Fixed-point implementation** (avoid floating point):
```
Y = (77×R + 150×G + 29×B) >> 8
77 + 150 + 29 = 256 (powers of 2 friendly)
```
- Uses 3 multipliers (or 3 DSPs) + 2 adders
- Or: use a 256-entry LUT for each coefficient
- Throughput: 1 pixel/cycle (pipelined)

### RGB → HSV

Useful for color-based segmentation (isolate objects by hue):
- Nonlinear — requires comparison (max/min channels) and conditional division
- Division is expensive on FPGA — use lookup tables for the final division
- Or use Vitis HLS (C++) and let it handle the complexity

### YCbCr ↔ RGB

Standard video color space. Matrix multiply — 9 multiplications.
Xilinx provides IP: `v_rgb2ycrcb` and `v_ycrcb2rgb`.

### Bayer Demosaicing

Basic bilinear demosaicing:
- Requires 3×3 or 5×5 neighborhood (2 line buffers minimum)
- Multiply neighbors by known fixed weights → sum
- Xilinx Vivado IP: `v_demosaic`

---

## 7. Feature Detection Algorithms

### Sobel Edge Detector

```
Gx kernel:    Gy kernel:
-1  0  1     -1 -2 -1
-2  0  2      0  0  0
-1  0  1      1  2  1

Edge magnitude ≈ |Gx| + |Gy| (avoid sqrt for FPGA efficiency)
Edge direction = atan2(Gy, Gx) (approximated or LUT-based)
```

FPGA implementation:
- 2 line buffers + 2×3 shift registers
- 6 multiplications (can simplify to adds/subs since coefficients are ±1 and ±2)
- 2 adder trees
- Fully pipelined: 1 pixel/cycle

### Canny Edge Detector

More complex multi-stage pipeline:
1. Gaussian smoothing (5×5)
2. Gradient computation (Sobel)
3. Non-maximum suppression (requires 8 neighbors + direction)
4. Double threshold + hysteresis (requires connectivity — hard to pipeline)

Steps 1–3 are streaming. Step 4 (hysteresis) requires full-frame random access → DDR + frame buffer.

### Harris Corner Detector

1. Compute Ix, Iy (image gradients)
2. Compute Ix², Iy², Ix×Iy (3 multiplications)
3. Gaussian smoothing on the products (3 more filters)
4. Compute R = det(M) - k×trace(M)² (matrix determinant)
5. Non-maximum suppression

FPGA-friendly: steps 1–4 are streaming. Full pipeline latency ~4 rows.

### Optical Flow (Horn-Schunck, Lucas-Kanade)

Requires comparing two frames → DDR frame buffer + DMA.
Most suitable for HLS implementation.

---

## 8. Deep Learning Inference on FPGAs

### Why FPGA for ML Inference?

- **Batch size 1**: FPGAs excel at single-image (real-time) inference; GPUs need large batches for efficiency
- **Custom precision**: INT4, INT6, mixed-precision not supported by GPUs; trivial on FPGA
- **Deterministic latency**: no OS jitter, guaranteed frame timing
- **Power**: typically 5–50W vs 150–400W for GPU

### Approaches

| Approach | Description | Effort |
|----------|-------------|--------|
| **Vitis AI** | Xilinx's ML stack with pre-built DPU | Medium |
| **HLS4ML** | Python tool: Keras → HLS → Vivado | Medium |
| **Custom RTL** | Hand-written systolic array | High |
| **finn** (Xilinx research) | Ultra-low precision networks (binary/ternary) | Medium-High |

### DPU (Deep Processing Unit) — Xilinx Vitis AI

Xilinx provides a pre-built, pre-optimized CNN inference engine called the **DPU**:
- Implements a systolic array of MAC units
- Supports most standard CNN layers (Conv2D, BN, ReLU, pooling, FC)
- Takes quantized models (INT8) from PyTorch/TensorFlow via quantization toolkit
- Pre-synthesized IP — you just drop it into your Zynq design

```
Camera → [Preprocessing] → [AXI DMA] → [DPU] → [Post-process] → Output
                               DDR
                           stores frames
                           and weights
```

**Supported networks**: ResNet, VGG, MobileNet, YOLO, SSD, FCN, U-Net (most popular CNNs).

### HLS4ML (Keras → FPGA)

For custom small networks (edge ML):
```python
import hls4ml
config = hls4ml.utils.config_from_keras_model(model, granularity='Layer')
hls_model = hls4ml.converters.convert_from_keras_model(
    model, hls_config=config, output_dir='hls4ml_prj',
    part='xc7z020clg400-1'
)
hls_model.compile()
hls_model.build()
```

Limitation: primarily for small networks (MLP, small CNNs) due to FPGA resource constraints. Not suitable for ResNet-50 on Zynq-7020.

---

## 9. Algorithm Complexity vs FPGA Resources

### Resource Budget Estimates for Zynq-7020 (220 DSPs, 140 BRAMs)

| Algorithm | DSPs | BRAMs | LUTs | FFs |
|-----------|------|-------|------|-----|
| RGB→Grayscale | 3 | 0 | 20 | 10 |
| 3×3 Sobel | 0 | 2 | 60 | 100 |
| 3×3 Gaussian (separable) | 4 | 2 | 80 | 150 |
| Canny (all stages) | 10 | 6 | 500 | 800 |
| Bayer demosaic (bilinear) | 6 | 3 | 150 | 200 |
| Color space convert (matrix) | 9 | 0 | 30 | 40 |
| Small CNN layer (3×3, 64 ch) | 50–100 | 20 | 2000 | 3000 |
| YOLO-tiny (full) | 200+ | 100+ | 30K+ | 50K+ | ← too large for Z7-020

**Rule of thumb**: a Zynq-7020 can run:
- An entire classical computer vision pipeline (Canny, Harris, etc.) — plenty of room
- A tiny CNN (MobileNetV2 at INT8 via DPU) — fits with careful optimization
- A large CNN (ResNet-50) — needs Zynq UltraScale+

---

## 10. Open-Source IP Cores for Vision

| Core | Function | Source |
|------|----------|--------|
| **ZipCPU video** | VGA, HDMI, pixel pipeline | Dan Gisselquist (zipcpu.com) |
| **vga_timing_gen** | VGA sync generator | Multiple GitHub repos |
| **axis_sobel** | Sobel edge detector, AXI4-Stream | Various |
| **Hamsterworks HDMI** | HDMI TX/RX for 7-series | Mike Field |
| **Digilent HDMIout** | HDMI for Artix-7 / Zynq | Digilent GitHub |
| **PYNQ camera** | MIPI + processing for PYNQ boards | Xilinx GitHub |
| **lichee-pi-zero video** | Parallel camera interface | Community |

**Xilinx Video IP Suite** (free with Vivado):
- `v_vid_in_axi4s` — video-to-AXI4-Stream
- `v_axi4s_vid_out` — AXI4-Stream-to-video
- `v_demosaic` — Bayer demosaicing
- `v_gamma_lut` — Gamma correction LUT
- `v_rgb2ycrcb` — Color conversion
- `v_resize` — Bilinear/bicubic scale
- `v_osd` — On-Screen Display (overlay)
- `v_tpg` — Test Pattern Generator

---

## 11. Image Processing vs Video Processing — What Changes

| Concern | Still Image Processing | Video Processing |
|---------|----------------------|-----------------|
| Data source | File (DDR → DMA) | Camera (live stream) |
| Timing requirement | Relaxed | Strict (must finish before next frame) |
| Latency | Acceptable | Must be < 1 frame (16.7 ms @ 60fps) |
| Memory needed | 1–2 frame buffers | 2–3 frame buffers (ping-pong) |
| Algorithm freedom | Any algorithm OK | Must be pipelined / streamable |
| Debugging | Load same image repeatedly | Need ILA (optional — requires JTAG cable) or HDMI loopback |
| ARM software role | Load, trigger, readback | Configure once, then hands-off |

### Recommended Starting Point

**Still Image Processing first** — easier to debug:
1. Load image from SD card using ARM (Linux + OpenCV or bare-metal)
2. DMA to FPGA PL
3. Process in FPGA
4. DMA result back to ARM
5. Display or save

Then migrate to **live video**:
1. Replace DMA source with live camera stream
2. Add timing constraints (must complete in 1/fps seconds)
3. Add proper sync handling (TUSER, TLAST)

---

## 12. Fixed-Point Arithmetic for Image Processing

### Why Not Floating Point?

An IEEE 754 single-precision float multiply uses ~200 LUTs and 3 DSP slices with 5+ cycle latency. A fixed-point 8×8 multiply uses 1 DSP slice and 1-cycle latency. For a pixel pipeline multiplying thousands of values every clock cycle, floating point is prohibitively expensive.

**The solution**: scale all arithmetic to integers with an implicit decimal point — the hardware never knows the decimal is there, but you do.

### Q Notation

Fixed-point numbers are written as **Qm.n** (unsigned: **UQm.n**):
- **m** = integer bits
- **n** = fractional bits
- Total width = m + n (+ 1 sign bit for signed)

| Notation | Total bits | Range (signed) | Resolution |
|----------|-----------|----------------|------------|
| Q8.0 | 8 | −128 to +127 | 1.0 |
| Q8.8 | 16 | −128 to +127.996 | 1/256 ≈ 0.004 |
| Q1.15 | 16 | −1.0 to +0.9999 | 1/32768 |
| UQ8.0 | 8 | 0 to 255 | 1.0 |
| UQ1.7 | 8 | 0 to 1.992 | 1/128 |

Pixel values are naturally **UQ8.0** (unsigned 8-bit integers, 0–255). Filter coefficients like 0.299 are typically **Q1.15** or scaled to a convenient power of 2.

### Converting a Float Algorithm to Fixed Point

Take RGB → Grayscale: `Y = 0.299R + 0.587G + 0.114B`

**Step 1 — Choose a scale factor (power of 2)**
Scale = 2^8 = 256. Division by 256 is a free right-shift.

**Step 2 — Scale the coefficients**
```
0.299 × 256 = 76.544 → 77
0.587 × 256 = 150.272 → 150
0.114 × 256 = 29.184  → 29
Sum: 77 + 150 + 29 = 256 ✓  (sums to scale factor — no normalisation error)
```

**Step 3 — Implement as integer arithmetic**
```
Y_scaled = 77×R + 150×G + 29×B    // 16-bit accumulator
Y        = Y_scaled >> 8           // divide by 256
```

**Step 4 — Verify range**
Max: `256 × 255 = 65 280`. After `>>8`: `65 280 / 256 = 255` ✓

### Multiplication Width Growth

Multiplying two N-bit values produces a 2N-bit result — Verilog requires you to declare the correct output width or bits are silently truncated:

```systemverilog
logic [7:0]  pixel;        // UQ8.0
logic [7:0]  coeff;        // UQ0.8  (value represents coeff/256)
logic [15:0] product;      // 16-bit: UQ8.8
logic [7:0]  result;       // final 8-bit output

assign product = pixel * coeff;           // 16-bit multiply
assign result  = product[15:8];           // upper byte = divide by 256
```

### Accumulator Width for Filters

When accumulating N multiplications, size the accumulator to avoid overflow:

```
Accumulator bits = ceil(log2(N × max_product)) rounded up to the next byte

3×3 filter, 8-bit pixels × 8-bit coefficients:
  max single product = 255 × 255 = 65 025  (16-bit)
  9 products summed  = 9 × 65 025 = 585 225 → 20-bit accumulator minimum
  → use 24 bits to be safe
```

Always use a wide internal accumulator, then truncate at the pipeline output stage.

### Overflow and Saturation

Standard integer overflow wraps: `255 + 1 → 0`. For image data this produces catastrophic black pixels in bright regions. Use **saturating arithmetic**:

```systemverilog
// Saturating add: clamp to 255 instead of wrapping
logic [8:0] wide;    // 9-bit catches the carry
logic [7:0] sat;

assign wide = {1'b0, a} + {1'b0, b};         // zero-extend both operands
assign sat  = wide[8] ? 8'hFF : wide[7:0];   // carry set → clamp to 255
```

Xilinx DSP48E2 slices include built-in saturation and rounding modes — use them when available.

### Rounding

Truncation (dropping fractional bits) introduces a small but consistent negative bias. Round-to-nearest costs one addition:

```
result = (accumulator + (1 << (frac_bits - 1))) >> frac_bits

For 8 fractional bits: result = (accum + 128) >> 8
```

---

## 13. ISP Pipeline — Camera RAW to Displayable Output

A camera sensor outputs **raw data** that looks grey, noisy, and colour-shifted without correction. The ISP (Image Signal Processing) pipeline is the sequence of transforms that produces a natural-looking image. These stages are **not optional** for usable image quality from a RAW sensor.

### Full ISP Stage Order

```
RAW Bayer (from sensor)
        │
        ▼
① Black Level Subtraction
        │
        ▼
② Lens Shading Correction   (optional — corrects vignetting)
        │
        ▼
③ Demosaicing (Bayer → RGB)
        │
        ▼
④ White Balance
        │
        ▼
⑤ Color Correction Matrix (CCM)
        │
        ▼
⑥ Gamma Correction
        │
        ▼
⑦ Noise Reduction / Sharpening
        │
        ▼
Displayable RGB
```

### Stage ①: Black Level Subtraction

Sensor pixels have a non-zero output even in complete darkness (dark current, offset voltage). Without correction, blacks appear grey.

```
corrected = max(raw_pixel − black_level, 0)
```

`black_level` is a constant read from the sensor's registers via I2C before streaming starts. Typically 64 for a 10-bit sensor, 16 for 8-bit.

**FPGA cost**: 1 subtractor + 1 clamp per channel. No DSPs.

### Stage ③: Demosaicing

Covered in Section 6. Bayer pattern → RGB using bilinear interpolation (or higher-quality algorithms such as HQLI for professional systems). The Xilinx `v_demosaic` IP implements this with configurable Bayer pattern.

### Stage ④: White Balance

Different light sources have different colour temperatures (daylight ≈ 6500 K, tungsten ≈ 2700 K). A white sheet looks blue-ish under daylight and orange-ish under tungsten. White balance multiplies each channel by a gain to remove this cast.

**Gray World algorithm** (simple auto white balance — AWB):
1. Compute mean R, G, B over the entire frame (ARM CPU reads from DDR once per frame)
2. Set gains: `Gr = mean_G / mean_R`, `Gg = 1.0`, `Gb = mean_G / mean_B`
3. Apply in PL: `R_out = R × Gr`, `G_out = G`, `B_out = B × Gb`

**FPGA implementation** (apply only; ARM computes gains and writes them via AXI-Lite):

```systemverilog
// Gains as UQ4.8 (12-bit): value = gain × 256
// Written by ARM through AXI-Lite slave registers
logic [11:0] gain_r, gain_g, gain_b;
logic [7:0]  r_in, g_in, b_in;
logic [19:0] r_w, g_w, b_w;
logic [7:0]  r_out, g_out, b_out;

always_ff @(posedge clk) begin
    r_w <= r_in * gain_r;              // 8×12 = 20-bit
    g_w <= g_in * gain_g;
    b_w <= b_in * gain_b;
    // Saturate and extract 8 bits (÷256 = shift right 8)
    r_out <= r_w[15:8] > 8'hFF ? 8'hFF : r_w[15:8];
    g_out <= g_w[15:8] > 8'hFF ? 8'hFF : g_w[15:8];
    b_out <= b_w[15:8] > 8'hFF ? 8'hFF : b_w[15:8];
end
```

**FPGA cost**: 3 DSP slices. 2-cycle latency.

### Stage ⑤: Color Correction Matrix (CCM)

Camera sensor spectral sensitivities don't match the CIE standard observer (human vision). A 3×3 matrix maps sensor RGB to display-calibrated sRGB:

```
|R_out|   |m00  m01  m02| |R_in|
|G_out| = |m10  m11  m12| |G_in|
|B_out|   |m20  m21  m22| |B_in|
```

Coefficients are determined by the camera vendor from a colour-checker calibration target. They are close to identity but include negative cross-channel terms (e.g., subtracting blue from red), so **signed arithmetic** is required throughout.

**FPGA implementation notes**:
- 9 multiplications per pixel, 6 additions per output channel
- Use 9 DSPs (one per multiply) or 3 with time-multiplexing (saves DSPs at the cost of needing 3× pixel clock)
- Accumulate in 20-bit signed registers; clip to [0, 255] at output
- Store coefficients in AXI-Lite registers so ARM can load different matrices for different cameras

**FPGA cost**: 9 DSP slices, ~50 LUTs. 3-cycle pipelined latency.

### Stage ⑥: Gamma Correction

Human vision is perceptually non-linear — we see much more detail in dark regions than bright ones. Displays compensate for this with gamma encoding:

```
output = (input / 255)^(1/γ) × 255    where γ = 2.2 (sRGB standard)
```

**You cannot implement this with multipliers**: the exponentiation requires complex non-linear computation.

**FPGA solution — Look-Up Table (LUT)**

Pre-compute all 256 output values offline and store them in a BRAM. The pixel value becomes the address; the BRAM read is the corrected value:

```python
# Generate gamma LUT (run on host, once)
import numpy as np
gamma = 2.2
lut = [int((i / 255.0) ** (1.0 / gamma) * 255 + 0.5) for i in range(256)]
# Write to .coe or .hex file for BRAM initialisation
with open("gamma_lut.hex", "w") as f:
    for v in lut:
        f.write(f"{v:02X}\n")
```

```systemverilog
// Gamma LUT: 256×8 BRAM, 1-cycle read latency
logic [7:0] gamma_lut [0:255];
initial $readmemh("gamma_lut.hex", gamma_lut);

always_ff @(posedge clk)
    pixel_out <= gamma_lut[pixel_in];
```

**FPGA cost**: 1 BRAM per channel (3 BRAMs for RGB). 1-cycle latency. Zero DSPs.

Xilinx `v_gamma_lut` IP implements this with an AXI-Lite interface for runtime LUT updates.

### Stage ⑦: Noise Reduction

Sensor noise is amplified by gain and CCM. A 3×3 or 5×5 Gaussian blur (Section 5) reduces high-frequency noise before the frame is written to DDR. For scenes requiring edge preservation, a **bilateral filter** blurs smoothly within flat regions but not across edges — but it is expensive on FPGA (requires exponential function). A 5×5 Gaussian is the practical choice for most designs.

### Complete ISP Resource Estimate (1080p)

| Stage | DSPs | BRAMs | LUTs |
|-------|------|-------|------|
| Black level subtract | 0 | 0 | 6 |
| Demosaic (bilinear) | 6 | 3 | 150 |
| White balance | 3 | 0 | 20 |
| CCM (3×3) | 9 | 0 | 50 |
| Gamma LUT | 0 | 3 | 10 |
| Noise reduce (Gauss 3×3) | 4 | 2 | 80 |
| **Total** | **22** | **8** | **316** |

This is roughly 10% of a Zynq-7020's resources — well within budget alongside other processing.

---

## 14. Morphological Operations

Morphological operations process **binary images** (after thresholding) to clean noise, fill holes, or separate touching objects. They are among the cheapest vision operations on FPGA — no multipliers needed, only logic gates.

### Structuring Element

A structuring element (SE) is a small kernel of 0s and 1s that defines the neighbourhood shape. The simplest is a 3×3 all-ones square:

```
1 1 1
1 1 1
1 1 1
```

Other common shapes: plus/cross (removes corners), horizontal bar (keeps horizontal lines), diagonal.

### Erosion

**Erosion**: a pixel stays white (1) only if **all** neighbours under the SE are also white.

Mathematically: `eroded(x,y) = AND of all pixels in the 3×3 window`

Effect: shrinks white regions, removes isolated white pixels (noise), removes thin lines thinner than the SE.

```systemverilog
// 3×3 erosion on binary image
// window[row][col] is the 9-pixel sliding window (1-bit each)
assign eroded = window[0][0] & window[0][1] & window[0][2] &
                window[1][0] & window[1][1] & window[1][2] &
                window[2][0] & window[2][1] & window[2][2];
// 9-input AND — synthesises to 1-2 LUTs
```

**FPGA cost**: 2 BRAMs (line buffers, same as convolution) + ~2 LUTs. Throughput: 1 pixel/clock.

### Dilation

**Dilation**: a pixel becomes white (1) if **any** neighbour is white.

Mathematically: `dilated(x,y) = OR of all pixels in the 3×3 window`

Effect: grows white regions, closes small holes, thickens lines.

```systemverilog
assign dilated = window[0][0] | window[0][1] | window[0][2] |
                 window[1][0] | window[1][1] | window[1][2] |
                 window[2][0] | window[2][1] | window[2][2];
```

### Compound Operations

| Operation | Definition | Effect |
|-----------|-----------|--------|
| **Opening** | Erosion → Dilation | Removes small white blobs (salt noise); preserves shape of large objects |
| **Closing** | Dilation → Erosion | Fills small holes and gaps; connects nearby blobs |
| **Morphological gradient** | Dilation − Erosion | Extracts thick outlines of blobs |
| **Top-hat** | Original − Opening | Isolates fine bright structures against dark background |

Opening and Closing are simply two streaming stages in sequence:

```
Binary pixel stream
  → [Erosion stage] → FIFO → [Dilation stage]
  = Opening pipeline (1 pixel/clock)
```

The FIFO between stages absorbs the ~2-row pipeline latency of each stage.

### Grayscale Morphology (Min/Max Filters)

Morphology generalises to grayscale: Erosion → **min filter**, Dilation → **max filter**.

```systemverilog
// 3×3 min filter (grayscale erosion)
// window[i][j] are 8-bit pixel values
logic [7:0] min_val;
always_comb begin
    min_val = window[1][1];       // start with centre
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            if (window[i][j] < min_val) min_val = window[i][j];
end
```

The comparison tree synthesises to a small cascade of comparators — no DSPs required.

**Grayscale opening** (min then max) removes small bright peaks (impulse noise) from an image with no edge blurring — a useful pre-processing step before edge detection.

---

## 15. Real-Time Timing Budget Analysis

Before building a pipeline, verify it can keep up with the incoming pixel rate. A design that cannot process one pixel per clock **drops pixels** — there is no second chance.

### Pixel Rate and Pixel Clock

For 1920×1080 @ 60 fps:

```
Active pixels/frame = 1920 × 1080            = 2,073,600
Total clocks/frame  = 2200 × 1125            = 2,475,000  (active + blanking)
Pixel clock         = 2,475,000 × 60 fps     = 148.5 MHz
```

The pixel clock is the fundamental constraint: **your fabric must run at ≥ 148.5 MHz and produce one valid output pixel every clock cycle**. Use an MMCM inside the PL to generate exactly 148.5 MHz from the PS FCLK reference.

### Initiation Interval (II)

**Initiation Interval** is how many clock cycles a pipeline stage takes between accepting consecutive inputs.

- **II = 1**: fully pipelined — accepts a new pixel every clock. Throughput = clock frequency. This is the target for every streaming stage.
- **II = 2**: accepts a pixel every 2 clocks → throughput is halved → drops every other pixel at 1080p60.

HLS enforces this with `#pragma HLS PIPELINE II=1`. In RTL, II=1 is automatic when logic depth fits in one clock period.

| Stage II | Throughput at 148.5 MHz | Meets 1080p60? |
|----------|-------------------------|----------------|
| 1 | 148.5 Mpx/s | Yes |
| 2 | 74.25 Mpx/s | No |
| 1 (but clock = 100 MHz) | 100 Mpx/s | No |

### Latency vs Throughput

These are **independent**:

- **Latency**: how many cycles from input pixel to corresponding output pixel
- **Throughput**: output pixels per second (once the pipeline is full)

A 3×3 convolution has latency ≈ `2 × image_width + 2 cycles` ≈ 3 842 cycles ≈ 25 µs. But its throughput is still 1 pixel/clock. High latency does not hurt real-time throughput — it just means the output lags the input by a fixed number of rows.

For a chain of K pipelined stages:

```
Total latency = Σ latency_i         (adds up)
Throughput    = min(1 / II_i)       (bottleneck stage sets the limit)
```

### Blanking Budget

During horizontal and vertical blanking (16.2% of pixel clocks at 1080p60), no valid pixels arrive. This free time is used for:

- Pipeline flush at end of frame (TUSER goes low, pipeline drains)
- ARM-side per-frame computation (histogram analysis, Otsu threshold, gain update)
- DMA descriptor setup for the next frame capture buffer

**Free time per frame**:
```
(2 475 000 − 2 073 600) pixel clocks / (148.5 MHz) = 2.7 ms per frame
```

This 2.7 ms is available for ARM CPU work before the next frame arrives.

### Timing Closure

If synthesis/implementation reports that your critical path **fails timing** at 148.5 MHz:

1. **Pipeline the failing path**: add a register (flip-flop) in the middle of a long combinational chain to split it into two shorter stages, each fitting in one clock period.
2. **Reduce fan-out**: a signal driving hundreds of LUTs has high routing capacitance — register it and let the tool duplicate it.
3. **Lower parallelism**: if you are running N convolutions in parallel, consider sharing hardware with time-multiplexing (reduces DSPs and routing).

A simple pixel pipeline typically closes timing at 160–200 MHz on Zynq — well above the 148.5 MHz target, leaving comfortable margin.

---

## 16. Pipeline Flow Control and Backpressure

Understanding how data flows — and what happens when a stage is momentarily slow — is essential for building robust pipelines.

### The AXI4-Stream Handshake

Data transfers when **both** TVALID and TREADY are high on the same rising clock edge:

```
              TVALID  "I have data"
 Producer ───────────────────────────► Consumer
 Producer ◄───────────────────────────
              TREADY  "I can accept data"

Transfer: TVALID=1 AND TREADY=1 on rising clock edge.
```

If the consumer sets TREADY=0 (backpressure), the producer must **hold** TDATA and TVALID stable until TREADY goes high again. No data is ever dropped or corrupted.

### Two Pipeline Models

**Model A — Lock-step (synchronous, no backpressure)**

All stages clock at the pixel clock. Every stage is II=1. Data flows continuously with no FIFO needed between stages.

```
Camera (pixel clock) → Stage 1 → Stage 2 → Stage 3 → Display (pixel clock)
```

Best for: fully streaming pipelines (filtering, colour conversion, edge detection). This is the ideal model.

**Model B — Asynchronous / rate-mismatched**

Stages run at different rates or have variable latency (DDR access, arbitration delays). FIFOs absorb bursts.

```
Camera (148 MHz, continuous) → Stages → FIFO → AXI DMA (DDR bursts at variable rate)
```

Best for: when stages write to or read from DDR (unpredictable latency).

### FIFO Sizing Between Pipeline and DMA

A FIFO between a streaming pipeline and an AXI DMA must absorb the worst-case DDR unavailability. DDR can be blocked for up to ~1 000 ns (memory refresh cycles, competing port access). At 148.5 MHz:

```
Minimum FIFO depth = DDR_latency_ns × pixel_clock_MHz
                   = 1 000 ns × 148.5 MHz / 1 000
                   = 148 pixels minimum → round to 256 (next power of 2)
```

A 256-entry × 8-bit FIFO costs 1 BRAM. For 24-bit RGB pixels, 1 BRAM still suffices (256 × 24 = 48 Kb < 36 Kb → needs 2 BRAMs).

### Critical Rule: Camera Cannot Backpressure

A camera sensor outputs pixels at the pixel clock rate regardless of downstream state — it has no TREADY input. Connecting the camera receive path directly to any module that might assert TREADY=0 **will silently drop pixels**.

```
Wrong:   Camera IP → Filter (may assert TREADY=0) → ...
Correct: Camera IP → ASYNC FIFO → Filter (may assert TREADY=0) → ...
```

Always insert a FIFO immediately after the camera receive IP. This decouples the camera's locked-rate output from any downstream backpressure.

### Pipeline Bubble vs Stall

| Event | Cause | Effect |
|-------|-------|--------|
| **Bubble** | TVALID=0 from upstream (e.g. blanking interval) | A "empty" slot flows through the pipeline. Harmless. |
| **Stall** | TREADY=0 from downstream (backpressure) | Entire upstream halts. Data held in registers. |

Well-designed pipelines handle both correctly. Each stage must propagate backpressure upstream when it cannot accept data, and must pass bubbles through transparently.

---

## 17. Histogram and Statistics Operations

Histograms are foundational: Otsu thresholding, automatic exposure control, contrast stretching, and histogram equalisation all derive from the frame histogram. Computing one is the canonical FPGA example of an operation that **cannot be trivially pipelined**.

### Why Histograms Are Hard on FPGAs

A histogram is a 256-entry array where you increment `hist[pixel_value]` for each pixel:

```systemverilog
// Naive — BROKEN
always_ff @(posedge clk)
    hist[pixel_in] <= hist[pixel_in] + 1;  // read-modify-write
```

**Problem — Read-After-Write (RAW) hazard**: reading `hist[pixel_in]` has 1-2 cycle latency. If two consecutive pixels have the same value, the second read returns the stale (pre-increment) count. The increment is lost.

### Solution 1 — Forwarding (Simple, Works for Single-Cycle Conflicts)

```systemverilog
logic [15:0] hist [0:255];     // LUT RAM (not BRAM — 1-cycle read)
logic [7:0]  prev_pixel;
logic        prev_valid;

always_ff @(posedge clk) begin
    if (pixel_valid) begin
        // If same bin as last cycle, forward the already-incremented value
        if (prev_valid && pixel_in == prev_pixel)
            hist[pixel_in] <= hist[prev_pixel] + 2; // both this and last
        else
            hist[pixel_in] <= hist[pixel_in] + 1;
        prev_pixel <= pixel_in;
        prev_valid <= 1'b1;
    end
end
```

Handles consecutive identical values. More complex patterns (3+ in a row of the same bin) need a deeper forwarding chain or use Solution 2.

### Solution 2 — Interleaved Dual Histograms

Split the pixel stream: even-position pixels go to histogram A, odd-position pixels to histogram B. Because consecutive pixels always go to different arrays, no RAW hazard exists.

```
Pixel stream: p0  p1  p2  p3  p4  p5  ...
Histogram A:  p0  —   p2  —   p4  —   (even pixels)
Histogram B:  —   p1  —   p3  —   p5  (odd pixels)
```

After the frame, the ARM merges them: `hist[i] = histA[i] + histB[i]` — 256 additions, microseconds.

**FPGA cost**: 2 × 256-entry RAM (2 BRAMs or LUT RAM). Fully pipelined, 1 pixel/clock.

### Histogram Equalisation

Equalisation redistributes pixel intensities to cover the full 0–255 range, improving contrast in low-contrast images.

**Algorithm** (ARM CPU, per-frame):
```python
def equalise(hist, total_pixels):
    cdf = [0] * 256
    cdf[0] = hist[0]
    for i in range(1, 256):
        cdf[i] = cdf[i-1] + hist[i]

    cdf_min = next(c for c in cdf if c > 0)
    lut = [round((cdf[i] - cdf_min) / (total_pixels - cdf_min) * 255)
           for i in range(256)]
    return lut  # 256-entry remapping table
```

**FPGA+ARM split**:
1. FPGA accumulates histogram during frame N (using Solution 2 above)
2. ARM computes equalisation LUT from histogram (< 1 ms)
3. ARM writes 256 new values into the PL gamma LUT via AXI-Lite
4. FPGA applies the new LUT during frame N+1

One frame of latency, fully automatic adaptive contrast enhancement.

### Otsu's Automatic Threshold

Otsu's method finds the optimal binary threshold by maximising the between-class variance of foreground and background. Runs entirely on the ARM from the histogram (no image re-read needed):

```python
def otsu(hist, total):
    sum_total = sum(i * hist[i] for i in range(256))
    best_var, threshold = 0, 0
    w_bg, sum_bg = 0, 0

    for t in range(256):
        w_bg += hist[t]
        if w_bg == 0: continue
        w_fg = total - w_bg
        if w_fg == 0: break

        sum_bg += t * hist[t]
        u_bg = sum_bg / w_bg
        u_fg = (sum_total - sum_bg) / w_fg
        var  = w_bg * w_fg * (u_bg - u_fg) ** 2

        if var > best_var:
            best_var, threshold = var, t
    return threshold
```

ARM writes the resulting threshold value into a PL register via AXI-Lite. PL applies `pixel > threshold ? 255 : 0` combinationally. Fully adaptive, zero manual tuning.

---

## 18. Debugging Vision Pipelines on FPGA

Debugging on FPGA is different from software — you cannot add print statements and you cannot pause execution. Use these tools and strategies systematically.

### Strategy: Build Incrementally

Never connect camera → full pipeline → display in one go. Build and verify each stage independently before connecting the next:

```
Step 1: v_tpg → Display
        → Verify display timing, resolution, correct sync signals

Step 2: v_tpg → Your Filter → Display
        → Verify filter output on a known, deterministic input

Step 3: Camera → (passthrough, no processing) → Display
        → Verify camera interface; raw Bayer image visible

Step 4: Camera → Your Filter → Display
        → Verify full pipeline on live input
```

This isolates each failure to a single added component.

### ILA (Integrated Logic Analyzer) — optional, requires JTAG cable

The ILA is an on-chip logic analyser that samples internal signals into BRAM, then streams them out over JTAG to Vivado's waveform viewer — no oscilloscope required. **Optional for this project** — a JTAG cable is not available yet; UART logging and RTL simulation cover bring-up without it.

```
Your design signals ──► ILA core ──► JTAG cable ──► Vivado Hardware Manager
                                                     (waveform display)
```

**Adding an ILA in Vivado (Block Design)**:
1. Add `ila_0` IP core; set probe count and data width
2. Connect internal signals you want to observe to ILA probe ports
3. Set a trigger condition (e.g., rising edge of TUSER = start of frame)
4. Program FPGA → open Hardware Manager → Run Trigger → view captured waveform

**What to probe in a vision pipeline**:

| Signal | Why |
|--------|-----|
| `TVALID`, `TREADY`, `TLAST`, `TUSER` | Verify AXI4-Stream handshake and frame timing |
| `pixel_data` at input and output | Verify correct pixel values |
| State machine states | Identify stuck/illegal states |
| FIFO flags (`full`, `empty`, `almost_full`) | Catch overflow/underflow |
| DMA `mm2s_err`, `s2mm_err` | Catch DMA transfer errors |

**ILA resource cost**: ~2 BRAMs per 1 024 sample depth. Probe only what you need.

### Test Pattern Generator (v_tpg)

The Xilinx `v_tpg` IP generates synthetic video — it is the first IP you should drop into every new design:

| Pattern | Use case |
|---------|---------|
| Colour bars (EBU/SMPTE) | Verify colour pipeline (white balance, CCM, gamma) |
| Ramp | Verify bit-depth, saturation, bit ordering |
| Checkerboard | Verify edge detection algorithms (known edge locations) |
| Cross-hatch | Verify geometric operations (known lines) |
| Solid red / green / blue | Isolate individual colour channel paths |
| Passthrough | Useful as a no-op placeholder during bring-up |

Pattern type is selected via AXI-Lite register write. The ARM controls it in software.

### RTL Simulation with Real Image Data

Simulation lets you verify algorithm correctness before even touching hardware. Load a real image as a hex file into the testbench:

```python
# host: generate test image hex file
import cv2
img = cv2.imread("test.png", cv2.IMREAD_GRAYSCALE).flatten()
with open("test_image.hex", "w") as f:
    for px in img:
        f.write(f"{px:02X}\n")
```

```systemverilog
// testbench: stream pixels with correct AXI4-Stream timing
parameter H = 1920, V = 1080;
logic [7:0] test_image [0:H*V-1];
initial $readmemh("test_image.hex", test_image);

int col = 0, row = 0;
always @(posedge clk) begin
    if (m_tready) begin
        m_tdata  <= test_image[row*H + col];
        m_tvalid <= 1'b1;
        m_tlast  <= (col == H-1);
        m_tuser  <= (row == 0 && col == 0);  // SOF
        col <= (col == H-1) ? 0 : col + 1;
        if (col == H-1) row <= (row == V-1) ? 0 : row + 1;
    end
end
```

Capture the output `m_tdata` stream, write it to a file, and compare against a reference computed in Python (NumPy / OpenCV). If they match to within rounding error, the RTL is correct.

### Common Failure Modes and What to Look For

| Symptom | Likely cause | How to diagnose |
|---------|-------------|----------------|
| Blank or all-black display | Pipeline not producing TVALID, or clock not reaching display IP | ILA (optional, needs JTAG): check TVALID on display input |
| Image shifted horizontally or vertically | TLAST or TUSER asserted at wrong pixel | ILA (optional, needs JTAG): count TVALID pulses between TLAST edges |
| Checkerboard / tearing artefacts | Clock domain crossing without synchroniser; FIFO overflow | Add CDC synchroniser; check FIFO almost-full flag |
| Colour bleed (colours mixed between channels) | Wrong pixel packing / byte ordering | Probe raw pixel values in ILA (optional, needs JTAG) with colour bars input |
| Intermittent glitches | Timing violation at wrong clock | Check timing report; add pipeline register on critical path |
| Correct output in simulation, wrong on hardware | Uninitialised BRAM, reset issue, or timing closure failure | Check implementation timing report and ILA capture (optional, needs JTAG) |

---

---

## 19. Worked Example — First Pixel Through a Point-Based Pipeline

This traces one pixel, from the moment it leaves the camera sensor all the way to the HDMI output — cycle by clock cycle. The algorithm is **brightness adjustment** (simplest possible point-wise operation), so nothing gets in the way of seeing the pipeline mechanics clearly.

**Setup:**
- Camera: OV2640, parallel DVP, 640×480, outputs RAW8 (Bayer)
- Design: DVP receiver → demosaic → grayscale convert → brightness adjust → HDMI out
- Fabric clock: 100 MHz (10 ns per cycle)
- Operation: `output = clamp(pixel + 50, 255)` — increase brightness by 50

---

### Step 0 — Before anything moves: system startup (PS/ARM only)

The ARM processor runs once at boot before any pixels flow. The PL sits idle.

```
ARM boots from SD card
  │
  ├─ Loads your bitstream into PL  → your pipeline now physically exists
  │
  ├─ Sends I2C commands to OV2640:
  │    "set resolution 640×480, 30 fps, start streaming"
  │
  ├─ Writes brightness offset = 50 into PL register via AXI-Lite:
  │    write 32'h00000032  →  address 0x4000_0000  (your control register)
  │
  └─ Starts HDMI output IP, sets pixel clock to 25.175 MHz (640×480 @ 60 Hz)

ARM is now DONE.  It waits for interrupts.  PL runs everything from here.
```

---

### Step 1 — Pixel leaves the camera (camera's PCLK domain)

The OV2640 raises `PCLK` once per pixel. The first pixel of the frame is the top-left corner, row 0, column 0. Its color filter is Red (RGGB Bayer), and it read a brightness of 180.

```
On OV2640's PCLK rising edge #1:

  DATA[7:0] = 8'hB4   (= 180, the raw Red-channel reading)
  HREF      = 1       (1 = active pixel, not blanking)
  VSYNC     = 1       (1 = we are inside a valid frame)
```

This is a **different clock domain** from your FPGA fabric. OV2640's PCLK might be 24 MHz; your fabric is 100 MHz. They are not synchronised — you cannot connect them directly.

---

### Step 2 — Clock domain crossing (async FIFO)

The DVP receiver FSM (running in the PCLK domain) sees HREF=1 and VSYNC=1, so it writes this pixel into the **async FIFO**:

```
PCLK domain → writes into async FIFO:
  data   = 8'hB4
  tvalid = 1
  tuser  = 1    ← first pixel of the frame → Start-Of-Frame (SOF) pulse
  tlast  = 0    ← not end of row yet (this is column 0 of 640)
```

On the fabric clock (100 MHz) side, the FIFO's read port sees data ready. It reads out:

```
Fabric clock cycle 1:
  s_tdata  = 8'hB4
  s_tvalid = 1
  s_tuser  = 1    ← SOF — signals to every downstream stage: new frame starting
  s_tlast  = 0
```

From this point everything runs on the 100 MHz fabric clock.

---

### Step 3 — Demosaic stage (neighbourhood, 2 line buffers)

The demosaic needs 3 rows to interpolate. This is the first pixel of the first frame — the line buffers are empty. The module suppresses output (`m_tvalid = 0`) until row 2 arrives.

```
Cycle 1:    pixel(0,0) = 180 (Red site) enters. Written into line buffer 0.
             m_tvalid = 0  — not enough rows yet

... 640 cycles: row 0 fills line buffer 0
... 640 cycles: row 1 fills line buffer 1
... 1 more cycle: pixel(0,2) arrives — 3-row window is now full

Cycle 1281: pixel(0,2) arrives.
             Demosaic reads 3×3 window, interpolates missing colours:
               R = 180  (from row 0 red site directly above)
               G = 95   (interpolated from adjacent green sites)
               B = 40   (interpolated from blue sites)

             m_tdata  = {8'hB4, 8'h5F, 8'h28}   (24-bit RGB packed)
             m_tvalid = 1
             m_tuser  = 1   ← passed through aligned with data
             m_tlast  = 0
```

After this point, one new processed pixel exits per clock cycle continuously.

---

### Step 4 — Grayscale convert (point-wise, 2 cycles)

Applies: `Y = (77×R + 150×G + 29×B) >> 8`

```
Cycle 1281 (input registered into stage 1):
  Latches R=180, G=95, B=40

Cycle 1282 (multiply stage):
  77 × 180 = 13,860
  150 ×  95 = 14,250
  29 ×  40  =  1,160

Cycle 1283 (accumulate + shift):
  sum = 13,860 + 14,250 + 1,160 = 29,270
  Y   = 29,270 >> 8 = 114

  m_tdata  = 8'h72   (= 114)
  m_tvalid = 1
  m_tuser  = 1       ← still aligned, passed through 2-stage shift register
  m_tlast  = 0
```

---

### Step 5 — Brightness adjust (point-wise, 1 cycle) ← the actual algorithm

One registered addition with saturation clamp:

```
Cycle 1283 (input arrives):
  pixel_in = 8'h72  (= 114)
  offset   = 8'h32  (= 50 — written by ARM at startup, stored in register)

  wire [8:0] sum = {1'b0, 114} + {1'b0, 50}
                 = 9'd164          ← 164 fits in 8 bits, sum[8] = 0, no overflow

Cycle 1284 (registered output):
  pixel_out = 8'hA4  (= 164)
  m_tvalid  = 1
  m_tuser   = 1
  m_tlast   = 0
```

That is it. The entire algorithm is one addition and one comparator, taking one clock cycle.

---

### Step 6 — HDMI output (AXI4-Stream → video timing signals)

The `v_axi4s_vid_out` IP converts the AXI4-Stream back into classical HDMI timing signals:

```
Cycle 1284:
  Pixel 164 arrives.
  TUSER = 1 → IP knows this is SOF, begins a new frame output.

  Drives to HDMI TX chip:
    DE        = 1        (data enable — active pixel)
    DATA[7:0] = 8'hA4   (brightness-boosted pixel, value 164)
    HSYNC, VSYNC controlled by the IP's internal timing generator

HDMI TX serialises the signal at 25.175 MHz to the monitor.
```

---

### Full journey summary

```
                                                   Latency added
Camera raises PCLK (pixel 0,0 = RAW value 180)
  │
  ▼  Async FIFO CDC                                ~2 fabric cycles
  │
  ▼  Demosaic (waits for 2 rows to fill)           1,280 cycles  ← biggest wait
  │  then 1 pixel/cycle continuously
  │
  ▼  Grayscale convert                             2 cycles
  │
  ▼  Brightness adjust            ← your algorithm  1 cycle
  │
  ▼  HDMI output IP                                ~2 cycles
  │
  ▼  Monitor displays pixel
                                                   ─────────────
                                     Total startup: ~1,287 cycles
                                                  = 12.87 µs at 100 MHz
                                       (invisible — well under 1 frame = 33 ms)
```

After cycle 1,287 every clock cycle (10 ns) produces and displays one new pixel. The pipeline runs at 100 MHz for the remaining 307,199 pixels of the frame, then immediately starts the next frame without any gap.

---

### What ARM does during all of this

```
ARM after startup:   SLEEPING (WFI — Wait For Interrupt, consuming ~0% CPU)

Once per frame (optional, triggered by VSYNC interrupt from PL):
  - Read a new brightness value from USB, network, or button
  - Write new offset into AXI-Lite register (one 32-bit write)
  - Go back to sleep

ARM CPU load: < 1%.  PL does all pixel work.
```

---

### The two key takeaways from this example

**1. The 1,280-cycle startup cost has nothing to do with your algorithm.** It is purely the line-buffer fill time for demosaic. Your brightness step added just 1 cycle. This is why neighbourhood operations (not point-wise ones) are the bottleneck in startup latency.

**2. AXI-Lite and AXI4-Stream never interfere.** ARM writes the brightness offset once over AXI-Lite (slow, addressed, single word). Pixels fly through the AXI4-Stream (fast, unaddressed, continuous). These are two separate physical buses — the ARM write does not stall the pixel stream.

---

**Previous**: [05 — Memory and Interfaces](../fundamentals/05_MEMORY_AND_INTERFACES.md)  
**Next**: [07 — Hardware Selection Guide](../hardware/07_HARDWARE_SELECTION.md)
