# 07 — Hardware Selection

> Two boards have been selected for this project. This document is a focused reference for both — specs, differences, camera/display compatibility, and which board to use at which stage.

---

## Table of Contents
1. [The Two Boards at a Glance](#1-the-two-boards-at-a-glance)
2. [Board A — Arty Z7-20 (Zynq-7020)](#2-board-a--arty-z7-20-zynq-7020)
3. [Board B — AXU2CGB (Zynq UltraScale+ ZU2CG)](#3-board-b--axu2cgb-zynq-ultrascale-zu2cg)
4. [Side-by-Side Comparison](#4-side-by-side-comparison)
5. [When to Use Which Board](#5-when-to-use-which-board)
6. [Camera Module Compatibility](#6-camera-module-compatibility)
7. [Display Output Options](#7-display-output-options)
8. [What to Check in the Schematics](#8-what-to-check-in-the-schematics)

---

## 1. The Two Boards at a Glance

| | **Arty Z7-20** | **AXU2CGB** |
|--|----------------|------------|
| Family | Zynq-7000 | Zynq UltraScale+ |
| Device | XC7Z020-CLG400 | XCZU2CG |
| Vendor | Digilent (Part 410-346-20) | ALINX |
| Role in project | **Learning, prototyping, algorithm development** | **Performance target, production-like pipeline** |

---

## 2. Board A — Arty Z7-20 (Zynq-7020)

### Device: XC7Z020-CLG400

**Processing System (PS):**
- Dual-core ARM Cortex-A9 @ up to 866 MHz
- 512 KB L2 cache
- Runs Linux (PetaLinux, Ubuntu)
- I2C, SPI, UART, GigE, USB, SD card — all in hard PS

**Programmable Logic (PL):**

| Resource | Count |
|----------|-------|
| LUTs (6-input) | 53,200 |
| Flip-Flops | 106,400 |
| DSP48E1 slices | 220 |
| BRAM (36 Kb blocks) | 140 (4.9 Mb total) |
| CMTs (MMCM/PLL) | 4 |
| Max I/O pins | 200 |

**Board features (Digilent Arty Z7-20):**
- **Memory**: 1 GB DDR3L (PS-side)
- **Display**: HDMI Out (TMDS, via FPGA I/O)
- **Expansion**: 4× PMOD headers, 1× Arduino shield header
- **Camera**: No dedicated CSI connector — use PMOD or Arduino header for parallel DVP camera
- **Debug**: USB-UART + USB-JTAG onboard (single micro-USB cable)
- **Power**: USB (5 V, up to 2 A) or external barrel jack
- **Vivado license**: Free (Vivado ML Standard supports XC7Z020-CLG400)
- **Price**: ~$280

**Limitations for vision:**
- Cortex-A9 is 32-bit only (older architecture vs Cortex-A53)
- No MIPI CSI-2 connector on-board — parallel DVP camera is simplest option
- DSP48E1 (25×18-bit multiply) is one generation behind DSP48E2 on UltraScale+
- 220 DSPs is enough for most classical algorithms and small CNNs, not large models

---

## 3. Board B — AXU2CGB (Zynq UltraScale+ ZU2CG)

### Device: XCZU2CG (CG subfamily — see [wiki/10](./10_ZYNQ_ULTRASCALE_REFERENCE.md))

**Processing System (PS):**
- Dual-core ARM Cortex-A53 @ up to 1.5 GHz (64-bit, ARMv8)
- Dual-core ARM Cortex-R5F @ up to 600 MHz (real-time core)
- 256 KB on-chip OCM (ECC)
- DDR4 memory controller
- Hard PCIe Gen2, USB 3.0, SATA, GigE × 4 — all in PS
- **No GPU, No VCU** (ZU2CG is a CG device — for GPU/VCU you need EG/EV)

**Programmable Logic (PL):**

| Resource | Count |
|----------|-------|
| LUTs (6-input) | 47,232 |
| Flip-Flops | 94,464 |
| DSP48E2 slices | 240 |
| BRAM (36 Kb blocks) | 150 (5.3 Mb total) |
| UltraRAM (288 Kb blocks) | 0 (not in ZU2CG) |
| Max HP I/O | 156 |
| Max HD I/O | 96 |

> **Note**: The ZU2CG has fewer LUTs and DSPs than a ZU5EG (Kria K26) or ZU7EG (ZCU104). However, it still has significantly more PS capability (Cortex-A53, Cortex-R5F, USB3, PCIe) than the Zynq-7020. Consult DS891 for the full device feature table: [`ds891-zynq-ultrascale-plus-overview.pdf`](../../resources/ds891-zynq-ultrascale-plus-overview.pdf)

**Board features (ALINX AXU2CGB):**
- **Memory**: DDR4 (verify exact capacity from ALINX documentation/schematic)
- **Display**: HDMI output
- **Camera**: MIPI CSI-2 connector(s) — verify lane count from schematic
- **Expansion**: 40-pin expansion headers (FPGA I/O)
- **Debug**: USB-JTAG, UART
- **Power**: External power supply (verify voltage/current requirement from ALINX docs)
- **Vivado license**: Check which Vivado edition covers XCZU2CG — verify on AMD licensing page
- **Price**: ~$200–300 (varies by vendor)

> **Always verify board-specific features (exact DDR size, MIPI lane count, I/O bank voltages) from the official ALINX AXU2CGB schematic and user guide before wiring any peripheral.**

---

## 4. Side-by-Side Comparison

| Feature | Arty Z7-20 | AXU2CGB |
|---------|------------|---------|
| **FPGA generation** | 7-series (28 nm) | UltraScale+ (16 nm) |
| **Application CPU** | Dual Cortex-A9 @ 866 MHz (32-bit) | Dual Cortex-A53 @ 1.5 GHz (64-bit) |
| **Real-time CPU** | None | Dual Cortex-R5F @ 600 MHz |
| **LUTs** | 53,200 | 47,232 |
| **DSP slices** | 220 × DSP48E1 (25×18-bit) | 240 × DSP48E2 (27×18-bit, pre-adder) |
| **BRAM** | 140 × 36 Kb = 4.9 Mb | 150 × 36 Kb = 5.3 Mb |
| **UltraRAM** | None | None (ZU2CG) |
| **DDR** | 1 GB DDR3L (PS-side) | DDR4 (verify capacity) |
| **USB** | USB 2.0 (via PS) | USB 3.0 (hard PS) |
| **PCIe** | None in PS | PCIe Gen2 (hard PS) |
| **MIPI CSI-2** | No dedicated connector | Yes (verify from schematic) |
| **HDMI** | HDMI Out (via PL I/O) | HDMI Out |
| **Vivado license** | Free (ML Standard) | Verify required edition |
| **PS boot** | ARM boots from SD/QSPI | ARM boots from SD/QSPI (3-stage: PMU→CSU→FSBL) |
| **Price** | ~$280 | ~$200–300 |

**Key insight**: The AXU2CGB has a newer, faster PS (Cortex-A53 + Cortex-R5F) and a newer process node, but the ZU2CG PL is not dramatically larger than the Zynq-7020. The main gains are CPU performance, USB 3.0, PCIe, and the UltraScale+ DSP48E2 (wider pre-adder, better for filter chains). The Arty Z7-20 wins on community support and free Vivado coverage.

---

## 5. When to Use Which Board

### Use the **Arty Z7-20** for:
- Learning Vivado, Verilog, AXI, ILA debugging (optional — needs JTAG cable) from scratch
- Algorithm prototyping — develop and verify your RTL pipeline here first
- Running the wiki exercises (Phases 1–3 of the roadmap)
- Any design that fits within 220 DSPs and 53K LUTs
- When you want free Vivado support and abundant community examples
- Connecting a simple parallel DVP camera (OV7670, OV2640) via PMOD

### Use the **AXU2CGB** for:
- Running the design on target hardware after prototyping on Arty Z7-20
- Designs requiring the Cortex-A53 (64-bit Linux, more CPU performance)
- Using the Cortex-R5F for a dedicated real-time control task alongside the PL pipeline
- Connecting a MIPI CSI-2 camera (if the board exposes CSI lanes — verify schematic)
- Interfacing with USB 3.0 peripherals or PCIe from the PS
- Phase 4+ of the roadmap (full camera pipeline, system integration)

### Development workflow between both boards:
```
[Arty Z7-20]                          [AXU2CGB]
Develop & simulate RTL  ──► Port & verify on target hardware
Develop AXI infrastructure ──► Adapt to UltraScale+ PS-PL ports
Prototype camera interface ──► Switch to MIPI CSI-2 path
Test Linux + DMA flow  ──► Adapt boot flow (PMU/CSU/FSBL)
```

Both devices use **Vivado** (same tool), so XDC constraints and Tcl scripts transfer with minor device-specific edits. The main porting effort is:
- Re-synthesise and re-implement for new part number
- Update XDC `PACKAGE_PIN` and `IOSTANDARD` from the new board's schematic
- Update Zynq PS block settings (clocks, DDR type, MIO pin assignments) in IP Integrator

---

## 6. Camera Module Compatibility

| Camera | Interface | Resolution | Works with Arty Z7-20 | Works with AXU2CGB |
|--------|-----------|-----------|----------------------|-------------------|
| **OV7670 module** | Parallel DVP | 0.3 MP (VGA) | Yes — via PMOD or Arduino header | Yes — via expansion header |
| **OV2640 module** | Parallel DVP | 2 MP | Yes — via PMOD | Yes — via expansion header |
| **OV5640 DVP module** | Parallel DVP | 5 MP | Yes (needs ~14 I/O pins) | Yes |
| **Raspberry Pi Camera v2 (IMX219)** | MIPI CSI-2 2-lane | 8 MP | No dedicated connector — needs adapter | Yes (if CSI connector exposed — verify) |
| **Digilent Pcam 5C (OV5640)** | MIPI CSI-2 2-lane | 5 MP | Requires PCAM connector (not on Arty Z7-20) | Possibly — verify connector compatibility |
| **USB Webcam (UVC)** | USB 2.0 | varies | Yes — USB via PS on Linux | Yes — USB 3.0 via hard PS |

**Recommended starting camera for each board:**
- **Arty Z7-20**: OV7670 or OV2640 parallel DVP module via PMOD headers — simplest wiring, no special IP needed
- **AXU2CGB**: Raspberry Pi Camera v2 (IMX219) via MIPI CSI-2 if the board exposes CSI lanes; otherwise fall back to parallel DVP via expansion header

**Important — always check before buying a MIPI camera:**
1. Confirm the AXU2CGB schematic shows MIPI CSI-2 pins connected to HP I/O banks (1.0–1.8 V capable)
2. Confirm lane count (1-lane, 2-lane, 4-lane) matches your sensor
3. Verify the FPGA I/O bank voltage matches the sensor's data interface voltage

---

## 7. Display Output Options

Both boards have HDMI output. The implementation differs by generation:

| | Arty Z7-20 | AXU2CGB |
|--|------------|---------|
| **HDMI Out** | Via PL TMDS I/O (uses LVDS I/O bank) | Via HDMI connector (verify if driven from PS DisplayPort or PL) |
| **Max resolution** | 1080p @ 60 fps is achievable | 1080p+ (verify from board docs) |
| **IP to use** | `v_axi4s_vid_out` + `rgb2dvi` IP | Same or PS DisplayPort (if wired) |
| **Clock needed** | 148.5 MHz pixel clock (MMCM inside PL) | Same |

For the AXU2CGB: check whether the HDMI connector is driven from the PL (using TMDS I/O) or from the PS's hard DisplayPort controller. If it uses the PS DisplayPort, you configure it differently (through software, not RTL).

---

## 8. What to Check in the Schematics

Before writing any RTL or buying any peripheral, verify these things in both boards' schematics:

### Both boards
- [ ] **On-board oscillator frequency** — what is the reference clock going to the PS? (Arty Z7-20: 125 MHz; AXU2CGB: verify from schematic)
- [ ] **JTAG connector** — USB-JTAG onboard? No external JTAG cable needed?
- [ ] **DDR type and size** — DDR3 (Arty) or DDR4 (AXU2CGB); exact capacity determines how many frames you can buffer
- [ ] **HDMI pin mapping** — which FPGA package pins connect to HDMI data lanes D0/D1/D2 and clock?

### Arty Z7-20 specific
- [ ] **PMOD I/O voltage** — JA/JB/JC/JD are 3.3 V; this is what parallel DVP camera data lines must match
- [ ] **HDMI I/O bank voltage** — the HDMI TMDS pins must be on a 3.3 V or LVDS-capable bank; verify in constraints
- [ ] **Arduino header pin mapping** — useful if you need more than 8 camera data bits

### AXU2CGB specific
- [ ] **MIPI CSI-2 connector pin mapping** — which FPGA HP I/O bank pins are the differential lane pairs?
- [ ] **I/O bank voltages** — HP banks (1.0–1.8 V) vs HD banks (1.2–3.3 V); camera LVDS data must land on HP banks
- [ ] **Power supply requirements** — the board likely needs more than USB power; verify required voltage and current
- [ ] **Boot mode pins** — how are the boot mode pins set by default? (SD card, QSPI, JTAG?)
- [ ] **Vivado device string** — find the exact part number (xczu2cg-...-speed grade-package) for the Vivado project

---

**Previous**: [06 — Vision on FPGAs](../vision/06_VISION_ON_FPGA.md)  
**Next**: [15 — Learning Path](../vision/15_LEARNING_PATH.md)
