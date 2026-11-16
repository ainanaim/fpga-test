# 03 — HDL and High-Level Synthesis

> Two approaches to describing hardware: **RTL** (write the circuit directly in Verilog/VHDL) or **HLS** (let the tool compile your C++ into circuits). Neither is strictly better — the choice depends on your goal.

---

## Table of Contents
1. [The Design Entry Landscape](#1-the-design-entry-landscape)
2. [Verilog — the Dominant RTL Language](#2-verilog--the-dominant-rtl-language)
3. [SystemVerilog — Modern Verilog](#3-systemverilog--modern-verilog)
4. [VHDL — the Other RTL Language](#4-vhdl--the-other-rtl-language)
5. [High-Level Synthesis (HLS)](#5-high-level-synthesis-hls)
6. [Choosing Your Path](#6-choosing-your-path)
7. [Simulation Basics](#7-simulation-basics)
8. [HDL Style Guide for Vision Designs](#8-hdl-style-guide-for-vision-designs)

---

## 1. The Design Entry Landscape

```
Abstraction level (high → low)

  Python / MATLAB      ← algorithm prototyping only, not synthesizable
       |
  OpenCL / HLS C++     ← Vitis HLS, Intel HLS; generates RTL
       |
  SystemVerilog / Verilog / VHDL  ← RTL; direct circuit description
       |
  Gate-level netlist   ← output of synthesis; not written by hand
       |
  FPGA bitstream       ← loaded onto device
```

For this project you will work primarily at the **RTL** or **HLS** level. Everything above is for algorithmic exploration; everything below is handled by tools.

---

## 2. Verilog — the Dominant RTL Language

Verilog (IEEE 1364, later merged into SystemVerilog IEEE 1800) is the dominant hardware description language in industry and academia for FPGA/ASIC design.

### Module Structure

Every design unit is a **module**:

```verilog
module my_module (
    input  wire        clk,
    input  wire        rst_n,       // active-low reset
    input  wire [7:0]  data_in,
    output reg  [7:0]  data_out
);

// Internal signals
wire [7:0] shifted;

// Combinational logic
assign shifted = data_in >> 1;

// Sequential logic (register)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_out <= 8'h00;
    else
        data_out <= shifted;
end

endmodule
```

### Key Verilog Concepts

| Concept | Description |
|---------|-------------|
| `wire` | Combinational connection (no memory) |
| `reg` | Signal that can be assigned in `always` block (can be FF or latch) |
| `assign` | Continuous assignment — describes combinational logic |
| `always @(posedge clk)` | Clocked process — describes sequential logic (FFs) |
| `always @(*)` | Combinational process — describes combinational logic |
| `<=` (non-blocking) | Used in clocked `always` blocks — evaluates RHS before updating |
| `=` (blocking) | Used in combinational `always` blocks — evaluates immediately |
| `parameter` | Compile-time constant (makes modules reusable) |
| `generate` | Generates repeated hardware (e.g., array of modules) |

### Critical Rule: Non-Blocking vs Blocking Assignment

```verilog
// CORRECT: sequential logic uses non-blocking <=
always @(posedge clk) begin
    a <= b;  // a gets OLD value of b
    b <= a;  // b gets OLD value of a — this SWAPS a and b
end

// WRONG if intended as swap — using blocking =
always @(posedge clk) begin
    a = b;   // a gets new value of b
    b = a;   // b gets new value of a — which is now b (not swapped!)
end
```

This is one of the most common Verilog bugs.

### Number Literals

```verilog
8'b1010_1010   // 8-bit binary
8'hAA          // 8-bit hex
12'd42         // 12-bit decimal
1'b1           // 1-bit (single bit)
4'bz           // high-impedance (tri-state)
4'bx           // unknown/don't-care (simulation only)
```

### Instantiating Modules (Hierarchy)

```verilog
// Top-level module instantiates sub-modules
threshold_filter #(
    .THRESHOLD(128)   // parameter override
) filter_inst (
    .clk      (clk),
    .data_in  (pixel_data),
    .data_out (filtered_pixel)
);
```

### Parameterizable Modules (Essential for Vision)

```verilog
module rgb_to_gray #(
    parameter DATA_WIDTH = 8
) (
    input  wire [DATA_WIDTH-1:0] r, g, b,
    output wire [DATA_WIDTH-1:0] gray
);
    // Approximate: 0.299R + 0.587G + 0.114B
    // Fixed-point: (77*R + 150*G + 29*B) >> 8
    wire [DATA_WIDTH+7:0] sum;
    assign sum  = (8'd77 * r) + (8'd150 * g) + (8'd29 * b);
    assign gray = sum[DATA_WIDTH+7:8];  // right shift by 8
endmodule
```

---

## 3. SystemVerilog — Modern Verilog

SystemVerilog (IEEE 1800-2012) extends Verilog with:
- `logic` type (replaces the `reg`/`wire` confusion)
- `always_ff`, `always_comb`, `always_latch` (intent-checking)
- `interface` (bundle signals between modules cleanly)
- `enum` for state machine states
- `struct`/`union` for grouping signals
- `package` for shared definitions
- Powerful testbench features (classes, randomization, assertions)

**Recommendation**: Write RTL in **SystemVerilog** from the start. The `always_ff`/`always_comb` distinction catches a whole class of errors at synthesis time.

```systemverilog
// SystemVerilog state machine — cleaner than Verilog
typedef enum logic [1:0] {
    IDLE    = 2'b00,
    CAPTURE = 2'b01,
    PROCESS = 2'b10,
    OUTPUT  = 2'b11
} state_t;

state_t state, next_state;

always_ff @(posedge clk) begin
    if (rst) state <= IDLE;
    else     state <= next_state;
end

always_comb begin
    next_state = state;  // default: hold state
    case (state)
        IDLE:    if (start)    next_state = CAPTURE;
        CAPTURE: if (captured) next_state = PROCESS;
        PROCESS: if (done)     next_state = OUTPUT;
        OUTPUT:               next_state = IDLE;
    endcase
end
```

---

## 4. VHDL — the Other RTL Language

VHDL (IEEE 1076) is more verbose and strongly typed. Common in European academia, aerospace, and defense.

```vhdl
-- Same shift-register in VHDL
entity my_module is
    port (
        clk      : in  std_logic;
        data_in  : in  std_logic_vector(7 downto 0);
        data_out : out std_logic_vector(7 downto 0)
    );
end entity my_module;

architecture rtl of my_module is
begin
    process(clk)
    begin
        if rising_edge(clk) then
            data_out <= '0' & data_in(7 downto 1);  -- right shift
        end if;
    end process;
end architecture rtl;
```

**For this project**: Use **Verilog or SystemVerilog** unless your institution mandates VHDL. The majority of open-source FPGA cores and community examples use Verilog.

---

## 5. High-Level Synthesis (HLS)

HLS lets you write your algorithm in **C/C++** and have a tool automatically generate the RTL.

### How HLS Works

```
C++ function (annotated with pragmas)
       |
  [HLS Tool: Vitis HLS / Intel HLS]
       |
  Verilog/VHDL RTL module
       |
  Normal synthesis/P&R flow
```

### HLS Pragmas (Xilinx Vitis HLS)

```cpp
#include "hls_stream.h"
#include "ap_int.h"

void gaussian_blur(
    hls::stream<ap_uint<8>>& pixel_in,
    hls::stream<ap_uint<8>>& pixel_out,
    int width, int height)
{
#pragma HLS INTERFACE axis port=pixel_in
#pragma HLS INTERFACE axis port=pixel_out
#pragma HLS PIPELINE II=1    // Initiation Interval = 1 cycle (fully pipelined)

    // HLS generates a pipelined hardware implementation
    // of whatever C++ you write here
}
```

### HLS Pragmas You Must Know

| Pragma | Effect |
|--------|--------|
| `#pragma HLS PIPELINE II=1` | Pipeline the loop — accept new input every 1 cycle |
| `#pragma HLS UNROLL factor=4` | Unroll loop 4x — 4 iterations run in parallel |
| `#pragma HLS DATAFLOW` | Pipeline functions like assembly line (producer-consumer) |
| `#pragma HLS ARRAY_PARTITION dim=1 complete` | Split array into registers (parallel access) |
| `#pragma HLS INTERFACE axis` | Generate AXI4-Stream interface |
| `#pragma HLS INTERFACE m_axi` | Generate AXI4 master interface (DMA-capable) |
| `#pragma HLS RESOURCE variable=x core=RAM_2P_BRAM` | Use BRAM for array `x` |

### HLS Data Types

HLS provides custom integer types that map to arbitrary-width hardware:

```cpp
#include "ap_int.h"
#include "ap_fixed.h"

ap_uint<10>  pixel;          // 10-bit unsigned integer
ap_int<16>   coefficient;    // 16-bit signed integer
ap_fixed<16,8> fp_val;       // 16-bit fixed-point: 8 integer + 8 fractional bits
```

### HLS Trade-offs

| Aspect | RTL (Verilog) | HLS (C++) |
|--------|--------------|-----------|
| Development speed | Slow | Fast |
| Code understandability | Low (for beginners) | High |
| Generated quality (QoR) | Excellent (you control) | Good (tool decides) |
| Fine-grained control | Full | Limited (via pragmas) |
| Timing closure ease | Manual | Semi-automatic |
| Debugging | Simulation waveforms | C simulation + cosim |
| Learning curve | Steep | Moderate |
| Portability | Low (tool-specific) | Low (pragma-specific) |

---

## 6. Choosing Your Path

### Decision Guide

```
Do you need to process live video at >60fps?
├── YES → RTL is safer for guaranteed II=1 pipelines
└── NO  → HLS may be fine

Do you need to control exact timing (pixel-synchronous output)?
├── YES → RTL for the timing-critical parts
└── NO  → HLS

Is this for learning FPGA fundamentals?
├── YES → Start with RTL (Verilog/SystemVerilog). You MUST understand RTL 
│         even if you eventually use HLS.
└── NO  → HLS for faster prototyping

Are you implementing a CNN/ML inference layer?
├── YES → Vitis AI (pre-built) or HLS with DATAFLOW pragma
└── NO  → depends on above

Is the algorithm inherently sequential/iterative?
├── YES → HLS handles this better than manual RTL
└── NO  → RTL pipeline
```

### Recommended approach for this project

1. **Learn RTL first** (Verilog/SystemVerilog) — spend 2–4 weeks on fundamentals
2. **Implement basic image ops in RTL** — grayscale, threshold, simple filters
3. **Use HLS for complex algorithms** — Gaussian blur with large kernel, CNN layers
4. **Mix both** in the final design — RTL for pixel-synchronous path, HLS for computation blocks

---

## 7. Simulation Basics

**You cannot test FPGA designs on hardware alone.** Simulation is mandatory.

### Testbench Structure

```verilog
// A testbench is NOT synthesizable — it drives your design
module tb_my_filter;

// Clock generation
reg clk = 0;
always #5 clk = ~clk;  // 100 MHz (10 ns period)

// DUT (Device Under Test) connections
reg  [7:0] pixel_in;
wire [7:0] pixel_out;

// Instantiate the module to test
my_filter dut (
    .clk      (clk),
    .pixel_in (pixel_in),
    .pixel_out(pixel_out)
);

// Stimulus
initial begin
    $dumpfile("waveform.vcd");
    $dumpvars(0, tb_my_filter);

    pixel_in = 8'd0;    #20;
    pixel_in = 8'd128;  #20;
    pixel_in = 8'd255;  #20;

    $display("Done");
    $finish;
end

endmodule
```

### Simulators

| Tool | License | Notes |
|------|---------|-------|
| **ModelSim / Questa** | Vendor (Xilinx/Intel include a lite version) | Industry standard |
| **Vivado Simulator (xsim)** | Free with Vivado | Adequate for most tasks |
| **Icarus Verilog (iverilog)** | Open source | Great for learning |
| **Verilator** | Open source | Fastest; converts to C++ for fast sims |
| **GHDL** | Open source | VHDL only |

**Workflow**: write testbench → simulate → check waveforms in GTKWave (free) or Vivado Waveform Viewer.

### For image/video testbenches

Read pixel data from a file (`.pgm`, `.csv`, or binary), drive it through your DUT, write output back to a file, compare with MATLAB/Python reference output.

```verilog
// Read image file in testbench
integer fd;
reg [7:0] pixel;

initial begin
    fd = $fopen("input_image.bin", "rb");
    while (!$feof(fd)) begin
        pixel = $fgetc(fd);
        @(posedge clk);
        pixel_in = pixel;
    end
    $fclose(fd);
end
```

---

## 8. HDL Style Guide for Vision Designs

Good RTL style makes your design maintainable, synthesizable, and debuggable.

### File and Module Organization

```
src/
├── rtl/
│   ├── top/          ← top-level integration modules
│   ├── pipeline/     ← pixel pipeline stages
│   ├── control/      ← FSMs, sequencers
│   └── common/       ← reusable primitives (FIFO, counter, etc.)
├── sim/
│   ├── tb_*.sv       ← testbenches
│   └── models/       ← behavioral models of external devices
└── constraints/
    └── *.xdc         ← timing and pin constraints
```

### Naming Conventions

```verilog
// Signals
clk_pixel        // clock for pixel domain
clk_proc         // clock for processing domain
rst_n            // active-low reset (suffix _n)
vsync, hsync     // video sync signals
pixel_valid      // data valid signal
pixel_data       // actual pixel data
frame_start      // pulse: 1 cycle at start of frame
line_end         // pulse: 1 cycle at end of each line

// Registers vs wires
reg_data_q       // registered (q = "output of FF" in EE notation)
comb_result      // combinational/wire signal
```

### Always use parameters for image dimensions

```verilog
parameter IMG_WIDTH  = 1920;
parameter IMG_HEIGHT = 1080;
parameter PIXEL_BITS = 8;

// Never hardcode magic numbers
// BAD:  if (col_cnt == 1920) ...
// GOOD: if (col_cnt == IMG_WIDTH) ...
```

### Reset everything that matters

```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        pixel_out   <= '0;
        pixel_valid <= 1'b0;
        col_cnt     <= '0;
        row_cnt     <= '0;
    end else begin
        // normal operation
    end
end
```

---

**Next**: [04 — Toolchain and Design Flow](./04_TOOLCHAIN_AND_FLOW.md)
