# 08 — FPGA Vision Project Roadmap

> A structured, phased plan from zero to a working FPGA-accelerated vision pipeline. Each phase has clear entry requirements, deliverables, and exit criteria.

---

## Roadmap Overview

```
Phase 0: Prerequisites and Setup          (1–2 weeks)
    ↓
Phase 1: FPGA Basics — Blinking Lights    (1–2 weeks)
    ↓
Phase 2: Digital Design Patterns          (2–3 weeks)
    ↓
Phase 3: Pixel Pipeline Fundamentals      (2–3 weeks)
    ↓
Phase 4: Display and Camera Integration   (2–3 weeks)
    ↓
Phase 5: Image Processing Core            (3–4 weeks)
    ↓
Phase 6: Video Pipeline (live stream)     (3–4 weeks)  ← if going video route
    ↓
Phase 7: Advanced Acceleration            (ongoing)
```

**Total estimated time to Phase 5**: 12–18 weeks (working part-time, ~10–15 hrs/week)
**Total estimated time to Phase 6**: 18–25 weeks

These are estimates for someone starting from scratch with programming experience but no digital design background.

---

## Phase 0 — Prerequisites and Environment Setup

**Goal**: Have everything installed and working. Understand what you are getting into.

### 0.1 Read the wiki
- Read [01_FPGA_FUNDAMENTALS.md](../fundamentals/01_FPGA_FUNDAMENTALS.md) — fully
- Read [02_DIGITAL_DESIGN_PREREQUISITES.md](../fundamentals/02_DIGITAL_DESIGN_PREREQUISITES.md) — fully
- Skim [03_HDL_AND_HLS.md](../fundamentals/03_HDL_AND_HLS.md) introduction
- Decide on hardware: read [07_HARDWARE_SELECTION.md](../hardware/07_HARDWARE_SELECTION.md)

### 0.2 Order Hardware
- FPGA board (recommended: PYNQ-Z1 or PYNQ-Z2)
- USB cable (usually micro-USB or USB-C depending on board)
- HDMI cable
- Camera (optional for now — start without)

### 0.3 Install Software

```
Mandatory:
[ ] Vivado ML Standard (free) — download from AMD/Xilinx website
    Installation: select "Zynq-7000" support during install
    Size: ~40–50 GB
    Time: 1–3 hours

[ ] Icarus Verilog (iverilog) — for quick simulation
    macOS: brew install icarus-verilog
    Linux: apt install iverilog

[ ] GTKWave — waveform viewer
    macOS: brew install gtkwave (or download the app)
    Linux: apt install gtkwave

Optional (useful):
[ ] Python 3 + numpy + matplotlib — for image reference implementation
[ ] PYNQ board image (SD card) — from pynq.io downloads
[ ] VS Code with Verilog-HDL extension (for syntax highlighting)
```

### 0.4 Digital Design Self-Assessment

Work through these before writing any HDL:

| Topic | Resource |
|-------|---------|
| Binary arithmetic, two's complement | nand2tetris.org Chapter 1 |
| Boolean algebra, logic gates | Any digital logic textbook, Chapter 1–2 |
| Flip-flops, registers, state machines | nand2tetris.org Chapter 3 |
| Timing, setup/hold (conceptual) | Xilinx FPGA Fundamentals tutorial |

### 0.5 Decide on a Direction

**Decision to make**: image processing OR video processing?

| Choose image processing if... | Choose video processing if... |
|-------------------------------|-------------------------------|
| You want shorter feedback loops | You want to build real-time systems |
| Algorithm experimentation is the focus | Pipeline throughput and timing matter |
| No real-time constraint required | You have or will buy a camera |
| Easier to debug (repeatable input) | You want to process live sensor data |

Both routes use the same fundamental skills through Phase 5. After Phase 5 they diverge.

**Exit criteria Phase 0**:
- Vivado installed and licensed
- Board in hand and booting
- iverilog + GTKWave working
- Digital design basics reviewed

