# 16 — OV5647 MIPI to PS DisplayPort Design Plan

> **Status:** design and bring-up plan only. The working Vivado project is external to this repository; this document does not modify or regenerate it.
>
> **Target:** ALINX AXU2CGB (Zynq UltraScale+ ZU2CG), OV5647 on MIPI1/J23, 640×480 RAW10 at 30 fps, displayed through the PS DisplayPort controller and the board's miniDP connector.

## 1. Scope

```text
OV5647 → MIPI CSI-2 RX Subsystem → AXI4-Stream Data FIFO → AXI4-Stream Subset Converter
       → Sensor Demosaic → Video Frame Buffer Write → DDR → PS DPDMA → PS DisplayPort → miniDP
```

First display mode:

- Camera: 640×480 @ 30 fps. Display: 1920×1080 @ 60 Hz.
- Camera image is a native-size 640×480 window in a cleared 1080p framebuffer. No scaling initially.
- Frame-rate conversion is done by the DDR framebuffer, not a stream FIFO.
- Each stage has an exit condition so camera, DDR, and DisplayPort failures stay separable.

Non-goals for the first pass: scaling/aspect conversion, direct camera-to-DP live video, custom demosaic/DP RTL, Linux/V4L2 (standalone Vitis app only), changes to the working MIPI pin constraints or sensor PLL setup.

## 2. Current design and assumptions

Current data path: `mipi_csi2_rx_subsystem_0/video_out → axis_data_fifo_0/S_AXIS`, with `M_AXIS` discarded.

| Item | Value |
|---|---|
| Sensor data | RAW10 Bayer, 4 pixels/clock |
| CSI/FIFO `TDATA` | 40 bits (4 × 10-bit samples, as output by the CSI RX subsystem) |
| `TUSER` | 1 bit; bit 0 = start of frame |
| Active image | 640×480 @ 30 fps |
| Video clock | 100 MHz, unchanged initially |
| Display | PS DisplayPort via miniDP; no PL DP TX Subsystem needed |

[`create_mipi_bringup.tcl`](../../vivado/create_mipi_bringup.tcl) is a stale **RAW8/32-bit** generator. **Do not source it over the external working project.** Older generic examples in the camera guide use different widths/rates; this table governs.

### Formats through the pipeline (4 pixels/clock)

| Stage | Format | Width |
|---|---|---:|
| CSI RX / FIFO | 4 × RAW10 | 40 bits |
| Subset Converter out | 4 × RAW8 (2 LSBs dropped per sample) | 32 bits |
| Demosaic out | 4 × RGB888 | 96 bits |
| Frame Buffer Write / DPDMA | 32-bit RGBX-style memory pixels | 4 B/pixel |

Pick the memory format from those supported by **both** Video Frame Buffer Write and DPDMA; stream, DDR, and DP channel byte orders are not necessarily identical. A software-generated R/G/B test image is the cheapest way to prove the mapping.

## 3. Why DDR is required

The camera runs ~30 fps and the monitor needs 60 Hz. DPDMA can re-read the same completed frame twice; a small stream FIFO cannot hold a frame or repeat one. DDR also gives a debug point to inspect a captured frame before DP is involved.

```text
Camera write (640×480×4 B×30)    ≈ 36.9 MB/s
Display read (1920×1080×4 B×60)  ≈ 497.7 MB/s   (excludes burst/refresh overhead)

Display stride         = 1920×4 = 7,680 B
Camera bytes per row   =  640×4 = 2,560 B
Full 1080p surface     = 8,294,400 B;  three surfaces ≈ 23.7 MiB
```

Allocate complete display surfaces even though only 640×480 is written, and clear every surface before display so unused pixels are black.

## 4. Stage 0 — baseline

- [ ] Record Vivado/Vitis versions and the sensor register sequence.
- [ ] Save a copy/checkpoint of the working external project, its block design, and its XSA.
- [ ] Confirm the existing bitstream still builds.
- [ ] Edit the external `.bd`, not the repo-local generator.
- [ ] Change one failure domain at a time: ready wiring, DP test pattern, pixel conversion, DDR capture, integrated display.

**Exit:** reproducible camera-receive baseline and a restore path.

## 5. Stage 1 — AXI4-Stream ready wiring and transport check

