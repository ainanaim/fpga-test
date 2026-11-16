# FPGA Vision Project Wiki

> A self-contained knowledge base for learning FPGA development with a focus on image and video processing.
> This wiki is structured so you can read it top-to-bottom as a curriculum, or jump to any section as a reference.

---

## Who this is for

You have some programming background (C/Python) and want to build a hardware-accelerated vision pipeline on an FPGA. You are **not** expected to have prior experience with digital design or hardware description languages.

---

## Wiki Map

Files are organized into five subfolders by topic. The index stays at the wiki root.

| # | Folder | Document | What you will learn |
|---|--------|----------|---------------------|
| 01 | `fundamentals/` | [FPGA Fundamentals](./fundamentals/01_FPGA_FUNDAMENTALS.md) | What an FPGA is physically — fabric, LUTs, flip-flops, DSP slices, BRAM, routing |
| 02 | `fundamentals/` | [Digital Design Prerequisites](./fundamentals/02_DIGITAL_DESIGN_PREREQUISITES.md) | Combinational/sequential logic, clocks, timing, setup/hold, pipelining |
| 03 | `fundamentals/` | [HDL and HLS](./fundamentals/03_HDL_AND_HLS.md) | Verilog, VHDL, SystemVerilog, and High-Level Synthesis — when to use each |
| 04 | `fundamentals/` | [Toolchain and Design Flow](./fundamentals/04_TOOLCHAIN_AND_FLOW.md) | RTL → Synthesis → Place-and-Route → Bitstream; Vivado, open-source tools |
| 05 | `fundamentals/` | [Memory and Interfaces](./fundamentals/05_MEMORY_AND_INTERFACES.md) | BRAM, registers, external DRAM, AXI4 bus, DMA, streaming (AXI4-Stream) |
| 06 | `vision/` | [Vision on FPGAs](./vision/06_VISION_ON_FPGA.md) | Image pipelines, pixel formats, video standards, key algorithms and their FPGA mapping |
| 07 | `hardware/` | [Hardware Selection Guide](./hardware/07_HARDWARE_SELECTION.md) | Choosing an FPGA board — Zynq SoC, development boards comparison |
| 08 | `planning/` | [Project Roadmap](./planning/08_ROADMAP.md) | Phased learning plan from zero to a working vision accelerator |
| 09 | `hardware/` | [Timing Constraints (XDC) Deep Dive](./hardware/09_TIMING_CONSTRAINTS.md) | STA, create_clock, CDC constraints, multi-cycle paths, reading timing reports, closure workflow |
| 10 | `hardware/` | [Zynq UltraScale+ Reference Summary](./hardware/10_ZYNQ_ULTRASCALE_REFERENCE.md) | Condensed summary of DS891 + UG1085: device subfamilies, PS/PL resources, AXI interfaces, clocking, DDR, boot sequence |
| 11 | `vision/` | [Video Processing Fundamentals (Step-by-Step)](./vision/11_VIDEO_PROCESSING_FUNDAMENTALS.md) | How pixels stream through an FPGA clock-by-clock — shift registers, line buffers, sliding windows, pipeline latency/throughput, DDR when needed |
| 12 | `vision/` | [OV5647 MIPI Camera Path on the AXU2CGB](./vision/12_OV5647_MIPI_CAMERA_PATH.md) | MIPI CSI-2 and D-PHY fundamentals, the OV5647 sensor, the AXU2CGB-E MIPI connector, Vivado MIPI CSI-2 Rx Subsystem IP, register bring-up, and ILA-based data path verification |
| 13 | `tutorials/` | [Getting Started with Vitis on the ALINX Board](./tutorials/13_VITIS_GETTING_STARTED.md) | Translated step-by-step guide from the ALINX Vitis tutorial Ch.1 — Vivado PS config, export XSA, Vitis app project, JTAG run/debug, and SD/QSPI boot-image creation |
| 14 | `tutorials/` | [ALINX FPGA Course 1 (Translated)](./tutorials/14_ALINX_FPGA_COURSE1.md) | Translated walkthrough of the entire ALINX FPGA tutorial (Course 1, 16 chapters) — ZYNQ arch, board hardware, Verilog building blocks, and PL experiments: LED, PLL, RAM, ROM, FIFO, keys, PWM, UART/RS232/RS422/RS485, HDMI, LCD |
| 15 | `planning/` | [Learning Path — Zero to MIPI Verification](./planning/15_LEARNING_PATH.md) | Personalized minimal step-by-step plan for the AXU2CGB-E: which Course 1 chapters to actually build, what to skip, and how to run the mipi_verify modules to prove the OV5647 camera data path |

### Folder structure

```
wiki/
├── 00_INDEX.md              ← you are here
├── fundamentals/            ← 01-05: FPGA, digital design, HDL, toolchain, memory
├── vision/                  ← 06, 11, 12: vision pipelines, video processing, MIPI camera
├── hardware/                ← 07, 09, 10: board selection, timing constraints, Zynq reference
├── planning/                ← 08, 15: project roadmap, MIPI learning path
└── tutorials/               ← 13, 14: translated ALINX Vitis + FPGA courses
```

---

## Mandatory Reading Order (before writing a single line of RTL)

```
01 → 02 → 03 (intro only) → 07 (choose your board) → 04 → 03 (deep dive) → 05 → 06 → 08
```

If you are in a hurry: **01, 02, and 08 are the absolute minimum.**

For the AXU2CGB-E + OV5647 MIPI goal specifically, follow
[`15_LEARNING_PATH.md`](./planning/15_LEARNING_PATH.md) instead — it tells you
which chapters to actually build and which to skip.

