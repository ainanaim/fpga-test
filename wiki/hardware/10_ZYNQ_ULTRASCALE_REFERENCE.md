# 10 — Zynq UltraScale+ Reference Summary

> Condensed reference drawn from two local documents:
> - **DS891** (v1.11.1, Mar 2025) — Product Selection Guide → [`resources/ds891-zynq-ultrascale-plus-overview.pdf`](../../resources/ds891-zynq-ultrascale-plus-overview.pdf)
> - **UG1085** (v2.5, Mar 2025) — Technical Reference Manual → [`resources/ug1085-zynq-ultrascale-trm.pdf`](../../resources/ug1085-zynq-ultrascale-trm.pdf)

---

## Table of Contents
1. [What is the Zynq UltraScale+ MPSoC?](#1-what-is-the-zynq-ultrascale-mpsoc)
2. [Device Subfamilies (CG / EG / EV)](#2-device-subfamilies-cg--eg--ev)
3. [Key Device Resource Numbers](#3-key-device-resource-numbers)
4. [Processing System (PS) Architecture](#4-processing-system-ps-architecture)
5. [Programmable Logic (PL) Resources](#5-programmable-logic-pl-resources)
6. [PS–PL AXI Interfaces](#6-pspl-axi-interfaces)
7. [Clocking Architecture](#7-clocking-architecture)
8. [DDR Memory Controller](#8-ddr-memory-controller)
9. [Boot Sequence](#9-boot-sequence)
10. [Power Domains](#10-power-domains)
11. [Quick UG1085 Chapter Map](#11-quick-ug1085-chapter-map)

---

## 1. What is the Zynq UltraScale+ MPSoC?

The Zynq UltraScale+ is AMD/Xilinx's second-generation **heterogeneous SoC** — a single chip combining:
- A hard **Processing System (PS)**: 64-bit ARM CPU(s), real-time CPU, GPU, DDR controller, USB3, PCIe, DisplayPort, GigE, all fully functional without touching the PL
- **Programmable Logic (PL)**: UltraScale FPGA fabric (LUTs, FFs, BRAM, UltraRAM, DSP slices, high-speed transceivers)

The PS and PL live in **separate power domains** and communicate through dedicated AXI interfaces. The PS always boots first; the PL is configured afterward by the PS.

**Compared to Zynq-7000 (the older family used on PYNQ-Z1):**

| Feature | Zynq-7000 (XC7Z020) | Zynq UltraScale+ (ZU5EG / Kria K26) |
|---------|--------------------|------------------------------------|
| Application CPU | Dual Cortex-A9 @ 667 MHz | Quad Cortex-A53 @ 1.5 GHz |
| Real-time CPU | None | Dual Cortex-R5F @ 600 MHz |
| GPU | None | Mali-400 MP2 |
| DDR | DDR3, 32-bit | DDR4/LPDDR4, 32 or 64-bit |
| Hard video blocks | None | H.264/H.265 VCU (EV devices) |
| DSPs | 220 | 1,248–3,528 (device-dependent) |

---

## 2. Device Subfamilies (CG / EG / EV)

The letter suffix after the device number tells you which hard blocks are present:

| Suffix | APU | GPU | VCU (H.264/H.265) | Typical use |
|--------|-----|-----|-------------------|-------------|
| **CG** | Dual-core Cortex-A53 | None | None | Cost-optimised, control-focused |
| **EG** | Quad-core Cortex-A53 | Mali-400 MP2 | None | General SoC, vision processing |
| **EV** | Quad-core Cortex-A53 | Mali-400 MP2 | Yes | Video encode/decode applications |

**For a vision project: EG or EV devices are recommended.** The EV adds hard H.264/H.265 encode/decode at up to 4K, freeing the PL for other tasks.

---

## 3. Key Device Resource Numbers

Devices most relevant to a vision project (from DS891 Tables 1 and 3):

| Device | LUTs | DSP Slices | BRAM (36K) | UltraRAM | Max HP I/O | Used on |
|--------|------|------------|------------|----------|-----------|---------|
| **ZU3EG** | 70,560 | 360 | 216 | 0 | 156 | Cora Z7 (EG variant) |
| **ZU4EG** | 87,840 | 728 | 128 | 48 | 156 | — |
| **ZU5EG** | 117,120 | 1,248 | 144 | 64 | 156 | **Kria K26 SOM** |
| **ZU7EG** | 230,400 | 1,728 | 312 | 96 | 416 | **ZCU104** |
| **ZU9EG** | 274,080 | 2,520 | 912 | 0 | 208 | ZCU102 |
| **ZU11EG** | 298,560 | 2,928 | 600 | 112 | 416 | — |

**HP I/O** = High-Performance I/O (1.0–1.8 V, supports LVDS, MIPI)  
**HD I/O** = High-Density I/O (1.2–3.3 V, general GPIO)

---

## 4. Processing System (PS) Architecture

### Application Processing Unit (APU)
- **Quad-core (EG/EV) or Dual-core (CG) Arm Cortex-A53**
- Up to **1.5 GHz**, ARMv8-A 64-bit architecture
- 32 KB L1 I-cache + 32 KB L1 D-cache per core (ECC)
- **1 MB shared L2 cache** (ECC), 16-way set-associative
- NEON SIMD + single/double-precision FPU per core
- TrustZone, virtualisation support
- Runs Linux, Android, or bare-metal

### Real-Time Processing Unit (RPU)
- **Dual-core Arm Cortex-R5F**, up to **600 MHz**, ARMv7-R 32-bit
- Can run in **lock-step mode** (single logical core with error detection) or split mode (two independent cores)
- 128 KB **Tightly Coupled Memory (TCM)** per core (256 KB combined in lock-step)
- Dedicated for hard real-time tasks (motor control, sensor fusion, safety watchdog)
- Useful in a vision system to handle camera I2C configuration, interrupt handling, or safety tasks without touching Linux

### GPU (EG/EV devices only)
- **Arm Mali-400 MP2** at up to 667 MHz
- OpenGL ES 1.1 / 2.0, OpenVG 1.1
- Pixel fill rate: 2 Mpixels/sec/MHz → ~1.3 Gpixels/sec total
- Up to 4K texture input and render output

### On-Chip Memory (OCM)
- **256 KB** on-chip RAM in the low-power domain (LPD)
- ECC protected
- Accessible by both APU and RPU
- Used heavily during boot (FSBL loaded here) and for fast inter-processor shared memory

### PS Peripherals (all hard IP, no PL resources needed)
- **DDR4/DDR3/LPDDR4** memory controller (see Section 8)
- **4× GigE** (10/100/1000 Mbps) with IEEE 1588 timestamping
- **2× USB 3.0/2.0** (SuperSpeed 5 Gbps)
- **PCIe Gen2** (x1/x2/x4)
- **SATA 3.1** (1.5/3.0/6.0 Gbps, up to 2 channels)
- **DisplayPort 1.2a** output (up to 4K×2K @ 30 Hz)
- **8-channel DMA**: two controllers (FPD-DMA and LPD-DMA), 8 channels each
- **I2C × 2, SPI × 2, UART × 2, CAN × 2, SD/eMMC × 2**
- **MIO (Multiplexed I/O)**: up to 78 physical PS I/O pins for PS peripherals
- **EMIO**: extends PS peripheral signals out through the PL to package pins (up to 96 bits)

---

## 5. Programmable Logic (PL) Resources

The PL uses the **UltraScale architecture** (same generation as Kintex/Virtex UltraScale, one generation newer than the 7-series used on PYNQ-Z1).

### CLB (Configurable Logic Block)
- **LUT6**: 6-input look-up table, can also be used as 64-bit distributed RAM or 32-bit shift register
- **Flip-flops**: 2 FFs per LUT (independent clock enable, synchronous/asynchronous reset)
- **Carry chain**: fast ripple-carry for adders, comparators

### BRAM (Block RAM)
- **36 Kb dual-port** (or two 18 Kb), true dual-port, up to 72 bits wide
- Configurable as simple dual-port, true dual-port, or FIFO
- ECC support in some configurations
- Independent read/write clocks per port

### UltraRAM (not present in Zynq-7000)
- **288 Kb per block**, 72 bits wide, dual-port
- ECC support
- Designed for large memories (frame buffers, weight tables) — fewer blocks than BRAM but much larger each
- Not all UltraScale+ devices have UltraRAM (see table in Section 3)

### DSP48E2 Slice
- **27 × 18-bit signed multiply** → 45-bit product
- **48-bit accumulator/adder**
- **27-bit pre-adder** (A ± D before multiply) — useful for symmetric filter kernels
- Cascadable for wide arithmetic and FIR filter chains
- Much more capable than the DSP48E1 in Zynq-7000 (which was 25×18)

### High-Speed Transceivers (GTH/GTY in PL)
- GTH: up to **12.5 Gbps** per lane (available in mid-range devices)
- GTY: up to **32.75 Gbps** per lane (available in larger EG/EV devices)
- Used for HDMI, DisplayPort, 10GbE, PCIe (from PL), custom high-speed links

### PL Hard Blocks (device-dependent)
- **PCIe Gen3** endpoint/root complex (up to 5 blocks in select devices)
- **100G Ethernet MAC/PCS** with RS-FEC
- **150G Interlaken**
- **VCU (EV devices)**: hard H.264 and H.265 encoder/decoder, accessible from PS or PL

---

## 6. PS–PL AXI Interfaces

This is the most important thing to understand for PL development. All PS↔PL data moves through these named AXI ports.

### Complete Interface Table (from UG1085 Table 35-1)

| Interface | Short name | Width | Direction | Coherency | Description |
|-----------|-----------|-------|-----------|-----------|-------------|
| `S_AXI_HP0_FPD` | HP0 | 32/64/128 | PL → PS | I/O coherent | High-perf, PL accesses DDR via PS |
| `S_AXI_HP1_FPD` | HP1 | 32/64/128 | PL → PS | I/O coherent | Same as HP0 |
| `S_AXI_HP2_FPD` | HP2 | 32/64/128 | PL → PS | I/O coherent | Same |
| `S_AXI_HP3_FPD` | HP3 | 32/64/128 | PL → PS | I/O coherent | Same |
| `S_AXI_HPC0_FPD` | HPC0 | 128 | PL → PS | I/O coherent (CCI) | HP + passes through cache-coherent interconnect |
| `S_AXI_HPC1_FPD` | HPC1 | 128 | PL → PS | I/O coherent (CCI) | Same as HPC0 |
| `S_AXI_ACP_FPD` | ACP | 128 | PL → PS | I/O coherent + L2 alloc | Allocates into A53 L2 cache — use for shared data with CPU |
| `S_AXI_ACE_FPD` | ACE | 128 | PL → PS | Full two-way coherent | Strongest coherency; PL and CPU share cache lines |
| `S_AXI_LPD` | LPD | 32/64/128 | PL → PS | Non-coherent | PL → RPU path; works even when FPD is powered down |
| `M_AXI_HPM0_FPD` | HPM0 | 32/64/128 | PS → PL | — | PS master reads/writes PL-side registers/BRAM |
| `M_AXI_HPM1_FPD` | HPM1 | 32/64/128 | PS → PL | — | Second PS master into PL |
| `M_AXI_HPM0_LPD` | LPD_PL | 32/64/128 | PS LPD → PL | — | Low-latency path from RPU/LPD into PL |

### Practical mapping for a vision pipeline

```
Camera pixels (PL pipeline)
    │
    ▼  processed frame
[AXI DMA in PL] ──► S_AXI_HP0_FPD ──► DDR (PS memory)
                                            │
                              ARM CPU reads results from DDR
                              or shares via ACP (cached access)

ARM CPU (PS) controls your accelerator:
M_AXI_HPM0_FPD ──► AXI-Lite slave in PL ──► weight/config registers
```

**Rules of thumb:**
- **HP{0:3}**: use for bulk pixel/frame DMA (PL writes frames to DDR, CPU reads them)
- **HPC{0,1}**: use when PL and CPU both access the same memory frequently (better cache coherency)
- **ACP**: use for small shared buffers where you want CPU cache to stay coherent with PL output
- **HPM{0,1}**: use for CPU-driven register writes into your PL accelerator (AXI-Lite control)
- **LPD**: use for RPU↔PL paths independent of the main FPD power state

---

## 7. Clocking Architecture

### PS PLLs (5 total)
The PS has five independent PLLs, each fed by a reference oscillator:

| PLL | Name | Primary use |
|-----|------|-------------|
| APLL | Application PLL | APU (Cortex-A53) clock |
| RPLL | Real-time PLL | RPU (Cortex-R5F) + LPD peripherals |
| DPLL | DDR PLL | DDR memory controller |
| IOPLL | I/O PLL | PS I/O peripherals (UART, SPI, I2C, GEM, USB) |
| VPLL | Video PLL | GPU, DisplayPort, video reference clocks |

### PS → PL Clock Delivery (FCLK)
The PS generates up to **4 fabric clocks** (FCLK0–FCLK3) for the PL, derived from any of the 5 PLLs with programmable dividers. These become the PL's main clocks:

```
PS PLL (e.g. IOPLL at 1000 MHz)
    │
    ├─ FCLK0 ÷ 10 = 100 MHz   ← your main processing clock
    ├─ FCLK1 ÷ 5  = 200 MHz   ← DDR reference or high-speed
    ├─ FCLK2 ÷ 7  = ~143 MHz  ← pixel clock approximate
    └─ FCLK3  ← available
```

FCLK frequencies are configured via PS block settings in Vivado IP Integrator (Zynq PS tab → Clock Configuration).

### PL Clocking (MMCM/PLL in PL)
For precise frequencies (e.g. exact 74.25 MHz pixel clock for 720p), use an MMCM inside the PL fed by one of the FCLK pins. MMCM provides fractional multiplication, phase shift, and deskew.

---

## 8. DDR Memory Controller

- Supports **DDR4, DDR3, DDR3L, LPDDR4, LPDDR3**
- **32-bit or 64-bit** bus width (DDR4/DDR3); 32-bit for LPDDR4
- Up to **2400 Mb/s** data rate (DDR4, -1 speed grade)
- Up to **32 GB** address space
- **ECC** support (single-bit correctable, double-bit detectable)
- **Multi-ported**: 6 AXI slave ports shared between PS subsystems and PL HP ports

### DDR Port Connections (from DS891)
```
APU + RPU + LPD ──► Port 0 (128-bit) ──►
HP0 + HP1       ──► Port 1 (128-bit) ──► DDR Memory Controller ──► LPDDR4
DisplayPort + HP2──► Port 2 (128-bit) ──►
HP3 + HP4       ──► Port 3 (128-bit) ──►
FPD DMA + HP5   ──► Port 4 (128-bit) ──►
RPU dedicated   ──► Port 5 (64-bit)  ──►
```

**Implication for vision pipelines**: heavy traffic from the PL (e.g. camera frames writing to DDR via HP0) competes with the CPU's own DDR access. Use the QoS (Quality of Service) registers in UG1085 Ch.17 to prioritise latency-sensitive paths.

---

## 9. Boot Sequence

The PS boots **completely independently of the PL**. PL configuration happens after the PS is running. (UG1085 Ch.11)

```
Power-on
    │
    ▼
[1] PMU ROM (pre-configuration stage)
    - Platform Management Unit initialises power domains
    - Voltage checks, memory zeroise, security checks
    │
    ▼
[2] CSU BootROM (configuration stage)
    - Configuration and Security Unit reads boot mode pins (SD / QSPI / JTAG)
    - Loads FSBL (First Stage Bootloader) into 256 KB OCM
    - Optionally loads PMU firmware into PMU RAM
    │
    ▼
[3] FSBL (user software, runs on APU or RPU)
    - Initialises DDR, clocks, MIO pin mux
    - Configures PL (loads bitstream via PCAP interface)  ← this is where your .bit file goes
    - Loads U-Boot or RTOS into DDR
    │
    ▼
[4] U-Boot → Linux (or bare-metal application)
    - Linux boots from DDR
    - PL is now running your FPGA design
    - ARM software can communicate with PL via AXI interfaces
```

### For development (Vivado / JTAG flow)
You do not go through the full boot sequence during development. Instead:
- Vivado Hardware Manager programs the PL directly over JTAG while Linux is already running on the PS
- For persistent deployment: build a `BOOT.BIN` using Xilinx Bootgen, containing FSBL + bitstream + U-Boot, and copy it to the SD card

---

## 10. Power Domains

The device has four independently controllable power domains (UG1085 Ch.1):

| Domain | Abbreviation | Contains | Can be powered down? |
|--------|-------------|---------|----------------------|
| Low-Power Domain | LPD | PMU, CSU, RPU, OCM, LPD-DMA, most PS I/O | No (always on when PS is on) |
| Full-Power Domain | FPD | APU (Cortex-A53), GPU, DDR, PCIe, SATA, USB3, DisplayPort, FPD-DMA | Yes — shut down to save power |
| PL Power Domain | PLPD | All PL fabric, BRAM, UltraRAM, DSPs, PL transceivers | Yes — shut down PL independently |
| Battery Power Domain | BPD | Real-time clock, BBRAM (key storage) | Runs from battery when main power off |

**Key point for vision projects**: if your FPGA pipeline is not needed (e.g. idle between capture sessions), you can power down the PLPD and save significant power. The PS (and even just the RPU in the LPD) can remain active for housekeeping.

---

## 11. Quick UG1085 Chapter Map

| Chapter | Page | Topic | When to read |
|---------|------|-------|-------------|
| Ch. 1 | 11 | Introduction, system block diagram, power domains | Start here |
| Ch. 3 | ~40 | Application Processing Unit (APU/Cortex-A53) | Setting up Linux on PS |
| Ch. 4 | 68 | Real-Time Processing Unit (RPU/Cortex-R5F) | Adding real-time control |
| Ch. 11 | 219 | Boot and Configuration | Creating BOOT.BIN, SD card boot |
| Ch. 15 | 356 | PS Interconnect | Understanding QoS, bandwidth |
| Ch. 17 | ~440 | DDR Memory Controller | DDR tuning, ECC, bandwidth |
| Ch. 18 | 513 | On-Chip Memory (OCM) | Using the 256 KB fast memory |
| Ch. 19 | 519 | DMA Controller (FPD/LPD-DMA) | PS-side DMA for data movement |
| Ch. 28 | 784 | Multiplexed I/O (MIO) | Assigning PS peripherals to pins |
| Ch. 29 | 806 | PS-GTR Transceivers | PCIe, SATA, USB3, DisplayPort lanes |
| Ch. 33 | 941 | DisplayPort Controller | HDMI-equivalent video output from PS |
| Ch. 34 | 1014 | GEM Ethernet | Gigabit Ethernet from PS |
| Ch. 35 | 1079 | PS–PL AXI Interfaces | **Most important for PL development** |
| Ch. 36 | ~1115 | PL Peripherals (VCU, RFSoC) | H.264/H.265 hard encoder/decoder |
| Ch. 37 | ~1131 | PS Clock Subsystem | Configuring FCLK, PLLs |
| Ch. 38 | 1151 | Reset System | Handling resets in PS and PL |
| Ch. 39 | 1163 | System Test and Debug (JTAG, CoreSight) | Hardware debugging |

---

**Previous**: [09 — Timing Constraints (XDC) Deep Dive](./09_TIMING_CONSTRAINTS.md)  
**Index**: [00 — Wiki Index](../00_INDEX.md)
