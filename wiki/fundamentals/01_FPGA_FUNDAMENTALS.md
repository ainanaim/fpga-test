# 01 — FPGA Fundamentals

> "An FPGA is not a chip that runs programs. It is a chip that **becomes** a circuit."

---

## Table of Contents
1. [What is an FPGA?](#1-what-is-an-fpga)
2. [Inside the Fabric](#2-inside-the-fabric)
   - 2.1 Look-Up Tables (LUTs)
   - 2.2 Flip-Flops (FFs)
   - 2.3 Carry Chains
   - 2.4 DSP Slices
   - 2.5 Block RAM (BRAM)
   - 2.6 Routing Fabric
   - 2.7 Hard IP Blocks
3. [How Configuration Works](#3-how-configuration-works)
4. [FPGA vs CPU vs GPU vs ASIC](#4-fpga-vs-cpu-vs-gpu-vs-asic)
5. [FPGA Families You Will Encounter](#5-fpga-families-you-will-encounter)
6. [The SoC FPGA — Best of Both Worlds](#6-the-soc-fpga--best-of-both-worlds)
7. [How the FPGA Counts Resources](#7-how-the-fpga-counts-resources)
8. [Key Takeaways](#8-key-takeaways)

---

## 1. What is an FPGA?

**FPGA** stands for **Field-Programmable Gate Array**.

- **Field-Programmable**: Programmed in the field (i.e., after manufacturing), by you, using software tools.
- **Gate Array**: Underlying silicon contains a large grid of configurable logic cells and routing resources.

The FPGA starts as a blank slate. You write a **Hardware Description Language (HDL)** program, run it through a tool chain, and the tool produces a **bitstream** — a binary configuration file. When you download this bitstream to the FPGA, the internal routing and logic is set up to implement your specific circuit. The chip literally "becomes" your design.

### Why this matters for vision:
A 1080p 60 fps video stream pushes ~3 GB/s of raw pixel data. An FPGA can process every pixel of every frame in a **single clock cycle** per stage — in real time — because every processing unit you describe exists as physical hardware running in parallel.

---

## 2. Inside the Fabric

### 2.1 Look-Up Tables (LUTs)

A LUT is the most fundamental logic primitive.

A **6-input LUT (LUT6)** can implement **any Boolean function of 6 inputs**. It works like a 64-entry truth table stored in SRAM: the 6 input bits form a 6-bit address that selects one of 64 stored output bits.

```
Inputs: A, B, C, D, E, F  (6 bits → 64 possible combinations)
LUT contents: 64-bit memory programmed by the bitstream
Output: the stored bit at address [A,B,C,D,E,F]
```

This means:
- An AND gate of 3 inputs? One LUT.
- A 4-to-1 multiplexer? One LUT.
- One bit of a 4-bit adder? One LUT (carry comes from the carry chain).
- A pixel threshold comparator? One or two LUTs.

Modern FPGAs contain hundreds of thousands to millions of LUTs.
Example: Xilinx Artix-7 XC7A200T — 134,600 LUTs.

### 2.2 Flip-Flops (FFs)

A **flip-flop** (FF) is a 1-bit D-type register. It captures its input on the **rising edge of the clock** and holds that value until the next rising edge.

```
   D ──┤>──── Q
       CLK
```

FFs are what make circuits **sequential** (stateful). Without them, you'd only have combinational logic — circuits with no memory. Every pipeline register, counter, state machine state, and shift register is built from FFs.

FPGAs pair one or more FFs with each LUT — typically there are as many or more FFs than LUTs.

**Rule of thumb**: every `always @(posedge clk)` assignment in Verilog maps to one FF per bit.

### 2.3 Carry Chains

Adjacent LUTs are connected by a **dedicated carry chain** — a fast path specifically for arithmetic carry propagation. Without this, adding two 32-bit numbers would route through general routing (slow). With carry chains, multi-bit adders and comparators run at nearly the speed of a single LUT.

This is why adders and counters are cheap on FPGAs.

### 2.4 DSP Slices

Multiplications are expensive in LUTs (a 16×16 multiply would need ~32+ LUTs). FPGAs embed **hardened DSP blocks** in the fabric — dedicated silicon for multiply-accumulate (MAC) operations.

| Vendor family | DSP primitive | Multiplier width | Accumulator |
|---------------|--------------|-----------------|-------------|
| Xilinx 7-series | DSP48E1 | 25 × 18 → 48-bit | Yes (48-bit) |
| Xilinx UltraScale+ | DSP48E2 | 27 × 18 → 58-bit | Yes (58-bit) |
| Intel Cyclone V | DSP Block | 18 × 18 → 36-bit | Yes |
| Intel Arria 10 | DSP Block | 27 × 27 | Yes |

**For vision/AI workloads, DSP slices are your most precious resource.** Convolutions, filters, matrix multiplications — all consume DSPs. Plan your architecture around DSP count.

A single Xilinx Zynq-7020 has **220 DSP48E1 slices** — enough for a modest CNN layer.

### 2.5 Block RAM (BRAM)

FPGAs contain arrays of **on-chip SRAM** called Block RAM (BRAM). Key properties:

- **Capacity**: each block is typically 18 Kb or 36 Kb (varies by family)
- **Ports**: true dual-port (two simultaneous independent read/write accesses)
- **Speed**: single-cycle access (1 clock latency for read)
- **Bandwidth**: 2 × (data width × clock frequency); at 200 MHz with 32-bit width = 6.4 GB/s per BRAM
- **No external memory controller needed** — deterministic latency

BRAM is used for:
- Line buffers in image processing (store one or more rows of pixels)
- Frame buffers (small images only — a 640×480 grayscale frame = 2.3 Mb = ~65 BRAMs)
- Weight storage for neural network layers
- FIFOs between pipeline stages

| Board | BRAM count | Total on-chip RAM |
|-------|-----------|-------------------|
| Artix-7 XC7A35T | 50 × 36 Kb | 1.8 Mb |
| Zynq-7020 | 140 × 36 Kb | 4.9 Mb |
| Zynq UltraScale+ ZU3EG | 216 × 36 Kb | 7.6 Mb |

**For 1080p video, full frames do NOT fit in BRAM.** You will need external DDR memory and DMA — see [05_MEMORY_AND_INTERFACES.md](./05_MEMORY_AND_INTERFACES.md).

### 2.6 Routing Fabric

Between logic cells sits a **programmable routing fabric** — a grid of wires and configurable switch points (muxes). The place-and-route tool decides which wires connect which cells.

Routing is what limits clock frequency in practice. Long routes across the chip have high capacitance (slow). The tool reports timing: if a path is "failing by 2 ns" it means the data can't travel far enough in one clock period.

**You cannot directly control routing** (without floorplanning constraints), but you can help the tool by:
- Keeping related logic near each other (pipelining breaks long paths into shorter stages)
- Avoiding unnecessarily wide buses across the chip
- Setting realistic clock frequency targets

### 2.7 Hard IP Blocks

Modern FPGAs include pre-built, hardened silicon blocks that are far more efficient than equivalent LUT implementations:

| Hard Block | Purpose |
|-----------|---------|
| **PCIe controller** | High-speed host interface |
| **DDR memory controller** | Interface to external LPDDR/DDR4 |
| **Ethernet MAC** (GigE, 10GigE) | Network connectivity |
| **SERDES / transceivers** | High-speed serial I/O (HDMI, DisplayPort, USB3) |
| **ARM Cortex-A core** (SoC FPGAs) | Full-blown processor on the same chip |
| **Video codec blocks** | H.264/H.265 encoder/decoder (some FPGAs) |
| **ADC/DAC** (some families) | Analog I/O |

For vision projects, the most relevant are: DDR controller, SERDES (for MIPI/HDMI), and ARM core (for SoC FPGAs).

---

## 3. How Configuration Works

```
  HDL source code
       |
       v
  [Synthesis]  ← converts RTL to gate-level netlist
       |
       v
  [Place & Route]  ← maps netlist to physical FPGA sites
       |
       v
  [Bitstream generation]
       |
       v
  [JTAG / QSPI programming]
       |
       v
  FPGA configured and running your circuit
```

The bitstream is typically loaded via:
- **JTAG** (direct USB-to-JTAG cable): loads into volatile configuration RAM — lost on power cycle. Fast for iteration.
- **QSPI Flash**: on-board flash stores the bitstream; FPGA loads it at power-up. Persistent.

Configuration time: 10–500 ms depending on device size and interface speed.

---

## 4. FPGA vs CPU vs GPU vs ASIC

| Dimension | CPU | GPU | FPGA | ASIC |
|-----------|-----|-----|------|------|
| Flexibility | Highest | High | High | None (fixed forever) |
| Peak throughput | Low–Med | Very high (batched) | Med–High | Highest |
| Latency | ms | ms (batched) | us (deterministic) | us |
| Power efficiency | Low | Med | High | Very high |
| Development time | Hours | Hours–Days | Weeks–Months | Years |
| NRE cost | None | None | None | $1M–$100M+ |
| Custom bit width | No | No (FP16/INT8) | Yes (1-bit to 64-bit) | Yes |
| Real-time guarantee | No | No | Yes | Yes |

**When FPGAs win for vision:**
- Real-time pixel-synchronous processing (no OS jitter)
- Custom precision arithmetic (e.g., 10-bit pixels, 12-bit weights)
- Low-power edge deployment (Jetson uses a lot of power by comparison)
- Research/prototyping (re-program vs tape-out for ASIC)
- Interfacing with exotic sensors (custom timing, custom protocols)

**When FPGAs lose:**
- Complex, irregular algorithms (hard to pipeline)
- When a GPU with OpenCV/CUDA already meets latency requirements
- When you need IEEE 754 double precision floating point everywhere
- Very high-volume production (ASIC is cheaper per unit at scale)

---

## 5. FPGA Families You Will Encounter

### Xilinx (now AMD-Xilinx)
| Family | Target | Key vision boards |
|--------|--------|------------------|
| Artix-7 | Low cost, low power | Nexys A7, Basys 3, Arty A7 |
| Kintex-7 | Mid-range performance | KC705 |
| Zynq-7000 | SoC (ARM + FPGA) | ZedBoard, PYNQ-Z1/Z2, Cora Z7 |
| UltraScale+ | High performance | ZCU104, Alveo |
| Zynq UltraScale+ MPSoC | High-end SoC | ZCU102, KV260 |

### Intel (Altera)
| Family | Target | Key vision boards |
|--------|--------|------------------|
| Cyclone IV/V | Low cost | DE0-Nano, DE10-Lite |
| Arria 10 | Mid-range | Arria 10 GX dev kit |
| Stratix 10 | High performance | Stratix 10 dev kit |
| Intel SoC FPGA | ARM + FPGA | DE10-Nano (Cyclone V SoC) |

### Lattice
Small, low-power FPGAs. Good for glue logic and simple interfaces. Limited DSP resources for heavy vision.

### Microchip (Microsemi)
Radiation-hardened and mixed-signal FPGAs. Less common in academic vision projects.

---

## 6. The SoC FPGA — Best of Both Worlds

For vision projects, **SoC FPGAs** (like Xilinx Zynq) are the most practical choice. They combine:

```
┌──────────────────────────────────────────────────────┐
│                    Zynq Chip                          │
│                                                      │
│  ┌──────────────────┐    ┌────────────────────────┐  │
│  │  Processing System│    │  Programmable Logic    │  │
│  │  (PS)             │    │  (PL)                  │  │
│  │                   │    │                        │  │
│  │  ARM Cortex-A9    │◄──►│  53,200 LUTs           │  │
│  │  (dual core)      │AXI │  220 DSP slices         │  │
│  │  512 MB DDR3      │    │  140 BRAMs              │  │
│  │  Linux / RTOS     │    │  Your custom circuit   │  │
│  └──────────────────┘    └────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

- **ARM core (PS)** handles: file I/O, Ethernet, USB, display output, Python/C application logic, ML model management
- **FPGA fabric (PL)** handles: pixel-level processing, real-time filtering, custom accelerators
- **AXI bus** connects them with high-bandwidth, low-latency transfers

This is why the **PYNQ-Z1/Z2** is popular for learning — Python runs on the ARM, and you interact with FPGA accelerators from Jupyter notebooks.

---

## 7. How the FPGA Counts Resources

When you open a synthesis/implementation report, you will see resource utilization like:

```
+----------------------------+-------+-------+-------+
| Resource                   |  Used | Avail |  Util |
+----------------------------+-------+-------+-------+
| LUT                        |  8420 | 53200 | 15.8% |
| LUTRAM                     |   312 | 17400 |  1.8% |
| FF                         | 12840 | 106400| 12.1% |
| BRAM 36K                   |    18 |   140 | 12.9% |
| DSP                        |    32 |   220 | 14.5% |
| IO                         |    48 |   200 | 24.0% |
+----------------------------+-------+-------+-------+
```

**Red flags** (usually mean you need a larger device or optimization):
- LUT > 70%: routing congestion, timing will suffer
- BRAM > 80%: may need to rethink data storage
- DSP > 80%: pipeline DSPs more carefully or reduce parallelism
- IO: check your pin count matches the physical board constraints

---

## 8. Key Takeaways

1. FPGAs implement circuits, not programs — the entire design exists simultaneously in hardware.
2. The fundamental unit is the **LUT** (logic) paired with a **FF** (state).
3. **DSP slices** are the bottleneck for multiply-heavy workloads (convolutions, filters).
4. **BRAM** is fast and plentiful for line buffers, but cannot hold full HD frames.
5. **SoC FPGAs** (Zynq) pair an ARM processor with FPGA fabric — ideal for vision projects.
6. Configuration is not instantaneous: compile times can be 10 minutes to 2+ hours.
7. Routing determines speed — keep logic close together and pipeline long paths.

---

**Next**: [02 — Digital Design Prerequisites](./02_DIGITAL_DESIGN_PREREQUISITES.md)
