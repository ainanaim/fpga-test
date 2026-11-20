# Aina — Personal FPGA Vision Progress

> Personal progress log for **Aina**. The merged project plan (phases + verification layers) lives in [15 — Learning Path](../vision/15_LEARNING_PATH.md).

*Last updated: 2026-11-20*

> **Design change (2026-11-20):** `create_mipi_bringup.tcl` no longer includes the AXI IIC IP or the ILA. SCCB/I²C is now driven by the Zynq PS **I2C0 peripheral via EMIO** (`cam1_i2c` → AH13/AE13; Vitis uses `xiicps.h` / `XIicPs_*`, base `XPAR_XIICPS_0_*`). The AXI IIC diagnostics below are kept as history — the bus pins and NACK conclusions still apply, but the controller and driver API have changed, so re-verify I²C with `XIicPs` before continuing.

---

## Current Position

- **Current phase:** Phase 1 — MIPI Camera Ingestion
- **Latest verified result:** `BOOT.bin` boots from SD; the bare-metal app un-gates PS I²C0, initializes `XIicPs`, and reads the OV5647 chip ID (`0x5647`) over I²C `0x36` — confirmed in PuTTY.
- **Current blocker:** The `mipi_csi2_rx_subsystem_0` is reporting errors — the app is polling and printing the MIPI Rx **ISR** and image-info registers to diagnose.
- **Next milestone:** Interpret the ISR / image-info values, confirm MIPI frames reach the PL.

| Phase | Aina's status |
|-------|---------------|
| Phase 0 — Setup and Board Bring-up | Complete |
| Phase 1 — MIPI Camera Ingestion | In progress |
| Phase 2 — Verification | Not started |
| Phase 3 — Pixel Processing Core | Not started |
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
- [ ] Interpret the printed ISR, `0x60`, and `0x64` values (image info VC0) and map them to lane/packet state.
- [ ] Confirm the sensor is actually sending HS data on the lanes (status registers / scope if available).
- [ ] Once the stream is clean, check for `frames=N` output in PuTTY.
- [ ] Confirm the frame counter increments and no I²C or MIPI errors remain.

### Personal Completion Criteria

- [x] The OV5647 acknowledges `0x36` and returns chip ID `0x5647` in the bare-metal application.
- [ ] The sensor responds to the stream-on command (registers written; MIPI output not yet confirmed clean).
- [ ] `xil_printf` reports `frames > 0` every 500 ms.
- [ ] No I²C or MIPI Rx errors are reported.

---

## Next Phase Preview

Once Phase 1 is complete, begin Phase 2 verification in this order:

1. I²C/SCCB response and chip ID.
2. XCLK presence.
3. MIPI D-PHY activity.
4. CSI-2 frame, line, and pixel decoding.
5. AXI4-Stream data flow through the FIFO to the PS.

See the [learning path](../vision/15_LEARNING_PATH.md) for the full verification matrix and later phases.
