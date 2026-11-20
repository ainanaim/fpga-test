# Learning Path — OV5647 MIPI Camera on AXU2CGB

> Personalized plan for getting the OV5647 MIPI camera verified on the
> **AXU2CGB** board, then building processing on top.
>
> **Board:** AXU2CGB · **Chip:** `xczu2cg-sfvc784-1-e` · **Goal:** prove MIPI
> video data moves correctly through the PL.
>
> **Status (2026-11-20):** Vivado/Vitis **2026.1** on Windows
> (`C:/fpga/mipi_bringup`). The Block Design is generated entirely by
> `vivado/create_mipi_bringup.tcl` (self-contained — it builds `mipi_bd` and
> `mipi_bd_wrapper.v` automatically). OV5647 I²C is **solved**: PS I2C0 via
> EMIO, `XIicPs` in the bare-metal app, chip ID `0x5647` confirmed in PuTTY.
> The `ov5647_720p_raw10[]` table configures 720p RAW10 over 2 MIPI lanes and
> stream-on (`0x0100 = 0x01`) is written. `BOOT.bin` boots from SD.
> **Current work:** decoding the MIPI Rx ISR and image-info registers
> (`0x60`/`0x64` VC0) printed over UART — `DPY_LINE_RATE`=250 Mbps and
> `C_HS_SETTLE_NS`=115 ns are already applied.
> See [`../progress/08-A_AINA_PROGRESS.md`](../progress/08-A_AINA_PROGRESS.md)
> for the live log.

---

## Why FPGA? (vision context)

See [`../fundamentals/01_FPGA_FUNDAMENTALS.md`](../fundamentals/01_FPGA_FUNDAMENTALS.md)
for the generic fundamentals; this section explains why they matter for
camera work specifically.

- **Bandwidth:** raw video is enormous. 1080p60 is ~3 GB/s; even 720p30 Bayer
  data is ~27 MB/s sustained. Every pixel must be handled every frame —
  an FPGA does this deterministically in hardware with no OS jitter.
- **DSP slices:** future layers of this path (filters, edge detection,
  eventually CNN inference on `line_buffer_passthrough`-style streams) are
  multiply-accumulate heavy. The ZU2CG's DSP48E2 slices are the resource
  to plan around (see §2.4 of fundamentals).
- **BRAM vs DDR:** line buffers fit in BRAM, but a full frame does not
  (640×480 grayscale ≈ 65 BRAMs). Anything beyond a line or two needs
  external DDR + DMA — that's what the DDR-writeback phase exercises.
- **SoC split:** the PL handles the pixel-synchronous data path
  (MIPI Rx IP → counters → line buffer → AXI-Stream), while the PS
  (ARM + Linux) handles the slow, irregular work: I2C/SCCB sensor config,
  DDR buffer management, UART debug, display. AXI moves data between them.
- **Real-time guarantee:** a CPU can drop frames under load; the FPGA
  pipeline either keeps up at line rate or fails visibly — which is exactly
  what the verification layers below are built to detect.

---

## Phase 1 — MIPI Camera Bring-Up (wiki/12) — effectively done

The full procedure lives in
[`12_OV5647_MIPI_CAMERA_PATH.md`](./12_OV5647_MIPI_CAMERA_PATH.md).
Completed so far:

- [x] Tcl-generated block design: Zynq PS (UART1, SD1, I2C0→EMIO), Clocking
      Wizard (200 MHz D-PHY ref + 24 MHz XCLK from 25 MHz), MIPI CSI-2 Rx
      Subsystem (2-lane RAW10, 4 px/clk, 250 Mbps, `C_HS_SETTLE_NS`=115),
      AXI Interconnect, AXI4-Stream FIFO, proc_sys_reset.
- [x] Bitstream + bootable `BOOT.bin` on SD card.
- [x] Vitis bare-metal app (`xiicps.h`): un-gates I2C0 clocks/resets,
      `XIicPs` init, chip ID `0x5647` read, `ov5647_720p_raw10[]` table
      written, stream-on `0x0100 = 0x01`.
- [ ] MIPI stream confirmed clean — **in progress**, see Phase 2.

---

## Phase 2 — Verify the Stream (current)

The generated design has **no counters or ILA** — verification is via the
MIPI Rx status registers polled over AXI from the bare-metal app, plus UART.

### Current check — MIPI Rx status registers
- [ ] Decode the printed **ISR** value — which error/status bits are set?
- [ ] Decode **`0x60`** (image information 1, VC0) and **`0x64`** (image
      information 2, VC0) — do they report the expected frame/line geometry?
- [ ] Once ISR is clean, confirm frame/line/pixel activity — either through
      these registers or by adding optional counters (below).

### Verification layers (each isolates a failure domain)

