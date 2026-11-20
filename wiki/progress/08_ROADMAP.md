# 08 — FPGA Vision Project Roadmap

> Shared roadmap for the **ALINX AXU2CGB** (Zynq UltraScale+ ZU2CG) + OV5647 MIPI camera pipeline.
> Focus: get camera data into the FPGA, verify it, then build processing on top.
> This document is status-neutral; contributors track their own progress in separate files in this folder.

---

## Phases at a Glance

```
Phase 0: Setup + Board Bring-up
Phase 1: MIPI Camera Ingestion
Phase 2: Verification (RTL + UART; ILA optional — needs JTAG cable)
Phase 3: Pixel Processing Core
Phase 4: Display / Software Integration
Phase 5: Advanced Pipeline
```

---

## Phase 0 — Setup and Board Bring-up

**Goal:** Establish a reproducible hardware and software starting point for camera development.

**Key activities:**
- Install Vivado/Vitis (2020.1 or later).
- Confirm the exact AXU2CGB board variant and FPGA part.
- Generate the camera block design from `create_mipi_bringup.tcl`.
- Confirm OV5647 communication and chip ID over I²C.
- Generate the bitstream and create a bootable `BOOT.bin`.

**Key files:**
- `vivado/create_mipi_bringup.tcl` — one-shot project generator. When sourced in Vivado's Tcl Console, it automatically:
  1. **Creates the Vivado project**: Initializes `mipi_bringup.xpr` targeting `xczu2cg-sfvc784-1-e`.
  2. **Loads constraints**: Automatically attaches `src/constraints/mipi1.xdc` (assigns the confirmed J23 pin locations and I/O standards).
  3. **Builds the Block Design (`mipi_bd`)**:
     - Configures the **Zynq UltraScale+ MPSoC** (PS): enables 100 MHz `FCLK0`, AXI `HPM0_FPD`, UART1 (`MIO 24-25`), and SD1 (`MIO 46-51`).
     - Instantiates the **Clocking Wizard**: derives 200 MHz (D-PHY reference) and 24 MHz (XCLK) from the 25 MHz board oscillator.
     - Instantiates the **MIPI CSI-2 Rx Subsystem (PG232)**: configured for 2-lane RAW8 D-PHY with pre-assigned BANK64 pin locations.
     - Adds **AXI Interconnect**, **AXI IIC** (for camera SCCB/I²C control on BANK24), and **AXI4-Stream FIFO**.
  4. **Generates wrapper & sets top**: Generates `mipi_bd_wrapper.v` so the design is ready for synthesis immediately.
- `src/constraints/mipi1.xdc` — J23 pin constraints
- `wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md` — full camera guide

**Exit criteria:**
- The design builds reproducibly from the Tcl generator.
- The FPGA part, pin assignments, and board variant are confirmed.
- The sensor chip ID can be read over I²C.
- A bitstream and boot image can be generated.

---

## Phase 1 — MIPI Camera Ingestion

**Goal:** Get OV5647 streaming MIPI data into the FPGA and confirm it reaches the PL.

**Key activities:**
- Boot the generated design from SD or load it through JTAG.
- Start the sensor stream over I²C/SCCB.
- Use UART logging to observe frame and pixel activity (ILA is optional and needs a JTAG cable, not yet available).
- Confirm the MIPI stream reaches the AXI4-Stream FIFO.

**Exit criteria:**
- `xil_printf` shows `frames > 0` every 500 ms (ILA can show equivalent frame activity once a JTAG cable is available).
- The sensor responds to the stream-on command.
- No I²C errors are reported.

---

## Phase 2 — Verification

**Goal:** Prove each layer of the pipeline works before building on top.

| Layer | What to verify | Tool |
|-------|---------------|------|
| I2C/SCCB | Sensor responds, chip ID correct | `i2cdetect`, `i2ctransfer` |
| XCLK | Sensor has clock (required for I2C) | Scope (ILA optional — needs JTAG) |
| MIPI D-PHY | Physical layer signals present | ILA on `mipi_phy_if_*` (optional — needs JTAG) or MIPI Rx status registers |
| CSI-2 decode | Frames/lines/pixels decoded correctly | `mipi_stats.v` counters |
| AXI-Stream | Data flows through FIFO to PS | UART counter output |

**Files for this phase:**
- `src/rtl/mipi_verify/mipi_stats.v` — frame/pixel/line counters
- `src/rtl/mipi_verify/line_buffer_passthrough.v` — AXI-Stream buffer
- `src/rtl/mipi_verify/ila_mipi_wrapper.v` — ILA probe wrapper (optional, needs JTAG cable)

**Exit criteria:**
- Frame counter increments at the expected rate (~30 fps).
- Pixel counter matches resolution × frame rate.
- No CRC errors or packet drops appear in MIPI Rx status registers.

---

## Phase 3 — Pixel Processing Core

**Goal:** Implement basic image processing on the incoming pixel stream.

**Recommended first modules:**
1. **Grayscale converter** — RGB→Y (simple, good for learning pipeline timing)
2. **3×3 sliding window** — foundation for convolution filters
3. **Line buffer** — use `line_buffer_passthrough.v` as a starting point

**Key concepts:**
- AXI4-Stream handshake (TVALID/TREADY/TLAST/TUSER)
- Pipeline latency vs throughput
- Fixed-point arithmetic for filters

**Exit criteria:**
- Processed image is visible on a display or readable by the PS.
- Throughput is at least 1 pixel/clock at 100 MHz.
- Timing closure is achieved (WNS ≥ 0).

---

## Phase 4 — Display / Software Integration

**Goal:** Get processed video to a screen or make it accessible to software.

**Options:**
- **HDMI/DisplayPort output** — needs additional IP (or use PetaLinux framebuffer)
- **DDR writeback** — DMA frames to PS memory, read via PetaLinux/Vitis
- **LCD via expansion header** — ALINX TFT module

**Software path:**
- PetaLinux with V4L2 driver → standard camera interface
- Or baremetal Vitis → custom register interface

**Exit criteria:**
- Live video is visible on a display OR frame data is readable from the PS.
- A frame rate of at least 15 fps is sustained.

---

## Phase 5 — Advanced Pipeline

**Goal:** Extend the verified stream with more advanced processing and acceleration.

**Candidate work:**
- Multi-stage processing (denoise → edge detect → morphology)
- Object detection (HLS-accelerated or DPU)
- Custom AXI-Stream processing modules
- Partial reconfiguration for different algorithms

---

## Quick Reference

| Topic | Doc |
|-------|-----|
| Camera bring-up | `wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md` |
| Toolchain | `wiki/fundamentals/04_TOOLCHAIN_AND_FLOW.md` |
| ALINX course | `wiki/tutorials/14_ALINX_FPGA_COURSE1.md` |
| Vitis guide | `wiki/tutorials/13_VITIS_GETTING_STARTED.md` |
| RTL verify modules | `src/rtl/mipi_verify/README.md` |

## Hardware Summary

| Component | Detail |
|-----------|--------|
| Board | ALINX AXU2CGB (Zynq UltraScale+ ZU2CG) |
| Camera | OV5647 (MIPI CSI-2, 2-lane, 0x36) |
| Connector | MIPI1/J23 (BANK64 D-PHY, BANK24 control) |
| UART | UART1 → MIO 24-25 (USB-UART chip) |
| SD | SD1 → MIO 46-51, CD on MIO 45 |
| Part | `xczu2cg-sfvc784-1-e` |

---

## Personal Progress Logs

- [Aina's progress](./AINA_PROGRESS.md)

*Last updated: 2026-11-18*
