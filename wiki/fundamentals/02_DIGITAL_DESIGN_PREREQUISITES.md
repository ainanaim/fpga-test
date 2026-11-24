# 02 — Digital Design Prerequisites

> Before writing HDL, you must understand **how digital circuits think**. This document covers the foundational concepts that underpin every FPGA design.

---

## Table of Contents
1. [Number Systems and Representation](#1-number-systems-and-representation)
2. [Combinational Logic](#2-combinational-logic)
3. [Sequential Logic and State](#3-sequential-logic-and-state)
4. [Clock Domains](#4-clock-domains)
5. [Timing: Setup, Hold, and Critical Paths](#5-timing-setup-hold-and-critical-paths)
6. [Pipelining](#6-pipelining)
7. [Finite State Machines (FSMs)](#7-finite-state-machines-fsms)
8. [Synchronization: Clock Domain Crossing](#8-synchronization-clock-domain-crossing)
9. [Reset Strategy](#9-reset-strategy)
10. [Fixed-Point Arithmetic](#10-fixed-point-arithmetic)
11. [Common Pitfalls for Software Engineers](#11-common-pitfalls-for-software-engineers)

---

## 1. Number Systems and Representation

### Binary, Hex, Two's Complement

You must be comfortable with:

| Format | Description | Example (decimal 42) |
|--------|-------------|----------------------|
| Binary | Base-2 | `0b00101010` |
| Hex | Base-16 | `0x2A` |
| Unsigned | No sign bit, range [0, 2^N - 1] | 8-bit: 0–255 |
| Signed (two's complement) | MSB is sign; range [−2^(N-1), 2^(N-1)−1] | 8-bit: −128–127 |

**Two's complement** is universal in digital design. Negation: flip all bits, add 1.

```
 42 = 0010 1010
-42 = 1101 0110  (flip) + 1 = 1101 0110
```

### Bit widths and overflow

Unlike Python (arbitrary precision), hardware integers have **fixed width**. Overflow wraps around silently:
- 8-bit: `255 + 1 = 0` (unsigned wrap)
- Saturation arithmetic (clamp instead of wrap) must be **explicitly designed**

This is critical for pixel arithmetic — adding two 8-bit pixel values can overflow to 0 if not handled.

---

## 2. Combinational Logic

Combinational circuits have **no memory** — outputs depend only on current inputs.

### Basic Gates

```
AND:  Y = A & B
OR:   Y = A | B
NOT:  Y = ~A
XOR:  Y = A ^ B
NAND: Y = ~(A & B)
NOR:  Y = ~(A | B)
```

### Key Combinational Structures

| Structure | Description | Vision use |
|-----------|-------------|------------|
| Multiplexer (MUX) | Select one of N inputs | Pixel routing |
| Decoder | 1-of-N output | Address decoding |
| Encoder/Priority Encoder | Compress binary | Feature extraction |
| Comparator | A == B, A > B | Threshold |
| Adder | A + B with carry | Accumulation |
| Shifter | Barrel shift, divide/multiply by power of 2 | Scaling |

### Propagation Delay

Combinational logic takes time to settle. Each gate introduces a **propagation delay** (~0.1–0.5 ns per gate level on FPGA). Multi-level logic adds these up — this is what limits your maximum clock frequency.

```
Input → [LUT 1] → [LUT 2] → [LUT 3] → Output
         0.3 ns    0.3 ns    0.3 ns    total: ~0.9 ns
                                       → max freq ≈ 1/0.9ns = 1.1 GHz (ideal)
                                         (routing adds more delay in practice)
```

---

## 3. Sequential Logic and State

Sequential circuits add memory via **flip-flops**. The output depends on **current inputs AND past state**.

### D Flip-Flop Behavior

```
On rising edge of CLK:
   Q <= D
Between edges:
   Q holds its value
```

### Why everything is clocked

In synchronous digital design, **all state changes happen on clock edges**. This makes the circuit predictable and analyzable. Asynchronous circuits exist but are extremely difficult to design correctly.

**Golden rule**: every piece of state in your design is a register, and registers change only at clock edges.

### Registers, Shift Registers, Counters

```
Register (N-bit):         N flip-flops in parallel
Shift register:           FFs in series — data shifts right/left each cycle
Counter:                  Register that increments each cycle
Accumulator:              Register that adds an input each cycle
```

Shift registers are extremely useful in image processing — a 1-row shift register of width W is a **line delay** (delays one full row of pixels).

---

## 4. Clock Domains

The **clock** is the heartbeat of your circuit. All FFs that share the same clock signal form a **clock domain**.

```
CLK: __|‾|__|‾|__|‾|__|‾|__|‾|__
     Period = 10 ns → Frequency = 100 MHz
```

**Common clock frequencies in vision designs:**
- Pixel clock: 148.5 MHz (1080p 60fps, standard HDMI)
- 74.25 MHz (1080p 30fps or 720p 60fps)
- Processing clock: 100–200 MHz (your FPGA fabric clock)
- Memory interface: 300–533 MHz (DDR controller, internally doubled)

### Clock Skew

The clock signal itself has routing delay and variation (**skew**) across the chip. FPGA tools use dedicated **clock routing networks** (global/regional clock buffers) to distribute clocks with minimal skew. Always use these — never use a signal as a clock unless it comes through a clock buffer.

---

## 5. Timing: Setup, Hold, and Critical Paths

This is the concept that trips up nearly every FPGA beginner. **You must understand this before writing a single RTL line.**

### Setup Time (Tsu)

The FF requires that input D be **stable for a minimum time (Tsu) before the clock edge**. If D changes too late, the FF may latch an incorrect value — **metastability**.

### Hold Time (Th)

The FF requires that D remain stable for a minimum time (Th) **after the clock edge**.

```
            Setup window      Hold window
                |<--Tsu-->|<--Th-->|
D: ════════════XXXXXXXXXXXXXXXXXXX══════════
CLK:          ___↑
```

### Critical Path

The **critical path** is the longest combinational path between any two FFs in your design. Its delay determines your maximum clock frequency:

```
Fmax = 1 / (Tsetup + Tcritical_path + Tskew)
```

If your critical path is 7 ns and your setup/skew budget is 1 ns, you can run at 1/8ns = 125 MHz.

**How to fix a failing timing path:**
1. Add a pipeline register in the middle of the long path (break it into two shorter paths)
2. Restructure the logic (fewer logic levels)
3. Use retiming (the tool can sometimes automatically do this)
4. Lower the clock frequency target (last resort)

### Timing Reports

Every FPGA tool produces timing reports. Learn to read them:
```
Path: FF_A/Q → LUT_1 → LUT_2 → LUT_3 → FF_B/D
Data arrival time:  7.823 ns
Data required time: 7.500 ns
Slack:              -0.323 ns  ← NEGATIVE = FAIL
```

Negative slack = timing violation = your design is wrong. Period.

---

## 6. Pipelining

Pipelining is **the most important design pattern** in FPGA development. It is how you turn a slow multi-cycle computation into a high-throughput streaming operation.

### Without pipelining (slow)

```
Stage 1 → Stage 2 → Stage 3 → Stage 4
|<── 4 ns ──>|<── 3 ns ──>|<── 5 ns ──>|<── 2 ns ──>|
Total delay = 14 ns → Fmax ≈ 71 MHz
Input must wait 14 ns before next input
```

### With pipelining (fast)

Insert registers between stages:

```
Stage 1 → [FF] → Stage 2 → [FF] → Stage 3 → [FF] → Stage 4
 4 ns             3 ns             5 ns             2 ns
Fmax limited by slowest stage: 1/5ns = 200 MHz
Latency = 4 cycles (data takes 4 cycles to emerge)
Throughput = 1 result per cycle (200M results/sec)
```

### Pipeline Latency vs Throughput Trade-off

| Property | No Pipeline | 4-stage Pipeline |
|----------|------------|-----------------|
| Latency | 14 ns (1 cycle) | 20 ns (4 cycles @ 5 ns) |
| Throughput | 71M/s | 200M/s |
| Resource usage | Low (no extra FFs) | Higher (3 extra FF stages) |

For streaming video, **throughput matters more than latency** — you want to process one pixel per clock, every clock.

### Key rule: all pipeline stages must accept new data every cycle

If stage 2 sometimes stalls for 2 cycles, stage 1 must hold its output (backpressure). This is handled with **valid/ready handshaking** (AXI4-Stream protocol) — see [05_MEMORY_AND_INTERFACES.md](./05_MEMORY_AND_INTERFACES.md).

---

## 7. Finite State Machines (FSMs)

An FSM describes a system with a discrete number of states and transitions between them.

```
         reset
           |
           v
        [IDLE] ──start──> [LOAD] ──done──> [PROCESS] ──done──> [OUTPUT]
           ^                                                        |
           └────────────────────────────────────────────────────────┘
```

**Types:**
- **Moore**: outputs depend only on current state (cleaner, more stable)
- **Mealy**: outputs depend on state AND current inputs (fewer states, but glitchy)

**In HDL:**
- Encode states as `localparam` or `enum`
- Use separate `always` blocks for: (1) state register, (2) next-state logic, (3) output logic

FSMs control sequencing in vision systems: frame capture, DMA initiation, processing trigger, result readout.

---

## 8. Synchronization: Clock Domain Crossing

When data crosses from one clock domain to another (e.g., 74.25 MHz pixel clock → 100 MHz processing clock), you **cannot** just wire the signal directly. The receiving FF may sample during a transition → **metastability** → unpredictable output.

### Solutions

| Technique | Use when |
|-----------|---------|
| **2-FF synchronizer** | Single-bit control signal crossing |
| **Handshake synchronizer** | Slow control signals |
| **Async FIFO** | Multi-bit data stream crossing clock domains |
| **Shared BRAM with gray-code pointers** | High-bandwidth crossing |

The **async FIFO** (using Gray-coded read/write pointers) is the standard solution for video pixel data crossing clock domains. Most FPGA vendors provide an IP core for this.

**Warning**: NEVER use a multi-bit signal directly across clock domains without synchronization. This is a common beginner mistake that causes intermittent, hard-to-debug failures.

---

## 9. Reset Strategy

Resets bring your circuit to a known state. There are two styles:

| Style | Synchronous Reset | Asynchronous Reset |
|-------|-------------------|-------------------|
| When applied | Only at clock edge | Immediately, any time |
| Xilinx preferred | Yes | Only if necessary |
| HDL pattern | `if (rst) Q <= 0;` inside `always @(posedge clk)` | `always @(posedge clk or posedge rst)` |
| Risk | Reset may not catch all failures | Glitches on reset line can corrupt state |

**Best practice for Xilinx FPGAs**: use **synchronous, active-high reset** in most cases. Keep the reset tree small — only reset FFs that strictly require it. Excessive reset logic consumes routing resources.

---

## 10. Fixed-Point Arithmetic

FPGAs can implement floating point (and tools will if you ask), but it is **expensive** — a single-precision FP adder costs ~200 LUTs and multiple clock cycles. For vision:

- Pixel values are integers (8-bit, 10-bit, 12-bit)
- Filter coefficients can be represented as fixed-point fractions
- Use **Q-format notation**: `Qm.n` = m integer bits, n fractional bits

### Example: Gaussian blur coefficient 0.0625 = 1/16

Instead of storing `0.0625` as float, represent it as: multiply by 16, store as integer, divide (shift) result by 16 at the end.

```
pixel_in = 128 (8-bit)
coefficient = 1/16

Floating point:  128.0 × 0.0625 = 8.0        (expensive)
Fixed point:     128 × 1 = 128, then >> 4 = 8 (free: just shift)
```

**Bit growth**: multiplying an M-bit number by an N-bit number produces an (M+N)-bit result. You must decide where to truncate (lose precision) or saturate (prevent overflow). Design your data path widths carefully.

---

## 11. Common Pitfalls for Software Engineers

If you come from Python/C, these will surprise you:

| Software assumption | FPGA reality |
|--------------------|-------------|
| Variables hold values | Signals describe connections — assigning a signal in two places creates a conflict |
| Code runs top-to-bottom | All `always` blocks run simultaneously every clock cycle |
| Arrays index into memory | Bit-slicing `[7:0]` in HDL selects specific wires |
| `if/else` is branching | `if/else` in combinational logic generates a MUX, not a branch |
| Loops iterate over time | Unrolled `for` loops generate parallel hardware |
| Division is easy | Hardware division is expensive; use multiplication by reciprocal instead |
| Floating point is default | Fixed-point is the FPGA default; FP requires explicit IP |
| Functions call and return | Pipelined modules have latency measured in cycles, not returns |
| Debugging with print() | Debugging uses: synthesis warnings, simulation waveforms, ILA (in-circuit logic analyzer — optional, needs JTAG cable) |

---

**Next**: [03 — HDL and HLS](./03_HDL_AND_HLS.md)