---

## Phase 1 — FPGA Basics: Blinking Lights and Counters

**Goal**: Write, synthesize, and run your first RTL design on hardware. Build familiarity with the entire flow end-to-end.

**Prerequisite**: Phase 0 complete.

### 1.1 "Hello World" — LED Blink

```
Task: Make LED blink at 1 Hz using a counter
Target: your FPGA board
Learn:
  - Verilog module structure
  - clock, reset, counter
  - constraints file (pin assignments + clock period)
  - Vivado synthesis + implementation + bitstream
  - JTAG programming
```

**Example implementation concept**:
- 100 MHz clock → divide by 100,000,000 → 1 Hz toggle
- Counter: 27 bits (2^27 ≈ 134M > 100M)
- Output: LED pin

### 1.2 Push-button Controlled LEDs

```
Task: Light different LEDs based on button presses
Learn:
  - Input debouncing (buttons bounce electrically)
  - Synchronous input sampling
  - Logic between multiple signals
```

### 1.3 Simple Counter with 7-Segment Display

```
Task: Count seconds/milliseconds, display on 7-segment
Learn:
  - Multi-digit display multiplexing (time-division)
  - BCD (Binary Coded Decimal) or binary to 7-seg decoder
  - FSM for multiplexing
```

### 1.4 Write a Testbench and Simulate

```
Task: Simulate the counter module without uploading to hardware
Learn:
  - Testbench structure ($dumpfile, $dumpvars, $finish)
  - Non-synthesizable constructs (#delay, $display)
  - Running iverilog: iverilog -g2012 -o sim.out tb.v counter.v && vvp sim.out
  - Viewing waveforms in GTKWave
```

**Exit criteria Phase 1**:
- LED blinks at correct rate on hardware
- 7-segment counter working
- Can simulate a module and view waveforms in GTKWave
- Understand Vivado's synthesis/implementation/bitstream flow
- Can read the timing summary report

---

## Phase 2 — Digital Design Patterns

**Goal**: Learn the building blocks used in every FPGA design. Implement each from scratch.

### 2.1 Parameterized Modules

```
Task: Write a generic N-bit counter, N-bit register, N-to-1 MUX
Learn:
  - `parameter` and `localparam`
  - `generate` blocks
  - `$clog2` for address width calculation
```

### 2.2 Finite State Machine (FSM)

```
Task: Implement a vending machine or traffic light controller FSM
Learn:
  - 3-block FSM style (state reg, next-state logic, output logic)
  - `always_ff`, `always_comb` (SystemVerilog)
  - `enum` for state encoding
  - Simulation-driven debugging
```

### 2.3 Synchronous FIFO

```
Task: Implement a parameterizable FIFO (First-In, First-Out buffer)
Learn:
  - Circular buffer with read/write pointers
  - Full/empty detection
  - Valid/ready handshake
  - Testing: fill to full, drain to empty, check no overflow
```

### 2.4 Asynchronous FIFO (Clock Domain Crossing)

```
Task: Implement or use a vendor async FIFO for CDC
Learn:
  - Gray code pointers
  - Why 2-FF synchronizer is needed for pointers
  - Metastability and why it cannot be eliminated, only managed
```

### 2.5 Simple Arithmetic Units

```
Tasks:
  - 8-bit adder with saturation (clamp to 255 instead of wrapping)
  - 8-bit multiplier (verify DSP inference in synthesis report)
  - Fixed-point multiply: 8-bit × 8-bit → keep upper 8 bits
Learn:
  - Bit-width analysis
  - Overflow and saturation
  - DSP48 inference conditions
```

### 2.6 On-chip RAM (BRAM) Module

```
Task: Implement a 256×8 single-port and dual-port RAM
Learn:
  - BRAM inference patterns (registered output for BRAM vs non-registered for LUT-RAM)
  - Read-first vs write-first vs no-change mode
  - Checking BRAM inferred in synthesis report
```