### 5.1 Ready wiring

While `M_AXIS` is still discarded:

1. Remove the constant driving `mipi_csi2_rx_subsystem_0/video_out_tready`.
2. Connect `axis_data_fifo_0/s_axis_tready` to CSI `video_out_tready`. It is an output; never tie it high.
3. Keep `axis_data_fifo_0/m_axis_tready` tied to constant 1 (temporary discard only; never leave it floating).

When the Subset Converter is attached:

1. Connect `axis_data_fifo_0/M_AXIS` to the converter `S_AXIS`.
2. Remove the constant on `m_axis_tready`; let the consumer's `s_axis_tready` drive it (interface-level connection does this).
3. Keep ready/valid chained through Demosaic and Frame Buffer Write.

Prefer interface-level connections, then check the elaborated design for exactly one driver per ready input and no leftover constants.

> The MIPI transmitter cannot be paused. Sustained downstream backpressure can still overflow upstream; the consumer must sustain the line rate, since the FIFO only absorbs bursts.

### 5.2 No-ILA verification with `mipi_stats`

[`mipi_stats.v`](../../src/rtl/mipi_verify/mipi_stats.v) is a **passive monitor** on the CSI→FIFO interface. It observes the real `TREADY`, counts only accepted transfers (`TVALID && TREADY`), never drives ready, and needs no ILA.

1. Add `src/rtl/mipi_verify/mipi_stats.v` as a design source and instantiate it via **Add Module**.
2. Parameters: `DATA_W=40`, `USER_W=1`, `PIXELS_PER_BEAT=4`, `CW=32`.
3. Connections:

| Port | Net |
|---|---|
| `clk` | `zynq_ultra_ps_e_0/pl_clk0` |
| `rst_n` | `proc_sys_reset_0/peripheral_aresetn` |
| `s_axis_tdata[39:0]` | `mipi_csi2_rx_subsystem_0/video_out_tdata` |
| `s_axis_tvalid` / `tlast` | `video_out_tvalid` / `video_out_tlast` |
| `s_axis_tuser[0]` | `video_out_tuser` |
| `s_axis_tready` (input) | `axis_data_fifo_0/s_axis_tready` |

4. Wire counters to two dual-channel AXI GPIOs (32-bit inputs), connect their `S_AXI` to the PS control interconnect, and assign addresses:

| GPIO | Ch 1 | Ch 2 |
|---|---|---|
| 0 | `beats_last_line` | `lines_last_frame` |
| 1 | `beats_last_frame` | `frame_cnt` |

`beat_cnt`, `pixel_cnt`, `line_cnt`, `sof_seen` are optional. Use the latched `lines_last_frame` (not `line_cnt`) for the 480-line check.

5. Export the XSA, update the Vitis platform, and print the GPIO values over UART. Ignore last-frame values until at least the second SOF after reset.

| Observation | Expected |
|---|---:|
| `beats_last_line` | 160 |
| `lines_last_frame` | 480 |
| `beats_last_frame` | 76,800 |
| `frame_cnt` increase over 500 ms | ~15 |
| `beat_cnt` / `pixel_cnt` increase per frame | 76,800 / 307,200 |

A held-off transfer (`TVALID=1`, `TREADY=0`) must not change any counter. These counters verify transport structure, not pixel content.

**Exit:** stable 160-beat lines, 480-line / 76,800-beat frames, ~30 SOF/s, no counts under backpressure, no growing CSI error counters.

## 6. Stage 2 — prove miniDP with a static DDR image

### 6.1 Zynq PS configuration (verify against schematic and Vivado UI)

| Setting | Value |
|---|---|
| DisplayPort controller | Enabled |
| AUX/HPD | MIO 27–30 |
| PS-GTR lanes | **Dual Higher** (lanes 2, 3 to miniDP) |
| DP reference clock | 27 MHz on MGTREFCLK2 |
| `DP_VIDEO` clock source | VPLL |
| Initial timing | 1920×1080 @ 60 Hz |

### 6.2 Hardware and software

1. Validate, regenerate the bitstream, export a new XSA (with bitstream), and **update the Vitis platform** (rebuilding only the app is not enough).
2. Select **`dppsu`** for `psu_dp` if the BSP exposes the choice.
3. Start from the Xilinx/ALINX PS DP DPDMA example and show a known 1080p RGBA/RGBX test image from a reserved DDR surface.
4. Check link-training status and the monitor's detected timing before checking pixels.

