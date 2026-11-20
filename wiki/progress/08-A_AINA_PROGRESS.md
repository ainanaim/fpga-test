# Aina — Personal FPGA Vision Progress

> Personal progress log for **Aina**. The shared, status-neutral project plan lives in [08 — Project Roadmap](./08_ROADMAP(PROGRESS).md).

*Last updated: 2026-11-20*

> **Design change (2026-11-20):** `create_mipi_bringup.tcl` no longer includes the AXI IIC IP or the ILA. SCCB/I²C is now driven by the Zynq PS **I2C0 peripheral via EMIO** (`cam1_i2c` → AH13/AE13; Vitis uses `xiicps.h` / `XIicPs_*`, base `XPAR_XIICPS_0_*`). The AXI IIC diagnostics below are kept as history — the bus pins and NACK conclusions still apply, but the controller and driver API have changed, so re-verify I²C with `XIicPs` before continuing.

---

## Current Position

- **Current phase:** Phase 1 — MIPI Camera Ingestion
- **Latest verified result:** `BOOT.bin` boots from SD; the bare-metal app un-gates PS I²C0, initializes `XIicPs`, and reads the OV5647 chip ID (`0x5647`) over I²C `0x36` — confirmed in PuTTY.
- **Current blocker:** The `mipi_csi2_rx_subsystem_0` is reporting errors — the app is polling and printing the MIPI Rx **Interrupt Status Register (ISR)** to diagnose.
- **Next milestone:** Clear the ISR errors and confirm MIPI frames reach the PL.

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

**Current work — MIPI Rx ISR errors:**
- The app prints the MIPI CSI-2 Rx **Interrupt Status Register (ISR)** and reads error info from the ISR address to find why no clean video stream is confirmed yet.

**Historical note (AXI IIC era, kept for reference):** an earlier revision used the AXI IIC IP, which NACKed `0x36` in bare-metal. The bus pins (AH13/AE13) and NACK conclusions below are historical — the controller is now PS I2C0 via EMIO and I²C reads succeed.

**Hardware checks completed (still valid):**
- Camera ribbon is connected to **J23 (MIPI0)**; all relevant I/O pins are locked in the implemented design.
- `cam1_gpio[0]` → **AH14**, currently driven to a constant `1`.
- `cam1_clk` → **AG13**, driven at **24 MHz**.
- SCCB/I²C: SCL → **AH13**, SDA → **AE13**, both with pull-ups.
- MIPI D-PHY signals use **BANK64** at **1.2 V**.
- Clocking Wizard outputs **200 MHz** for D-PHY and **24 MHz** for XCLK; I²C is now the PS I2C0 peripheral via EMIO (100 kHz, 7-bit addressing).

**UART diagnostics and conclusions:**

| Test | Observed output | Conclusion |
|------|-----------------|------------|
| Dynamic I²C (`XIic_DynInit`) | Read from `0x36` failed: no ACK | Dynamic-mode transfer did not reach a responding sensor. |
| Standard I²C (`XIic_Send`) | `SR = 0x000000C0`; send returned `0` | SCL and SDA are both pulled high and not stuck low, but the transfer did not complete. |
| Wire-level ISR diagnostic | `ISR: 0xD0 → 0xD6`; `TX_ERROR` bit set | The AXI IIC controller, PL, and AH13/AE13 pins physically drive the bus. Address `0x36` was NACKed; this alone does **not** prove the sensor is awake. |

**Current interpretation:** The FPGA-side I²C path is functional, while the OV5647 is not acknowledging its address in the bare-metal setup. Because the sensor previously responded under Linux, the leading remaining differences to investigate are:

1. **Enable/reset polarity and sequencing:** `cam1_gpio[0]` is fixed at `1`, but the camera may require `0` or a `0 → 1` transition after XCLK stabilizes.
2. **Linux device-tree configuration:** The working Linux setup may configure camera power/reset GPIOs or clocks differently from the bare-metal design.

### Next Steps

- [x] Read the OV5647 chip ID over bare-metal I²C — `0x5647` confirmed via `XIicPs`.
- [x] Start streaming — `ov5647_720p_raw10[]` table written, stream-on triggered.
- [ ] Decode the MIPI Rx ISR error bits and fix the cause (lane state, ECC/CRC errors, packet errors, or sensor config).
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

See the [shared roadmap](./08_ROADMAP(PROGRESS).md) for the full verification matrix and later phases.
