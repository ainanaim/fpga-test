# Aina — Personal FPGA Vision Progress

> Personal progress log for **Aina**. The merged project plan (phases + verification layers) lives in [15 — Learning Path](../vision/15_LEARNING_PATH.md).

*Last updated: 2026-11-27*

> **Design change (2026-11-20):** `create_mipi_bringup.tcl` no longer includes the AXI IIC IP or the ILA. SCCB/I²C is now driven by the Zynq PS **I2C0 peripheral via EMIO** (`cam1_i2c` → AH13/AE13; Vitis uses `xiicps.h` / `XIicPs_*`, base `XPAR_XIICPS_0_*`). The AXI IIC diagnostics below are kept as history — the bus pins and NACK conclusions still apply, but the controller and driver API have changed, so re-verify I²C with `XIicPs` before continuing.

---

## Current Position

- **Current phase:** Phase 2 — Verification (link verified over UART; capture Stage A committed, hardware build pending)
- **Latest verified result:** Exactly 30.00 fps: `WIN: csi=14400 (~30.00 fps) phy=43260/43260 bytes=800 DT=0x2B FE=1` (changelog §17, VTS=893). Zero lines lost.
- **Current blocker:** None for the link. Stage A capture needs a Vivado rebuild + firmware before pixels reach DDR.
- **Next milestone:** Build the Stage A bitstream, add the `fb=` frame count to `WIN:`, dump one raw frame over UART and confirm the image on the PC.

| Phase | Aina's status |
|-------|---------------|
| Phase 0 — Setup and Board Bring-up | Complete |
| Phase 1 — MIPI Camera Ingestion | Complete — receive path verified at 30.00 fps, RAW10, 800 B/line, zero lines lost |
| Phase 2 — Verification | In progress — UART link verification done; capture + `fb=` cross-check pending |
| Phase 3 — Pixel Processing Core | Not started — demosaic planned as capture Stage B |
| Phase 4 — Display / Software Integration | Not started |
| Phase 5 — Advanced Pipeline | Not started |

---

## Phase 0 — Completed Work

- Installed Vivado/Vitis; verified the Vitis 2026.1 standalone flow.
- Confirmed the AXU2CGB-E hardware setup and J23 (MIPI0) connections.
- Confirmed `create_mipi_bringup.tcl` generates the full block design.
- Previously confirmed the OV5647 chip ID (`0x5647`) under Linux.
- Generated the bitstream and created a working, SD-bootable `BOOT.bin`.

---

## Phase 1 — Work in Progress

### 1. `BOOT.bin` Not Booting — Resolved

**Root cause:** Vitis generated the FSBL automatically, but the boot image initially omitted `pmufw.elf`. On Zynq UltraScale+, missing PMUFW can leave power domains, PL resets, and peripheral clocks uninitialized, stopping boot before the application reaches `main()`. The boot partitions also needed the correct ordering.

**Working Vitis workflow:**
1. Create the platform from the exported Vivado `.xsa`; this generates `zynqmp_fsbl.elf` for `psu_cortexa53_0`.
2. Create a separate PMUFW application for `psu_pmu_0` using Vitis's **Zynq MP PMU Firmware** template.
3. Place PMUFW and the bare-metal camera application in the same System Project.
4. Build `BOOT.bin` with this exact partition order:

| Order | Partition | Role | Destination |
|-------|-----------|------|-------------|
| 1 | `zynqmp_fsbl.elf` | Bootloader | `a53-0` |
| 2 | `pmufw.elf` | PMU firmware / data | `pmu` |
| 3 | `mipi_bd_wrapper.bit` | PL bitstream / data | `pl` |
| 4 | `app.elf` | Bare-metal camera application / data | `a53-0` |

**Verified result:** Copying this `BOOT.bin` to the SD card's FAT32 partition and booting with the board in SD mode produces the `Zynq MP First Stage Boot Loader Release 2026.1` banner followed by the application's `xil_printf` logs in PuTTY at **115200 8N1**.

**Vitis 2026.1 note:** Standalone peripheral initialization uses a base address rather than the legacy device ID—for example, `XIic_Initialize(&IicInstance, XPAR_XIIC_0_BASEADDR)`, where the AXI IIC base address is `0xa0010000`.

### 2. I²C Resolved — Chip ID Confirmed; Now Debugging MIPI Rx ISR

