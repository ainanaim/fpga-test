# Aina — Personal FPGA Vision Progress

> Personal progress log for **Aina**. The shared, status-neutral project plan lives in [08 — Project Roadmap](./08_ROADMAP(PROGRESS).md).

*Last updated: 2026-11-20*

> **Design change (2026-11-20):** `create_mipi_bringup.tcl` no longer includes the AXI IIC IP or the ILA. SCCB/I²C is now driven by the Zynq PS **I2C0 peripheral via EMIO** (`cam1_i2c` → AH13/AE13; Vitis uses `xiicps.h` / `XIicPs_*`, base `XPAR_XIICPS_0_*`). The AXI IIC diagnostics below are kept as history — the bus pins and NACK conclusions still apply, but the controller and driver API have changed, so re-verify I²C with `XIicPs` before continuing.

---

## Current Position

- **Current phase:** Phase 1 — MIPI Camera Ingestion
- **Latest verified result:** `BOOT.bin` boots from SD and runs the bare-metal application, with FSBL and application logs visible over UART.
- **Current blocker:** The OV5647 NACKs address `0x36` from the bare-metal application. The FPGA-side I²C transmit path is proven working; sensor enable/reset sequencing is now under investigation.
- **Next milestone:** Read the OV5647 chip ID over bare-metal I²C, then confirm that frames reach the PL.

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

### 2. Latest UART Results — Camera Connection Under Investigation

**Hardware and Vivado checks completed:**
- Camera ribbon is connected to **J23 (MIPI0)**; all relevant I/O pins are locked in the implemented design.
- `cam1_gpio[0]` → **AH14**, currently driven to a constant `1`.
- `cam1_clk` → **AG13**, driven at **24 MHz**.
- SCCB/I²C: SCL → **AH13**, SDA → **AE13**, both with pull-ups.
- MIPI D-PHY signals use **BANK64** at **1.2 V**.
- Clocking Wizard outputs **200 MHz** for D-PHY and **24 MHz** for XCLK; AXI IIC is configured for **100 kHz**, 7-bit addressing, and a 100 MHz AXI clock.

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

- [ ] Inspect the working Linux DTB's `ov5647@36` node and record its clock, enable, and reset configuration.
- [ ] Make `cam1_gpio[0]` software-controllable instead of tying it to a constant.
- [ ] After allowing the 24 MHz XCLK to stabilize, test GPIO `0`, `1`, and a timed `0 → 1` transition.
- [ ] Retry the OV5647 chip-ID read at `0x36` after each sequence.
- [ ] Once I²C reads succeed, start streaming and check for `frames=N` output in PuTTY.
- [ ] Confirm the frame counter increments and no I²C errors remain.

### Personal Completion Criteria

- The OV5647 acknowledges `0x36` and returns chip ID `0x5647` in the bare-metal application.
- The sensor responds to the stream-on command.
- `xil_printf` reports `frames > 0` every 500 ms.
- No I²C errors are reported.

---

## Next Phase Preview

Once Phase 1 is complete, begin Phase 2 verification in this order:

1. I²C/SCCB response and chip ID.
2. XCLK presence.
3. MIPI D-PHY activity.
4. CSI-2 frame, line, and pixel decoding.
5. AXI4-Stream data flow through the FIFO to the PS.

See the [shared roadmap](./08_ROADMAP(PROGRESS).md) for the full verification matrix and later phases.