| Layer | What to verify | Tool |
|-------|---------------|------|
| I2C/SCCB | Sensor responds, chip ID correct | `XIicPs` in Vitis — **done** |
| XCLK | Sensor has clock (required for I2C) | Scope, or infer from I2C ACK |
| MIPI D-PHY | Physical layer signals present | MIPI Rx status registers (ISR) |
| CSI-2 decode | Frames/lines/pixels decoded correctly | MIPI Rx image-info regs; `mipi_stats.v` counters (optional add) |
| AXI-Stream | Data flows through FIFO to PS | UART counter output (optional add) |

### Optional RTL extensions (manual BD adds — not in the Tcl script)

From [`src/rtl/mipi_verify/`](../../src/rtl/mipi_verify/README.md):

- [ ] **`mipi_stats.v`** — frame/pixel/line/SOF counters. Confirm
      `frame_cnt` ticks at ~30 fps, `line_cnt` resets per SOF and reaches the
      row count, `sof_seen` latches high.
- [ ] **`line_buffer_passthrough.v`** — insert between MIPI Rx and a sink;
      compare input vs output AXI-Stream (same pixels, row length, frame rate)
      to prove the PL can receive, store, and re-emit video.
- [ ] **AXI DMA (S2MM) → PS DDR** — dump the first 64 bytes to UART; non-zero,
      varying, Bayer-patterned data proves MIPI → PL → DMA → DDR → ARM.
      (Optional) write the buffer to SD as `.bin` and view offline.

---

## Phase 3 — Pixel Processing Core

**Goal:** implement basic image processing on the incoming pixel stream.

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

**Goal:** get processed video to a screen or make it accessible to software.

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

**Goal:** extend the verified stream with more advanced processing and acceleration.

**Candidate work:**
- Multi-stage processing (denoise → edge detect → morphology)
- Object detection (HLS-accelerated or DPU)
- Custom AXI-Stream processing modules
- Partial reconfiguration for different algorithms

---

## Verilog Patterns Used in `mipi_verify`

Lookup table for reading the RTL — no need to read the ALINX course end-to-end.
Full reference: [`14_ALINX_FPGA_COURSE1.md`](../tutorials/14_ALINX_FPGA_COURSE1.md) §3.

| Pattern | Course 1 § | Where in `mipi_verify` |
|---------|-----------|------------------------|
| `always @(posedge clk or negedge rst_n)` | §3.4 async-reset DFF | Every module |
| `reg [W-1:0] ram [N-1:0]` | §3.4 single-port RAM | `line_buffer_passthrough.v` |
| `case(state)` FSM | §3.5 Mealy/Moore | `line_buffer_passthrough.v` |
| `assign s_tready = 1'b1` | §3.3 combinational | All modules |
| `<=` non-blocking assignment | §3.2 operators | All clocked blocks |

---

## Key Numbers for Your Board (AXU2CGB)

| Item | Value |
|------|-------|
| Vivado part | `xczu2cg-sfvc784-1-e` |
| PS clock | 33.333 MHz |
| PL reference clock | 25 MHz (pin AB11, LVCMOS33) |
| RTC clock | 32.768 kHz |
| USB UART | PS UART1 (MIO 24-25, 115200 8N1) |
| SD card | SD1 (MIO 46-51, CD on MIO 45) |
| DDR4 | 2 GB, 64-bit, up to 2400 Mbps |
| eMMC | 8 GB |
| QSPI | 32 MB (256 Mb) |
| MIPI Rx base address | `0xA0000000` (AXI polling from Vitis) |
| MIPI line rate | 250 Mbps/lane, 2 lanes, RAW10 @ 4 px/clk |
| MIPI1 data lanes (J23, active) | BANK64 (HP, 1.2 V) — AC9/AD9, AE9/AE8, AB8/AC8 |
| MIPI2 data lanes (J24, ref) | BANK65 (HP, 1.2 V) — W8/Y8, U9/V9, U8/V8 |
| MIPI1 SCCB & control (J23) | BANK24 (3.3 V) — AH13 (SCL), AE13 (SDA), AG13 (CLK), AH14 (GPIO) |
| LEDs | 4× on BANK25, LVCMOS33, active-low (high = off) |
| Keys | 4× + reset on BANK24, active-low |
| Boot mode JTAG | all switches ON (ON,ON,ON,ON) |
| Boot mode SD | ON,OFF,ON,OFF |
| Boot mode QSPI | ON,ON,OFF,ON |
| Boot mode eMMC | ON,OFF,OFF,ON |

---

## Cross-References

- [`12_OV5647_MIPI_CAMERA_PATH.md`](./12_OV5647_MIPI_CAMERA_PATH.md) — the
  MIPI-specific build guide (Phases 1-2).
- [`14_ALINX_FPGA_COURSE1.md`](../tutorials/14_ALINX_FPGA_COURSE1.md) —
  translated Course 1 (PL/FPGA side; reference for Verilog patterns).
- [`13_VITIS_GETTING_STARTED.md`](../tutorials/13_VITIS_GETTING_STARTED.md) —
  translated Course 2 Ch.1 (Vitis/PS side).
- [`src/rtl/mipi_verify/README.md`](../../src/rtl/mipi_verify/README.md) — the
  verification modules and their bring-up order.
