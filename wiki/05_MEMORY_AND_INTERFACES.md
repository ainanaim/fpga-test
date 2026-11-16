# 05 — Memory and Interfaces

> Vision designs are data-hungry. This document covers how data moves from sensor to FPGA, through on-chip memory, and out to displays or host systems.

---

## Table of Contents
1. [Memory Hierarchy on FPGAs](#1-memory-hierarchy-on-fpgas)
2. [Block RAM (BRAM) Deep Dive](#2-block-ram-bram-deep-dive)
3. [External DDR Memory](#3-external-ddr-memory)
4. [AXI4 Bus Protocol](#4-axi4-bus-protocol)
5. [AXI4-Stream — Pixel Streaming](#5-axi4-stream--pixel-streaming)
6. [DMA: Automated Data Movement](#6-dma-automated-data-movement)
7. [Camera Interfaces](#7-camera-interfaces)
8. [Display Interfaces](#8-display-interfaces)
9. [Host Interfaces (Ethernet, USB, PCIe)](#9-host-interfaces-ethernet-usb-pcie)
10. [Memory Architecture Patterns for Vision](#10-memory-architecture-patterns-for-vision)

---

## 1. Memory Hierarchy on FPGAs

| Level | Technology | Capacity | Access latency | Bandwidth |
|-------|-----------|----------|----------------|-----------|
| Registers | FF | Bits–Kb | 1 cycle (0 overhead) | Unlimited (direct wires) |
| Distributed RAM (LUTs) | LUT RAM | Kb | 1–2 cycles | High (many can be read in parallel) |
| Block RAM (BRAM) | On-chip SRAM | Mb (4–8 Mb typical) | 1–2 cycles | ~100 GB/s aggregate |
| UltraRAM (URAM) | On-chip SRAM (UltraScale+) | 10s of Mb | 2–3 cycles | Very high |
| External DRAM (DDR4/LPDDR4) | Off-chip DRAM | GB | 100–300 ns (high variance) | 10–30 GB/s |

**The key insight**: BRAM has enormous bandwidth but tiny capacity. DDR has huge capacity but high latency and limited bandwidth. Good architecture minimizes DDR access.

For vision:
- **Line buffers** → BRAM (need 1–5 rows at a time, low latency)
- **Full frames** → DDR (1920×1080×3 bytes = ~6 MB, doesn't fit in BRAM)
- **Filter weights** → BRAM or registers (small, frequently reused)
- **Feature maps** → DDR or URAM

---

## 2. Block RAM (BRAM) Deep Dive

### BRAM Primitive (Xilinx)

The basic BRAM primitive is `RAMB36E2` (36 Kb). It supports:

| Mode | Depth × Width |
|------|--------------|
| Simple Dual Port (SDP) | 32K × 1, 16K × 2, ... , 512 × 72 |
| True Dual Port (TDP) | Two independent ports (different addresses, widths) |

**True Dual Port** is most useful for vision: one port for writing incoming pixels, one port for reading them into the pipeline.

### BRAM Inference Pattern (Recommended)

```systemverilog
// Line buffer: stores one full row of pixels
// Infers a BRAM automatically
module line_buffer #(
    parameter WIDTH = 1920,
    parameter BITS  = 8
) (
    input  logic             clk,
    input  logic             wr_en,
    input  logic [$clog2(WIDTH)-1:0] wr_addr,
    input  logic [BITS-1:0]  wr_data,
    input  logic [$clog2(WIDTH)-1:0] rd_addr,
    output logic [BITS-1:0]  rd_data
);

logic [BITS-1:0] mem [0:WIDTH-1];

always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];  // registered output = BRAM
end

endmodule
```

### BRAM for Line Buffering in Image Processing

A 3×3 convolution kernel requires access to 3 consecutive rows simultaneously:

```
Row N-2: [ p(n-2,0) | p(n-2,1) | p(n-2,2) | ... ]  ← BRAM line buffer 0
Row N-1: [ p(n-1,0) | p(n-1,1) | p(n-1,2) | ... ]  ← BRAM line buffer 1
Row N:   [ p(n,0)   | p(n,1)   | p(n,2)   | ... ]  ← current row (live)
```

You shift row N → line buffer 1, row N-1 → line buffer 0, then read all three simultaneously for the 3×3 window.

### BRAM cost for common structures

| Structure | Config | BRAM 36K used |
|-----------|--------|--------------|
| 1920-pixel 8-bit line buffer | 2048×8 | 1 |
| 3-line buffer for 1920-wide 8-bit | 3×(2048×8) | 3 |
| 256-entry weight LUT | 256×16 | 1 |
| Small frame buffer (320×240 RGB) | 76,800×24 | 15 |

---

## 3. External DDR Memory

For full-resolution frames, you must use the off-chip DDR (or LPDDR) DRAM connected to the FPGA.

### DDR Interface Components

```
Your RTL logic
      │
      │  AXI4 (memory-mapped)
      ▼
 ┌─────────────────────┐
 │  MIG (Memory        │  ← Xilinx IP Core: Memory Interface Generator
 │  Interface          │     handles all DDR4/DDR3 timing, training,
 │  Generator)         │     refresh, calibration
 └──────────┬──────────┘
            │  Physical DDR signals (DQ, DQS, CLK, ADDR, BA, CS, RAS, CAS, WE)
            ▼
     DDR4/DDR3 SODIMM or on-board LPDDR chip
```

### Key DDR Access Properties

| Property | Value (DDR4-2400) |
|----------|------------------|
| Burst length | 8 beats (minimum transaction) |
| Latency (first beat) | ~100–150 ns (~30 cycles at 200 MHz) |
| Bandwidth (1 channel, 64-bit) | 19.2 GB/s theoretical |
| Practical bandwidth | 10–14 GB/s (after overhead) |
| Refresh overhead | ~5% of time |

**The 100 ns latency problem**: if your pipeline stalls 100 ns every time it needs a pixel, you cannot do real-time video. Solution: **prefetch entire lines into BRAM** using DMA before the pipeline needs them.

### LPDDR on Zynq Boards

Zynq-7000 boards (like PYNQ-Z1) have 512 MB DDR3 connected to the ARM PS, not the PL. To use it from your FPGA fabric:
1. Configure the PS in Block Design (Vivado)
2. Enable the HP (High-Performance) AXI ports on the PS
3. Your PL logic uses AXI4 through HP ports to access PS-side DDR

---

## 4. AXI4 Bus Protocol

**AXI4** (Advanced eXtensible Interface 4) is the standard bus protocol for all Xilinx Zynq and most high-end FPGA SoC designs. Everything — DMA, PS memory access, peripherals — communicates over AXI4.

### AXI4 Channels

AXI4 has 5 independent channels:

| Channel | Direction | Purpose |
|---------|-----------|---------|
| **AW** (Address Write) | Master → Slave | Write address + burst info |
| **W** (Write Data) | Master → Slave | Write data beats |
| **B** (Write Response) | Slave → Master | Write acknowledgment |
| **AR** (Address Read) | Master → Slave | Read address + burst info |
| **R** (Read Data) | Slave → Master | Read data beats |

### Valid/Ready Handshake (Critical)

Every AXI4 channel uses a **two-signal handshake**:

```
         valid
Producer ──────────────────► Consumer
         ◄────────────────── 
         ready
         
Transfer occurs when: valid AND ready are BOTH high on the same clock edge.
```

This is the **backpressure** mechanism: if the consumer is busy (ready = 0), the producer holds the data. If the producer has nothing (valid = 0), the consumer waits. No data is ever dropped or corrupted.

### AXI4 Flavors

| Variant | Full name | Use case |
|---------|-----------|---------|
| **AXI4** | Full AXI4 | Memory-mapped access (DMA read/write) |
| **AXI4-Lite** | Simplified AXI4 | Control registers (single transactions only) |
| **AXI4-Stream** | Streaming AXI4 | Pixel/sample data streaming (no address) |

For vision: use **AXI4-Stream** for the pixel data path, **AXI4-Lite** for configuration registers, **AXI4** for DMA.

---

## 5. AXI4-Stream — Pixel Streaming

AXI4-Stream is the standard for streaming pixel data between modules.

### Signals

| Signal | Direction | Description |
|--------|-----------|-------------|
| `TDATA` | Producer → Consumer | Pixel data (8/16/24/32 bits wide) |
| `TVALID` | Producer → Consumer | Data is valid this cycle |
| `TREADY` | Consumer → Producer | Consumer can accept data |
| `TLAST` | Producer → Consumer | Last beat of a packet (end of line) |
| `TUSER` | Producer → Consumer | Sideband: often used for frame start signal |
| `TKEEP` | Producer → Consumer | Byte enable (which bytes of TDATA are valid) |

### Minimal AXI4-Stream Connection for a Pixel Pipeline

```
Camera IP             Filter Module           Display IP
─────────             ─────────────           ──────────
TDATA  ──────────►  s_axis_tdata ──► m_axis_tdata  ──► TDATA
TVALID ──────────►  s_axis_tvalid──► m_axis_tvalid ──► TVALID
TREADY ◄──────────  s_axis_tready◄── m_axis_tready ◄── TREADY
TLAST  ──────────►  s_axis_tlast ──► m_axis_tlast  ──► TLAST
TUSER  ──────────►  s_axis_tuser ──► m_axis_tuser  ──► TUSER
```

### Frame synchronization convention (Xilinx Video IP)

```
TUSER[0] = SOF (Start of Frame) — asserted on first pixel of first line
TLAST    = EOL (End of Line) — asserted on last pixel of each line
```

This means you can count rows and columns purely from TUSER and TLAST — no separate sync signals needed.

### AXI4-Stream FIFO

When two AXI4-Stream modules run in different clock domains or at different rates, insert an **async FIFO** between them:

```
Xilinx IP: AXI4-Stream Data FIFO (axi_data_fifo)
      or:  AXI4-Stream Clock Converter (axis_clock_converter) — for CDC
```

---

## 6. DMA: Automated Data Movement

**DMA** (Direct Memory Access) transfers data between memory and streaming interfaces without CPU involvement.

### Why DMA is Essential for Video

Capturing a 1080p frame at 60fps:
- 1920 × 1080 × 3 bytes × 60 fps = 373 MB/s
- CPU-managed copy would saturate the ARM core (can't do anything else)
- DMA does the same transfer with ~0% CPU overhead

### Xilinx AXI DMA IP

The standard Xilinx DMA core (`axi_dma`) provides:

```
Memory (DDR)
    │
    │  AXI4 (memory-mapped)
    ▼
┌──────────────┐
│   AXI DMA    │
│              │
│  MM2S channel│ ──► AXI4-Stream ──► Your filter ──► display
│  (Read)      │     (Memory to Stream)
│              │
│  S2MM channel│ ◄── AXI4-Stream ◄── Camera
│  (Write)     │     (Stream to Memory)
└──────────────┘
    │  AXI4-Lite (control)
    ▼
ARM CPU (configures DMA via register writes)
```

### Video DMA: VDMA

For continuous video capture/playback, use `axi_vdma` (Video DMA):
- Supports double/triple buffering automatically
- Knows about frame dimensions (width, height, stride)
- Handles frame boundary synchronization
- Runs continuously without CPU intervention per frame

---

## 7. Camera Interfaces

### MIPI CSI-2 (Mobile Industry Processor Interface Camera Serial Interface 2)

The most common modern camera interface:
- Differential serial lanes (1–4 lanes)
- Data rates: 80 Mbps to 2.5 Gbps per lane
- Encodings: RAW8, RAW10, RAW12, YUV422, RGB888
- Used by: OV5640, IMX219 (Raspberry Pi camera), IMX477, AR0330...

```
Camera sensor
    │  MIPI CSI-2 (1 or 2 lanes, differential)
    ▼
 D-PHY / C-PHY receiver (FPGA SERDES or LVDS pins)
    │
    ▼
 MIPI CSI-2 Rx IP (Xilinx: mipi_csi2_rx_subsystem)
    │
    ▼
 AXI4-Stream (pixels in TDATA, line/frame sync in TLAST/TUSER)
    │
    ▼
 Your processing pipeline
```

**Important**: MIPI CSI-2 requires LVDS-capable I/O pins and usually a D-PHY IP. Verify your target board supports this.

### Parallel Camera Interface (Legacy)

Older sensors (OV7670, OV2640) use a parallel interface:
- 8/10/12 data lines + PCLK + HREF + VSYNC
- Simpler to implement in RTL
- Lower speed (up to ~96 Mbps at 12-bit)
- Good for learning — easy to implement without specialized IP

### USB Camera (via ARM/Linux)

If using a Zynq SoC board running Linux:
- Plug a standard USB UVC camera into the ARM's USB port
- Capture frames via V4L2 in Linux
- DMA frames from ARM DDR to FPGA PL for processing
- Good for prototyping, but introduces latency (not real-time pixel-sync)

---

## 8. Display Interfaces

### HDMI (High-Definition Multimedia Interface)

```
Your design → Video pipeline → HDMI TX IP → HDMI connector → Monitor
```

HDMI in FPGA uses the TMDS (Transition Minimized Differential Signaling) physical layer:
- 3 data channels + 1 clock (all differential pairs)
- Requires LVDS or SERDES-capable I/O

**Standard resolutions and pixel clocks:**

| Resolution | Frame rate | Pixel clock |
|------------|-----------|-------------|
| 720p | 60 fps | 74.25 MHz |
| 1080p | 60 fps | 148.5 MHz |
| 1080p | 30 fps | 74.25 MHz |
| 4K (UHD) | 30 fps | 297 MHz |

Xilinx provides an HDMI TX IP (`v_hdmi_tx_ss`) or you can use the community-favorite open-source **DVI/HDMI core** from Hamsterworks or the HDMI TX from the Digilent IP library.

### DisplayPort

Similar to HDMI but different encoding. Some Zynq UltraScale+ boards have native DP transceivers.

### VGA (Legacy, Easy)

For learning, VGA is the simplest display interface:
- 3 analog signals (R, G, B via resistor DAC or DAC chip)
- HSYNC, VSYNC (digital)
- Easily driven directly from FPGA I/O with resistor ladder or PMOD VGA

```systemverilog
// VGA timing generator (640×480 @ 60 Hz, 25 MHz pixel clock)
// Horizontal: 640 visible + 16 front porch + 96 sync + 48 back porch = 800 total
// Vertical:   480 visible + 11 fp + 2 sync + 31 bp = 524 total
```

Many starter boards (Basys 3, Nexys A7) have VGA connectors directly. Use VGA for your first display experiments.

---

## 9. Host Interfaces (Ethernet, USB, PCIe)

For feeding images from a computer to the FPGA or sending results back:

| Interface | Throughput | Latency | Complexity | Use case |
|-----------|-----------|---------|------------|---------|
| **UART** | 1 Mbps | ~ms | Very simple | Config, debug, tiny images |
| **USB UART** | 10 Mbps | ~ms | Simple | Same as above |
| **Gigabit Ethernet** | 125 MB/s | ~ms | Moderate | Stream images, receive results |
| **10GbE** | 1.25 GB/s | ~ms | High | High-speed data |
| **PCIe Gen3 x4** | ~4 GB/s | ~us | Very high | High-bandwidth host accelerator |
| **USB 3.0** | ~350 MB/s | ~ms | High (needs IP) | Frame transfer |

For a learning project: **GigE (1000BASE-T)** via UDP or RTSP is a good choice — most FPGA boards have an Ethernet PHY, and Xilinx provides the GigE MAC IP.

---

## 10. Memory Architecture Patterns for Vision

### Pattern 1: Streaming (No Frame Buffer)

```
Camera → [Filter A] → [Filter B] → [Filter C] → Display
              BRAM line buffers only
```
- Best latency (1–2 lines)
- No DDR needed
- Only works for algorithms that need ≤ a few lines of lookahead
- Examples: edge detection, threshold, color conversion, simple blur

### Pattern 2: Ping-Pong (Two Frame Buffers)

```
Camera → Write to Buffer A →     Read from Buffer B → Process → Display
                           ↓     ↑
          when frame done: swap A ↔ B
```
- One frame of latency
- Requires 2 × frame size in DDR
- Allows complex per-frame processing (doesn't need streaming)
- Examples: optical flow, background subtraction, JPEG encode

### Pattern 3: Triple Buffer

```
Buffer A: Writing (camera capture)
Buffer B: Reading (processing)
Buffer C: Displaying (output)
```
- Completely decouples capture / process / display
- 3 × frame size in DDR
- Used in professional video pipelines

### Pattern 4: HLS Dataflow (Multi-stage Pipeline with FIFOs)

```
Camera → [Stage 1] →FIFO→ [Stage 2] →FIFO→ [Stage 3] → Display
                   BRAM FIFOs between stages
```
- Multiple processing stages connected by FIFOs
- Each stage can run at its own rate
- HLS DATAFLOW pragma handles this automatically
- Good for complex multi-algorithm pipelines

---

**Next**: [06 — Vision on FPGAs](./06_VISION_ON_FPGA.md)