**Resolved (PS I2C0 EMIO design):**
- `main.c` un-gates the PS I²C0 clocks/resets, initializes `XIicPs`, and reads the OV5647 chip ID registers (`0x300A` / `0x300B`) over I²C at `0x36` — PuTTY confirms **`0x5647`**.
- It then writes the `ov5647_720p_raw10[]` register table to configure **720p RAW10 over 2 MIPI lanes** and triggers stream-on (`0x0100 = 0x01`), before starting the `mipi_csi2_rx_subsystem_0` AXI polling loop.

**Current work — decoding MIPI Rx status:**
- The app prints the MIPI CSI-2 Rx **ISR**, register **`0x60`** (image information 1, VC0), and **`0x64`** (image information 2, VC0); currently working out what the values mean.
- **Applied — `DPY_LINE_RATE` = `250` Mbps (was `400`):** aligns the receiver's expected bit period with the OV5647's actual ~250 Mbps per-lane rate — Vivado derives the D-PHY timing parameters from this value.
- **Applied — `C_HS_SETTLE_NS` = `115` (was `175`):** the default `HS_SETTLE` window is too long at 250 Mbps, so the D-PHY receiver misses the SoT sync sequence and raises `ERR_SOT_HS` / `ERR_SOT_SYNC_HS`; `115` ns lands inside the valid settle range.

**Historical note (AXI IIC era, kept for reference):** an earlier revision used the AXI IIC IP, which NACKed `0x36` in bare-metal. The bus pins (AH13/AE13) and NACK conclusions below are historical — the controller is now PS I2C0 via EMIO and I²C reads succeed.

**Hardware checks completed (still valid):**
### 3. Camera Streaming Verified — Valid CSI-2 Packets on PuTTY (2026-11-24)

The bare-metal application now reports live CSI-2 receive statistics over UART:

```text
WIN: csi=14338 (~29.87 fps) phy=43074/43074 bytes=800 DT=0x2B
```

| Field | Value | Meaning |
|-------|-------|---------|
| `csi` | 14338 (~29.87 fps) | CSI-2 frame count / rate in the reporting window; matches the 30 fps VGA mode |
| `phy` | 43074/43074 | The two PHY counts are equal, so no mismatch is reported |
| `bytes` | 800 | 640 pixels × 10 bits / 8 = 800 bytes per line, as expected for 640-wide RAW10 |
| `DT` | `0x2B` | CSI-2 data type for RAW10 |

**Conclusion:** The sensor is configured and streaming, D-PHY lanes are locked, and the receiver decodes RAW10 640-wide lines at about 30 fps. This meets the Phase 1 criteria of frames arriving and no persistent errors.

The earlier I²C NACK investigation below is kept as history. The report above doesn't record what resolved it, so add the final enable/reset sequence here once confirmed.

### 4. Capture Stage A Committed — Raw Frames to DDR (2026-11-27)

Link bring-up closed at exactly **30.00 fps** (changelog §17: VTS=893, `csi=14400`,
`phy=43260/43260`). The capture path is now version-controlled instead of GUI-only
(the earlier unsaved demosaic+frmbuf experiment was lost — this replaces it):

- **fpga-test commit `a1ba533`:** `src/rtl/pipeline/raw10_to_raw8.v` plus a self-checking
  testbench (Icarus Verilog **PASS**: 2000 beats / 8000 pixels under random
  back-pressure), and `create_mipi_bringup.tcl` Stage A:
  CSI → `raw10_to_raw8` → AXIS FIFO (4096) → `v_frmbuf_wr` (Y8, 640×480, stride 640 B)
  → `axi_interconnect_1` → `S_AXI_HP0_FPD` (128-bit) → DDR.
  frmbuf CTRL @ `0xA0010000`; frame-done IRQ → `xlconcat` → `pl_ps_irq0`.
  The old `tready=1` drain constant is gone.
- **Pixel-layout correction:** CSI `video_out` delivers **per-pixel zero-padded 10-bit
  fields** (same convention as the PG286 demosaic input), *not* the MIPI 4px/5B wire
  packing shown in PG232's packing table. So the 8-bit bring-up only drops 2 LSBs per
  pixel; at 10-bit the demosaic can connect directly (Stage B).
- **Status:** Tcl committed, **hardware build pending**. The on-board build is still the
  drained link design until rebuilt.
