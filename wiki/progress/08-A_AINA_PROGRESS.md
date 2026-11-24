# Aina — Personal FPGA Vision Progress

> Personal progress log for **Aina**. The shared, status-neutral project plan lives in [08 — Project Roadmap](./08_ROADMAP(PROGRESS).md).

*Last updated: 2026-11-24*

---

## Current Position

- **Current phase:** Phase 1 — MIPI Camera Ingestion (receive path working; moving to Phase 2 verification)
- **Latest verified result:** The OV5647 streams and the CSI-2 receive path decodes it. PuTTY shows `WIN: csi=14338 (~29.87 fps) phy=43074/43074 bytes=800 DT=0x2B`.
- **Current blocker:** None for camera ingestion. The earlier I²C NACK at `0x36` is no longer blocking, since the sensor is configured and streaming.
- **Next milestone:** Verify CSI→FIFO transport with `mipi_stats` (160 beats/line, 480 lines/frame), then follow the [MIPI to miniDP plan](../vision/16_MIPI_TO_MINIDP_DESIGN_PLAN.md).

| Phase | Aina's status |
|-------|---------------|
| Phase 0 — Setup and Board Bring-up | Complete |
| Phase 1 — MIPI Camera Ingestion | Receive path verified (~30 fps, RAW10, 800 B/line); transport checks pending |
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

### 2. Earlier UART Results — Camera Connection Investigation (historical)

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

- [x] Start streaming and see frame statistics in PuTTY (~29.87 fps, RAW10, 800 B/line).
- [ ] Record the working sensor enable/reset sequence and register setup.
- [ ] Confirm the chip-ID read (`0x5647`) over bare-metal I²C and that no I²C errors remain.
- [ ] Add `mipi_stats` and AXI GPIO; check 160 beats/line, 480 lines/frame, ~30 SOF/s.
- [ ] Continue with the [MIPI to miniDP plan](../vision/16_MIPI_TO_MINIDP_DESIGN_PLAN.md).

### Personal Completion Criteria

- [x] The sensor responds to the stream-on command.
- [x] `xil_printf` reports frames arriving at ~30 fps.
- [ ] The OV5647 chip ID `0x5647` is read in the bare-metal application (not recorded in the latest log).
- [ ] No I²C errors are reported (not recorded in the latest log).

---

## Next Phase Preview

Once Phase 1 is complete, begin Phase 2 verification in this order:

1. I²C/SCCB response and chip ID.
2. XCLK presence.
3. MIPI D-PHY activity.
4. CSI-2 frame, line, and pixel decoding.
5. AXI4-Stream data flow through the FIFO to the PS.

See the [shared roadmap](./08_ROADMAP(PROGRESS).md) for the full verification matrix and later phases.