**Exit criteria Phase 2**:
- Can implement FSMs correctly (no latches, all states handled)
- Can implement a synchronous FIFO from scratch
- Understand CDC and can explain why direct CDC is dangerous
- Arithmetic modules pass simulation with corner cases
- Can verify BRAM/DSP inference in synthesis reports

---

## Phase 3 — Pixel Pipeline Fundamentals

**Goal**: Understand how image data flows through FPGA hardware. Build fundamental pixel-level modules.

### 3.1 Test Pattern Generator (TPG)

```
Task: Generate colored bars, gradients, or checkerboard patterns
      without any camera
Learn:
  - Pixel counter (column, row)
  - Frame timing (active area, blanking)
  - Conditional pixel generation based on (col, row)
```

This is your "camera simulator" — use it throughout Phase 3 and 4.

### 3.2 AXI4-Stream Passthrough Module

```
Task: Create a module with AXI4-Stream input and output
      that passes data through unchanged (but registers it)
Learn:
  - TDATA, TVALID, TREADY, TLAST, TUSER handshake
  - Pipeline register for TREADY (this is tricky — requires a skid buffer)
  - Timing: modules must be TREADY=1 capable to avoid backpressure
```

### 3.3 Grayscale Converter (RGB → Y)

```
Task: Convert 24-bit RGB pixel stream to 8-bit grayscale
      Y = (77×R + 150×G + 29×B) >> 8
Learn:
  - Fixed-point coefficient multiply
  - Multi-cycle pipeline latency
  - Passing TLAST/TUSER through unchanged (don't forget sync signals!)
```

### 3.4 Pixel-wise Operations

```
Tasks (pick any 3):
  - Brightness/contrast adjust (multiply + add, saturate to [0,255])
  - Invert image (255 - pixel)
  - Threshold (pixel > T ? 255 : 0)
  - Gamma correction via LUT (256-entry BRAM lookup)
Learn:
  - Pipelined arithmetic
  - LUT-based operations (BRAM as lookup table)
```

### 3.5 Line Buffer Implementation

```
Task: Store one line of image data in BRAM,
      read it back one cycle later (1-line delay)
Learn:
  - BRAM as line buffer
  - Write pointer, read pointer management
  - Ping-pong or circular addressing
```

### 3.6 3×3 Sliding Window

```
Task: Build a module that accepts a pixel stream and outputs
      9 pixels simultaneously (3×3 neighborhood)
      using 2 BRAM line buffers + 2 column shift registers
Learn:
  - The sliding window architecture (most important pattern in image processing)
  - Multi-line buffer organization
  - Border handling (what to do at edges of image?)
```

**Exit criteria Phase 3**:
- 3×3 sliding window working in simulation with correct pixel values
- RGB→Grayscale pipeline tested with an image file (Python generates input, verifies output)
- AXI4-Stream handshake implemented correctly (backpressure tested)
- Understand pipeline latency (how many cycles before first valid output?)

---

## Phase 4 — Display and Camera Integration

**Goal**: Get pixels on a screen. Get pixels from a camera.

### 4.1 VGA/HDMI Output

```
Task: Display the test pattern generator output on a monitor
If your board has VGA: generate HSYNC, VSYNC, RGB directly
If your board has HDMI: use vendor HDMI IP or open-source DVI core
Learn:
  - Pixel clock generation (MMCM/PLL for 74.25 MHz or 148.5 MHz)
  - Horizontal/vertical timing (front porch, sync, back porch)
  - Video IP integration in Vivado Block Design
```

### 4.2 Display Your Processed Image

```
Task: Chain: TPG → Grayscale → HDMI Display
      Should show grayscale version of test pattern on monitor
Learn:
  - Connecting AXI4-Stream modules in series
  - Maintaining TLAST/TUSER through the pipeline
  - Debugging with ILA (probe key signals)
```

### 4.3 Zynq ARM + DMA: Image from Software