---

## Key Mental Models to Internalize

### 1. You are describing circuits, not writing programs
On a CPU you write instructions that execute sequentially.
On an FPGA you describe the **shape of a circuit** that exists in hardware simultaneously.
Every `always @(posedge clk)` block you write becomes a physical register in silicon.

### 2. Parallelism is the FPGA's superpower
Unlike a CPU that processes one pixel per clock on average, your FPGA design can process
many pixels in parallel — limited only by how much logic you provision.
This makes FPGAs ideal for real-time video pipelines.

### 3. Data moves through pipelines, not loops
A CPU loops over an array; an FPGA streams data through a **pipeline** of stages.
Each stage is a register boundary. Pipeline depth = latency. Pipeline width = throughput.

### 4. Everything is a trade-off in resources
Resources are finite: LUTs (logic), DSP slices (multiply-accumulate), BRAM (on-chip memory),
I/O pins, routing. Every design decision spends some and saves others.

### 5. Timing is a first-class constraint, not an afterthought
If your logic does not meet timing, the FPGA does not compute the right answer — it just computes
the wrong one silently. Timing closure is a skill in itself.

---

## Glossary of Essential Terms

| Term | Definition |
|------|-----------|
| **LUT** | Look-Up Table — basic logic cell; implements any N-input Boolean function |
| **FF / Flip-Flop** | 1-bit register; holds state across clock edges |
| **DSP slice** | Hardened multiply-accumulate block (e.g. 18×18 or 27×18 multiplier + adder) |
| **BRAM** | Block RAM — on-chip dual-port SRAM tile (typically 18 Kb or 36 Kb per block) |
| **CLB** | Configurable Logic Block — groups LUTs + FFs + carry chains |
| **Bitstream** | Binary file programmed into the FPGA that defines its circuit |
| **RTL** | Register-Transfer Level — abstraction describing data flow between registers |
| **Synthesis** | Converting RTL (HDL) into a netlist of FPGA primitives |
| **Place & Route** | Mapping netlist elements to physical FPGA sites and wiring them together |
| **Timing closure** | Satisfying all setup/hold constraints so logic is correct at the target frequency |
| **HLS** | High-Level Synthesis — compiling C/C++ into RTL automatically |
| **IP Core** | Pre-built, parameterizable design block (Xilinx/Intel or open-source) |
| **AXI4** | AMBA AXI4 — standard on-chip bus protocol; backbone of Xilinx Zynq ecosystem |
| **DMA** | Direct Memory Access — hardware engine that moves data without CPU involvement |
| **MIPI CSI-2** | Serial interface standard for camera sensors → FPGA |
| **SoC FPGA** | FPGA with an embedded ARM CPU (e.g. Xilinx Zynq, Intel SoC FPGA) |

---

## Project Vision Scope (undecided — image vs video)

Both are valid; the difference shapes your architecture:

| Dimension | Still Image Processing | Video Processing |
|-----------|----------------------|------------------|
| Data rate | Low (MB/s) | High (GB/s) |
| Latency requirement | Relaxed | Strict (1 frame = 16.7 ms @ 60 fps) |
| Buffering strategy | Full-frame DRAM buffer | Line-buffer (BRAM) or streaming |
| Interface | USB / Ethernet / PCIe | MIPI CSI-2 / HDMI / LVDS |
| Algorithm complexity | Batch, iterative OK | Pixel-synchronous preferred |
| FPGA size needed | Small–Medium | Medium–Large |

The wiki covers both; call-outs mark video-specific or image-specific content where relevant.

---

## Local Reference Documents

The following Xilinx manuals are saved in [`resources/`](../resources/):

| Document | File | When to read |
|----------|------|-------------|
| **DS891** — Zynq UltraScale+ MPSoC Product Selection Guide | [`ds891-zynq-ultrascale-plus-overview.pdf`](../resources/ds891-zynq-ultrascale-plus-overview.pdf) | Phase 0 / Phase 4 — when choosing a device or comparing UltraScale+ variants (LUT/DSP/BRAM counts, package options, feature table) |
| **UG1085** — Zynq UltraScale+ MPSoC Technical Reference Manual | [`ug1085-zynq-ultrascale-trm.pdf`](../resources/ug1085-zynq-ultrascale-trm.pdf) | Phase 4 onwards — the definitive reference for PS/PL architecture, AXI ports, DDR, DMA, clocking subsystem, interrupts, and boot sequence |

The following ALINX tutorial PDFs (Chinese) are saved in [`resources/tutorial(cn)/`](../resources/tutorial(cn)/):

| Document | File | Wiki translation |
|----------|------|-----------------|
| **Course 1** — ALINX ZYNQ MPSoC FPGA Tutorial V1.03 (174 pages) | [`course_s1_...FPGA教程V1.03.pdf`](../resources/tutorial(cn)/course_s1_ALINX_ZYNQ_MPSoC开发平台FPGA教程V1.03.pdf) | [`14_ALINX_FPGA_COURSE1.md`](./tutorials/14_ALINX_FPGA_COURSE1.md) |
| **Course 2** — ALINX ZYNQ MPSoC Vitis Tutorial V1.06 (388 pages) | [`course_s2_...Vitis应用教程V1.06.pdf`](../resources/tutorial(cn)/course_s2_ALINX_ZYNQ_MPSoC开发平台Vitis应用教程V1.06.pdf) | [`13_VITIS_GETTING_STARTED.md`](./tutorials/13_VITIS_GETTING_STARTED.md) |

---

*Last updated: 2026-11-16*