Reference: [ALINX PS DisplayPort tutorial](https://www.cnblogs.com/alinx/p/14297999.html). Without a cable and sink, AUX transactions and link training cannot be validated.

**Exit:** monitor locks to 1080p60 and shows the test pattern with correct colors and byte order.

## 7. Stage 3 — RAW10 Bayer to RGB888

### 7.1 Subset Converter

Remap each 10-bit sample independently; do **not** truncate the 40-bit bus to its low 32 bits.

```text
out_tdata[31:0] = { in[39:32], in[29:22], in[19:12], in[9:2] }
```

- Input 5 bytes, output 4 bytes, still 4 pixels/clock.
- Preserve `TUSER[0]` and `TLAST`; pass or remove `TID`/`TDEST` consistently with the next IP.
- Use the IP's per-sample remap, not a byte-stream resizing mode. Verify the generated interface behavior.

### 7.2 Sensor Demosaic

- RAW8 in, RGB888 out, 4 pixels/clock, dimensions set for 640×480.
- Bayer phase must come from the **actual configured stream** (OV5647 default is BGGR per the camera guide, but crop, mirror, and flip change it).
- Connect its AXI4-Lite control, clock, and reset to the PS control network; program width, height, and Bayer phase in software if required.
- Use the sensor test pattern or a color chart to separate Bayer-phase errors from later DDR/DPDMA byte-order errors.

**Exit:** correct RGB timing and colors, no per-line shift or pixel-group ordering error.

## 8. Stage 4 — write RGB frames into DDR

### 8.1 Connections

```text
Demosaic → Video Frame Buffer Write → AXI SmartConnect → zynq_ultra_ps_e_0/S_AXI_HP0_FPD → DDR
```

- Enable `S_AXI_HP0_FPD`; connect HP-port and writer clocks and all resets with correct polarity.
- Connect the writer's AXI4-Lite to the PS control interconnect and assign addresses.
- Configure 4 pixels/clock, a DPDMA-compatible 32-bit format, and the 100 MHz video clock.
- AXI VDMA S2MM is an alternative; do not instantiate both.

### 8.2 Memory and cache

- Reserve framebuffer DDR outside heap, stack, and normal linker sections; take addresses and alignment from the XSA memory map.
- Clean/flush CPU-written test data before DPDMA reads it; invalidate before the CPU inspects PL-written data (or use a non-cacheable mapping). Align cache ranges as the BSP requires.
- For later Linux, use a proper reserved-memory/DMA mechanism.

### 8.3 Capture-only test

1. Clear one surface; program the writer for 640×480 and the chosen stride (compact stride for DDR-only inspection, 7,680 B for the real display surface).
2. Capture one frame, then stop or park the writer.
3. Invalidate cache; check selected pixels, row starts, and counts; optionally dump the raw frame for offline PNG conversion.
4. Verify row `y` starts at `base + y × stride`.

Use one buffer while debugging; add two or three before expecting tear-free live display.

**Exit:** a complete, stable 640×480 RGB image in DDR with correct content, component order, dimensions, and stride.

## 9. Stage 5 — display the camera framebuffer

1. Keep the verified 1080p60 DP setup; clear all display surfaces to black with cache maintenance.
2. Program the writer for 640×480 at the surface origin with a 7,680-byte stride (a non-zero window offset needs a byte offset added to the base address).
3. Point DPDMA at the same surface and format; display one captured frame continuously first.
4. Add double/triple buffering only after that works.

Multi-buffer rules: track which buffer is being written, complete, and displayed; never switch DPDMA to a partially written buffer; use writer frame-done status/interrupts; recycle a buffer only when safe. Measure camera rate with SOF counters or frame sequence numbers, not monitor refresh. A 60 Hz monitor shows each 30 fps frame twice.

**Exit:** the 640×480 window displays with correct colors and position, the rest stays black, and camera SOF rate stays near 30 fps.

## 10. Verification and debugging

| Stage | Evidence | Isolates |
|---|---|---|
| Ready wiring | Validation; no unintended ready constants | AXI structure |
| CSI/FIFO | 160 beats/line, 480 lines/frame, 30 SOF/s | Sensor, CSI decode, FIFO |
| Static DP image | Monitor locks, known colors | PS DP, GTR, DPDMA, DDR read |
| RAW10→RAW8 | Correct sample order, SOF/EOL preserved | Subset conversion |
| Demosaic | Correct colors and alignment | Bayer phase, RGB mapping |
| DDR capture | Offline-readable image, correct stride | Writer, HP port, addressing, cache |
| Single-frame display | Frame in expected window | Capture + DPDMA integration |
| Multi-buffer | No partial swaps or tearing | Buffer ownership |

At every build, also check BD validation, synthesis/implementation errors, timing closure, and XSA consistency.

| Symptom | First checks |
|---|---|
| No SOF | Sensor stream-on, virtual channel, CSI status, frame-sync packets |
| Wrong line length | RAW format, pixels/clock, active width, accepted-beat counting |
| FIFO stalls | Downstream throughput, ready chain, FIFO occupancy, writer backpressure |
| Wrong colors, correct geometry | Bayer phase, then RGB/byte order |
| Shifted or skewed image | Width, stride, base alignment, first-pixel phase |
| CPU dump stale | Cache invalidation, writer completion, physical vs virtual address |
| DP pattern works, camera surface black | Writer enable/addresses, HP errors, surface selection, cache |
| No DP link | Cable/sink, MIO 27–30, lanes 2/3, 27 MHz ref, VPLL, exported platform |
| DP colors swapped | DPDMA format and component order |
| Persistent tearing | Buffer ownership/switching (not with one actively overwritten buffer) |

Return to the last passing stage rather than changing sensor, demosaic, DDR, and DP settings together.

## 11. Later options

**Scaling:** add a Video Processing Subsystem scaler after native display is stable. 640×480 → 1920×1080 directly stretches 4:3 to 16:9; preserving aspect gives 1440×1080 with 240-pixel pillarboxes on each side.

**Direct live video (no DDR):** `Demosaic → VTC + AXI4-Stream to Video Out → PS DP live input`. It needs PS live-video enablement, timing generation, pixel-clock/component mapping, and camera/display synchronization. If the display runs at 60 Hz independent of the ~30 Hz sensor, a small FIFO cannot replace a frame buffer. Revisit only if DDR buffering proves unsuitable.

## 12. Repository files

| File | Use |
|---|---|
| [`mipi_stats.v`](../../src/rtl/mipi_verify/mipi_stats.v) | Passive no-ILA monitor (Stage 1) |
| [`ila_mipi_wrapper.v`](../../src/rtl/mipi_verify/ila_mipi_wrapper.v) | Ignore; always-ready sink, not a passive monitor |
| [`line_buffer_passthrough.v`](../../src/rtl/mipi_verify/line_buffer_passthrough.v) | Ignore; replay/backpressure unsuitable for continuous video |
| [`mac_array_3x3.v`](../../src/rtl/pipeline/mac_array_3x3.v) | Unrelated CNN helper |
| [`create_mipi_bringup.tcl`](../../vivado/create_mipi_bringup.tcl) | Stale RAW8 script; do not run over the working project |

Related: [12 — OV5647 MIPI Camera Path](./12_OV5647_MIPI_CAMERA_PATH.md), [15 — Learning Path](./15_LEARNING_PATH.md), [Vitis Getting Started](../tutorials/13_VITIS_GETTING_STARTED.md), [MIPI verification modules](../../src/rtl/mipi_verify/README.md).

## 13. Inputs needed from the external design/hardware

- Vivado/Vitis versions and available IP revisions.
- Complete OV5647 VGA30 register sequence (mirror/flip, test pattern).
- Actual CSI/FIFO sideband widths and properties.
- Demosaic Bayer-phase encoding for the installed IP.
- The exact 32-bit memory format shared by Frame Buffer Write and DPDMA.
- DDR address map and a safe framebuffer reservation.
- AXI GPIO and UART access (JTAG/ILA optional later).
- miniDP cable and compatible monitor for AUX/link-training checks.

**Next action:** apply Stage 1 to a saved copy of the external block design and run the AXI-GPIO/UART acceptance checks before adding any display IP.
