# 08 — FPGA Vision Project Roadmap

> Compressed roadmap for the **ALINX AXU2CGB** (Zynq UltraScale+ ZU2CG) + OV5647 MIPI camera pipeline.
> Focus: get camera data into the FPGA, verify it, then build processing on top.

---

## Phases at a Glance

```
Phase 0: Setup + Board Bring-up        (done)
Phase 1: MIPI Camera Ingestion          (current)
Phase 2: Verification (RTL + ILA/UART)
Phase 3: Pixel Processing Core
Phase 4: Display / Software Integration
Phase 5: Advanced Pipeline
```

---

## Phase 0 — Setup ✅

**Done:**
- Vivado/Vitis installed (2020.1+)
- AXU2CGB board confirmed (not -E variant)
- `create_mipi_bringup.tcl` generates full block design
- OV5647 chip ID confirmed via I²C (0x5647)
- Bitstream generated, BOOT.bin created

**Key files:**
- `vivado/create_mipi_bringup.tcl` — one-shot project generator
- `src/constraints/mipi1.xdc` — J23 pin constraints
- `wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md` — full camera guide

---

## Phase 1 — MIPI Camera Ingestion 🔄

**Goal:** Get OV5647 streaming MIPI data into the FPGA and confirm it reaches the PL.

**Current status:**
- Block design built (MIPI CSI-2 Rx + FIFO + ILA skeleton)
- UART logging app created (prints frame/pixel counters)
- Waiting for: JTAG cable for ILA, or SD boot + PuTTY verification

**Remaining:**
- [ ] Boot from SD card → check PuTTY for `frames=N` output
- [ ] Confirm MIPI stream active (frame counter increments)
- [ ] If silent: check UART MIO (UART1 24-25 vs UART0 42-43), XCLK, ribbon seating

**Exit criteria:**
- `xil_printf` shows `frames > 0` every 500ms
- Sensor responds to stream-on command
- No I2C errors

---

## Phase 2 — Verification

**Goal:** Prove each layer of the pipeline works before building on top.

| Layer | What to verify | Tool |
|-------|---------------|------|
| I2C/SCCB | Sensor responds, chip ID correct | `i2cdetect`, `i2ctransfer` |
| XCLK | Sensor has clock (required for I2C) | Scope or ILA |
| MIPI D-PHY | Physical layer signals present | ILA on `mipi_phy_if_*` |
| CSI-2 decode | Frames/lines/pixels decoded correctly | `mipi_stats.v` counters |
| AXI-Stream | Data flows through FIFO to PS | UART counter output |

**Files ready:**
- `src/rtl/mipi_verify/mipi_stats.v` — frame/pixel/line counters
- `src/rtl/mipi_verify/line_buffer_passthrough.v` — AXI-Stream buffer
- `src/rtl/mipi_verify/ila_mipi_wrapper.v` — ILA probe wrapper

**Exit criteria:**
- Frame counter increments at expected rate (~30 fps)
- Pixel counter matches resolution × frame rate
- No CRC errors or packet drops in MIPI Rx status registers

---

## Phase 3 — Pixel Processing Core

**Goal:** Implement basic image processing on the incoming pixel stream.

**Recommended first modules:**
1. **Grayscale converter** — RGB→Y (simple, good for learning pipeline timing)
2. **3×3 sliding window** — foundation for convolution filters
3. **Line buffer** — already have `line_buffer_passthrough.v` as starting point

**Key concepts:**
- AXI4-Stream handshake (TVALID/TREADY/TLAST/TUSER)
- Pipeline latency vs throughput
- Fixed-point arithmetic for filters

**Exit criteria:**
- Processed image visible on display or readable by PS
- Throughput ≥ 1 pixel/clock at 100 MHz
- Timing closure (WNS ≥ 0)

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
- Live video visible on display OR frame data readable from PS
- Frame rate ≥ 15 fps sustained

---

## Phase 5 — Advanced Pipeline (future)

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

*Last updated: 2026-11-17*
*Status: Phase 1 in progress — waiting for hardware verification*