```
Task (Zynq boards only):
  - Load a JPEG/PNG from SD card using ARM Linux + libpng
  - DMA it to FPGA fabric
  - Process in FPGA
  - DMA result back to ARM
  - Display on HDMI or save to file
Learn:
  - Zynq PS/PL connection (AXI HP ports)
  - AXI DMA configuration and control from Linux
  - devmem2 or mmap() for register access
  - Coherency: cache flushing before DMA
```

### 4.4 Camera Integration (Optional in Phase 4)

```
If using USB webcam (easiest):
  - Plug in and test with v4l2-ctl under Linux
  - Capture frames to DDR using V4L2 ioctl
  - DMA to FPGA for processing

If using parallel camera (OV7670):
  - Write I2C configuration controller (or use Xilinx I2C IP)
  - Write parallel DVP receiver (sample data on PCLK rising edge)
  - Convert to AXI4-Stream

If using MIPI CSI-2 camera:
  - Use Xilinx mipi_csi2_rx_subsystem IP
  - Configure via I2C (ARM software)
  - Connect output to your pipeline
```

**Exit criteria Phase 4**:
- Monitor showing test pattern (or camera feed)
- End-to-end: image into FPGA → process → display
- DMA working (image in ARM memory → FPGA → ARM memory)
- ILA deployed and can probe signals in real hardware

---

## Phase 5 — Image Processing Core

**Goal**: Implement a meaningful image processing pipeline with multiple stages.

### 5.1 Spatial Filtering

```
Tasks (implement at least 2):
  - Box filter (3×3 average): sliding sum optimization
  - Gaussian blur (3×3 or 5×5): separable implementation
  - Median filter (3×3): sort network
  - Sharpening: subtract blurred from original
Learn:
  - Separable filter decomposition (halves DSP count)
  - Sliding sum: add new column, subtract old column
  - Resource utilization: how many DSPs, BRAMs used?
```

### 5.2 Edge Detection

```
Task: Implement Sobel edge detector
Input: grayscale stream
Output: edge magnitude stream
Steps:
  1. 3×3 sliding window
  2. Gx = (-1,0,+1; -2,0,+2; -1,0,+1) dot product with window
  3. Gy = (-1,-2,-1; 0,0,0; +1,+2,+1) dot product with window
  4. |Gx| + |Gy| as approximation of magnitude
  5. Threshold: edge if magnitude > T
Learn:
  - Coefficient multiplication (coefficients are 0, ±1, ±2 — no multiplier needed!)
  - Two simultaneous convolutions (Gx and Gy) on the same window
  - Final combination
```

### 5.3 Histogram Computation

```
Task: Compute histogram of a grayscale image (256 bins)
      Store in BRAM, read out via AXI4-Lite to ARM
Learn:
  - Accumulation in BRAM: read-modify-write (needs careful pipelining)
  - AXI4-Lite register interface (simple control/status interface)
  - Two-pass design: accumulate in first pass, read in second
```

### 5.4 Morphological Operations (Binary Image)

```
Task: Erosion and Dilation on binary (threshold) image
      Using 3×3 structuring element
Learn:
  - AND (erosion) / OR (dilation) on 9-pixel window
  - Structuring element as a parameter
  - Opening (erosion then dilation) for noise removal
```

### 5.5 Integration and Testing

```
Task: Build a pipeline with:
  Input (camera or DMA) → Noise filter → Edge detect → Threshold → Display
  
Create a Python reference implementation with OpenCV for comparison.
Compare pixel-by-pixel output from FPGA vs Python.
Measure throughput: how many pixels/second? FPS?
```

**Exit criteria Phase 5**:
- Complete multi-stage pipeline running on hardware
- Output verified correct against Python/OpenCV reference
- Resource utilization documented (LUT%, DSP%, BRAM%)
- Timing closure at target frequency (100 MHz or 150 MHz)
- Pipeline processes at 1 pixel per clock (fully pipelined)

---

## Phase 6A — Live Video Pipeline (Video Route)

**Goal**: Real-time video processing at 60 fps, 720p or 1080p.