- **Caution — rate values:** the committed Tcl still sets `DPY_LINE_RATE=400`; the
  `250 Mbps / C_HS_SETTLE_NS=115` experiment in §2 above never landed in the Tcl (the
  working link runs ~240 Mbps with HS_SETTLE=176 ns written by `main.c`). Reconcile when
  rebuilding — see open item 2 in `vitis_files/mipi_app/src/PROGRESS.md`.
- **Next:** rebuild + validate clean → firmware `XVFrmbufWr` + `fb=` count in `WIN:` →
  one-frame UART dump → PC Bayer-phase check (Y8 memory = 1 byte/pixel, no unpack) →
  Stage B demosaic. Diagram: `vitis_files/mipi_app/src/capture_plan.svg`.

### 2. Earlier UART Results — Camera Connection Investigation (historical)

**Hardware and Vivado checks completed:**
- Camera ribbon is connected to **J23 (MIPI0)**; all relevant I/O pins are locked in the implemented design.
- `cam1_gpio[0]` → **AH14**, currently driven to a constant `1`.
- `cam1_clk` → **AG13**, driven at **24 MHz**.
- SCCB/I²C: SCL → **AH13**, SDA → **AE13**, both with pull-ups.
- MIPI D-PHY signals use **BANK64** at **1.2 V**.
- Clocking Wizard outputs **200 MHz** for D-PHY and **24 MHz** for XCLK; I²C is now the PS I2C0 peripheral via EMIO (100 kHz, 7-bit addressing).

**UART diagnostics (superseded):** the AXI IIC-era tests (`XIic_DynInit`, `XIic_Send`, wire-level ISR) all NACKed `0x36` — that path is replaced by PS I2C0 EMIO + `XIicPs`, which now reads the chip ID successfully.

### Next Steps

- [x] Read the OV5647 chip ID over bare-metal I²C — `0x5647` confirmed via `XIicPs`.
- [x] Start streaming — `ov5647_720p_raw10[]` table written, stream-on triggered.
- [x] Apply the `DPY_LINE_RATE=250` / `C_HS_SETTLE_NS=115` fix, rebuild, and re-check the ISR for `ERR_SOT_*` clearance.
- [x] Start streaming and see frame statistics in PuTTY (~29.87 fps, RAW10, 800 B/line).
- [x] Record the working sensor enable/reset sequence and register setup — documented in `main_c_changelog.md` §0/§3 (Linux VGA table + `0x3036=0x3C`, `0x4837=0x40`, VTS=893).
- [x] Confirm the chip-ID read (`0x5647`) over bare-metal I²C and that no I²C errors remain.
- [ ] Source the updated Tcl in Vivado; `validate_bd_design` shows zero critical warnings.
- [ ] Build bitstream + `.xsa`, update the Vitis platform, SD `BOOT.bin`.
- [ ] Firmware: frmbuf driver + buffers + done IRQ; `WIN:` gains `fb=`; require `fb == csi/480`.
- [ ] UART-dump one frame; view on PC (Y8, no unpack); pick the Bayer phase from the four OpenCV codes.
- [ ] Stage B: insert demosaic (8-bit) or go 10-bit direct; frmbuf → RGB8.
- [ ] (optional, superseded) `mipi_stats` + AXI GPIO transport check — the frmbuf `fb=` count covers this once Stage A runs.
- [ ] [MIPI to miniDP plan](../vision/16_MIPI_TO_MINIDP_DESIGN_PLAN.md) — later phase, after capture + processing.

### Personal Completion Criteria

- [x] The sensor responds to stream-on and the MIPI output has clean geometry (`bytes=800`, `DT=0x2B`).
- [x] `xil_printf` reports frames arriving at 30.00 fps (`csi=14400`).
- [x] The OV5647 chip ID `0x5647` is read in the bare-metal application.
- [ ] `ERR=0` — residual correctable `SoT PendWr` remains (thin timing margin, open item).
- [ ] Frames land in DDR (`fb == csi/480`) — Stage A hardware build pending.

---

## Next Phase Preview

Phase 1 is complete; Phase 2 verification continues in this order (items 1–4 already
done over UART):

1. I²C/SCCB response and chip ID.
2. XCLK presence.
3. MIPI D-PHY activity.
4. CSI-2 frame, line, and pixel decoding.
5. AXI4-Stream data flow through the FIFO to the PS.
6. Frame capture to DDR (frmbuf) and the `fb=` cross-check against `csi/480`.

See the [learning path](../vision/15_LEARNING_PATH.md) for the full verification matrix and later phases.