### 6A.1 Video Timing Deep Dive

```
Learn:
  - Pixel clock vs processing clock (may differ)
  - Clock domain crossing between pixel clock and processing clock
  - Blank period handling (processing unit must be idle or reset during blanking)
  - Frame latency budget: 16.7 ms @ 60 fps = budget for all processing
```

### 6A.2 Camera to Display Loopback

```
Task: Camera → FPGA (identity pipeline) → Display
      No processing yet — just verify timing is correct
Verify:
  - Frame rate matches expected (60 fps)
  - No tearing, artifacts, or dropped frames
  - ILA: check TUSER/TLAST timing
```

### 6A.3 Apply Image Processing to Live Feed

```
Task: Insert Phase 5 pipeline between camera capture and display
Challenge: Processing pipeline may have latency > 0 cycles
  → Need 1-2 line buffers minimum → adds to latency but not throughput
Verify: 60 fps maintained, no dropped frames
```

### 6A.4 Multi-frame Processing (Optical Flow, Motion Detection)

```
Task: Motion detection using frame difference
  |Frame_N - Frame_{N-1}| > threshold → motion detected
Learn:
  - Ping-pong DDR buffer for two frames
  - Frame-to-frame subtraction
  - Temporal accumulation
```

### 6A.5 On-Screen Display (OSD)

```
Task: Overlay text/graphics on video output
  (e.g., frame counter, detected features highlighted)
Learn:
  - OSD composition: blend overlay with video
  - Font ROM (store character bitmaps in BRAM)
  - Alpha blending for overlay
```

**Exit criteria Phase 6A**:
- 60 fps live video with no dropped frames at 720p or 1080p
- Real-time edge detection or motion detection visible on HDMI output
- End-to-end latency measured (< 3 frames)
- System running 24/7 stable (no lockups from async FIFO overflow)

---

## Phase 6B — Deep Learning Acceleration (AI Route)

**Goal**: Run a neural network inference engine on the FPGA alongside classical CV.

### 6B.1 Vitis AI DPU Deployment

```
Task: Use the Xilinx DPU to run MobileNetV2 or YOLOv5-nano
Steps:
  1. Install Vitis AI on host PC
  2. Train or download a pre-trained model (PyTorch/TensorFlow)
  3. Quantize to INT8 using Vitis AI quantizer
  4. Compile for DPU using vai_c_tensorflow2
  5. Build Zynq design with DPU IP from Vitis AI
  6. Run inference from Python (Vitis AI runtime)
Learn:
  - Model quantization: how INT8 approximates FP32
  - DPU architecture: how it schedules CNN layers
  - Throughput: images per second for different networks
```

### 6B.2 Pre/Post Processing Acceleration

```
Task: Move preprocessing (resize, normalize) to FPGA fabric
      (currently done in ARM CPU)
Learn:
  - Bilinear resize in RTL or HLS
  - Normalization: (pixel - mean) / std → fixed-point
  - Integration between preprocessing FPGA fabric and DPU
```

### 6B.3 Custom HLS Accelerator (Optional)

```
Task: Implement a small CNN layer in Vitis HLS
  → demonstrates manual control vs DPU
Learn:
  - HLS DATAFLOW pragma for multi-layer pipeline
  - ap_fixed<> types for custom precision
  - Performance: compare vs DPU for same operation
```

---

## Phase 7 — Advanced Optimization (Ongoing)

For either route (video or AI), eventual optimizations:

### 7.1 Timing Optimization
- Pipelining long paths (retiming)
- Floorplanning critical modules
- Clock frequency increase (100 → 150 → 200 MHz)

### 7.2 Resource Optimization
- Share DSPs across time-multiplexed operations
- Replace large LUT structures with BRAM
- Compress filter coefficients (powers of 2 → free shifts)

### 7.3 Partial Reconfiguration
- Swap processing modules without full reconfiguration
- Different filter modes selectable at runtime

### 7.4 Power Optimization
- Clock gating unused modules during blanking
- Dynamic voltage/frequency scaling (Zynq PS)

---

## Skills Checklist

Use this to track your progress:

### Foundation
- [ ] Can write and synthesize a Verilog module with ports, parameters
- [ ] Can explain setup/hold time and timing closure
- [ ] Can add timing constraints (create_clock, set_property)
- [ ] Can read and act on timing reports (WNS, TNS, critical path)
- [ ] Can write a testbench and simulate with iverilog/Vivado
- [ ] Can view and interpret simulation waveforms in GTKWave

### FPGA Design Patterns
- [ ] Can implement a parameterized synchronous FIFO
- [ ] Can implement a correct Moore FSM (no latches)
- [ ] Can implement 2-FF synchronizer for single-bit CDC
- [ ] Can implement async FIFO for multi-bit CDC
- [ ] Can infer BRAM (verify in synthesis report)
- [ ] Can infer DSP slice for multiplications

### Vision Pipeline
- [ ] Can build a 3×3 sliding window module
- [ ] Can implement separable filtering
- [ ] Can implement AXI4-Stream passthrough (with TREADY backpressure)
- [ ] Can maintain TLAST/TUSER through a pipeline correctly
- [ ] Can implement Sobel edge detection
- [ ] Can verify results against a Python/OpenCV reference
- [ ] Can measure real pipeline throughput (pixels/clock, FPS)

### System Integration
- [ ] Can build a Zynq block design with PS, AXI interconnect, DMA
- [ ] Can configure and use AXI VDMA or AXI DMA
- [ ] Can configure and use the AXI4-Lite register interface from ARM Linux
- [ ] Can integrate ILA for in-circuit debugging
- [ ] Can program flash for persistent bitstream

---

## Reference Materials

### Books
| Title | Author | Focus |
|-------|--------|-------|
| *Digital Design and Computer Architecture* | Harris & Harris | Foundations |
| *FPGA Prototyping by SystemVerilog Examples* | Pong P. Chu | RTL design patterns |
| *Embedded System Design with FPGAs* | Pedroni | Practical FPGA |
| *Image and Video Processing* | Bovik | Algorithm reference |

### Online Courses
| Resource | URL | Content |
|----------|-----|---------|
| Xilinx Vivado tutorials | xilinx.com/support | Official toolchain tutorial |
| PYNQ tutorials | pynq.io | Zynq + Python framework |
| nand2tetris | nand2tetris.org | Digital logic from gates up |
| ZipCPU blog | zipcpu.com | Excellent FPGA engineering blog |
| FPGA4Fun | fpga4fun.com | Practical projects with examples |
| Digilent Learn | digilent.com/learn | Board-specific tutorials |

### Key GitHub Repositories
| Repository | Content |
|-----------|---------|
| `xilinx/PYNQ` | PYNQ platform source + overlays |
| `xilinx/Vitis-AI` | ML inference framework for Zynq |
| `enjoy-digital/litex` | Open-source SoC framework |
| `ZipCPU/wb2axip` | AXI4 bus infrastructure |
| `hls4ml-team/hls4ml` | Keras → HLS conversion |

### Local Xilinx Documents (saved in `resources/`)

| Document | File | Relevant phases |
|----------|------|----------------|
| **DS891** — Zynq UltraScale+ Product Selection Guide | [`ds891-zynq-ultrascale-plus-overview.pdf`](../../resources/ds891-zynq-ultrascale-plus-overview.pdf) | Phase 0: device selection, resource count comparison across MPSoC family |
| **UG1085** — Zynq UltraScale+ Technical Reference Manual | [`ug1085-zynq-ultrascale-trm.pdf`](../../resources/ug1085-zynq-ultrascale-trm.pdf) | Phase 4+: PS/PL AXI ports (Ch. 19), DDR (Ch. 13), DMA (Ch. 10), clocking (Ch. 37), boot (Ch. 11) |

---

*Last updated: 2026-11-05*
