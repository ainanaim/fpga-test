# Learning Path — From Zero to MIPI Camera Verification

> A personalized, minimal step-by-step plan for getting the OV5647 MIPI camera
> verified on the **AXU2CGB** board. Built from the translated ALINX tutorials
> and the `mipi_verify` modules.
>
> **Board:** AXU2CGB · **Chip:** `xczu2cg-sfvc784-1-e` · **Goal:** prove MIPI
> video data moves correctly through the PL.

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
  external DDR + DMA — that's what Layer 3 exercises.
- **SoC split:** the PL handles the pixel-synchronous data path
  (MIPI Rx IP → counters → line buffer → AXI-Stream), while the PS
  (ARM + Linux) handles the slow, irregular work: I2C/SCCB sensor config,
  DDR buffer management, UART debug, display. AXI moves data between them.
- **Real-time guarantee:** a CPU can drop frames under load; the FPGA
  pipeline either keeps up at line rate or fails visibly — which is exactly
  what the `mipi_verify` layers are built to detect.

---

## Before You Start — Hardware Checklist

- [ ] Confirm board is AXU2CGB (silkscreen or invoice).
- [x] **XCLK check:** AXU2CGB routes a dedicated PL clock output
      to Pin 12 on both MIPI connectors (J23 pin 12 = AG13, J24 pin 12 = AC14).
      The OV5647 clocking depends on the camera module variant:
      - **Raspberry Pi Camera V1 (OV5647)**: has an onboard 25 MHz crystal
        oscillator — typically ignores Pin 12 XCLK and uses its own crystal.
      - **Bare OV5647 module (no crystal)**: requires 24 MHz XCLK from the
        FPGA on Pin 12.
      Verify which module you have. If it has a crystal, XCLK output is
      optional; if not, the Clocking Wizard must generate 24 MHz on Pin 12.
- [ ] JTAG cable + USB-UART cable connected.
- [ ] Boot-mode switch set to JTAG (all ON) for downloads/debug.
- [ ] Vivado 2020.1 (or newer) installed on a Windows/Linux machine.
      The ALINX batch scripts are Windows-oriented; on macOS you must run
      Vivado in a VM or on a separate Windows/Linux machine.

---

## Phase 0 — Vivado Flow Basics (Course 1 Ch.4, ~half a day)

**Goal:** learn the full PL flow on a trivial example. Build the LED blink;
optionally add ILA (needs a JTAG cable, not yet available), trigger on a
counter value. This is the foundation everything else reuses.

- [ ] Read [`14_ALINX_FPGA_COURSE1.md`](../tutorials/14_ALINX_FPGA_COURSE1.md) §4
      (PL Hello World LED).
- [ ] Create the `led` project in Vivado:
      - Part = `xczu2cg-sfvc784-1-e`.
      - Target language = Verilog.
- [ ] Write `led.v` (the 25 MHz / 1-second blink from §4.3).
- [ ] Assign pins via I/O Ports → save `led.xdc` (LEDs on BANK25, LVCMOS33).
- [ ] Run Synthesis → Constraints Wizard (set `sys_clk` = 25 MHz) → save XDC.
- [ ] Generate Bitstream.
- [ ] Download via JTAG (Hardware Manager → Auto Connect → Program Device).
      Confirm the 4 PL LEDs blink once per second. (not needed yet)
- [ ] **[Optional — needs JTAG cable] Add ILA (§4.9 Method A):** insert ILA IP, 2 probes
      (PROBE0 = 32 bits for `timer_cnt`, PROBE1 = 4 bits for `led`).
      Rebuild, download, trigger on `timer_cnt == 24999999`. (not needed yet)
- [ ] **[Optional — needs JTAG cable] Add ILA (§4.9 Method B):** comment out the ILA instantiation, add
      `(* MARK_DEBUG = "true" *)` to `led` and `timer_cnt`, run Set Up Debug
      wizard, rebuild, download, trigger the same way. (not needed yet)

---

## Phase 1 — IP Instantiation (Course 1 Ch.5, ~2 hours)

**Goal:** learn how to add Xilinx IP (Clocking Wizard) to a project and
instantiate it in Verilog. The MIPI CSI-2 Rx IP is added the same way.

- [ ] Read [`14_ALINX_FPGA_COURSE1.md`](../tutorials/14_ALINX_FPGA_COURSE1.md) §5 (PLL).
- [ ] Build the `pll_test` project:
      - Clocking Wizard IP: input 25 MHz, outputs 200/100/50/25 MHz.
      - Instantiate `clk_wiz_0` in `pll_test.v` with a BUFG before the PLL
        (HDGC pin gotcha — see §5).
      - Note the PLL reset is **active-high**; invert the active-low button.
- [ ] Add `pll.xdc` (sys_clk AB11, rst_n AA13, clk_out A11).
- [ ] Generate bitstream, download, probe `clk_out` on J15 pin 3 with an
      oscilloscope.

**Why this matters:** the MIPI CSI-2 Rx IP needs multiple clocks (D-PHY ref
clock, video clock, AXI clock). You'll generate them with the same
Clocking Wizard technique.

**Skim but don't build:** §6 (RAM), §7 (ROM), §8 (FIFO). The
`line_buffer_passthrough.v` module uses the §6 RAM pattern
(`reg [W-1:0] ram [N-1:0]`). You don't need to build these yourself — just
recognize the pattern.

---

## Phase 2 — Verilog Reference (Course 1 Ch.3, as-needed)

Don't read end-to-end. Use as a lookup when a line in `mipi_verify` is
unclear. The patterns you'll hit:

| Pattern | Where in Ch.3 | Where in mipi_verify |
|---------|---------------|---------------------|
| `always @(posedge clk or negedge rst_n)` | §3.4 async-reset DFF | Every module |
| `reg [W-1:0] ram [N-1:0]` | §3.4 single-port RAM | `line_buffer_passthrough.v` |
| `case(state)` FSM | §3.5 Mealy/Moore | `line_buffer_passthrough.v` |
| `assign s_tready = 1'b1` | §3.3 combinational | All modules |
| `<=` non-blocking assignment | §3.2 operators | All clocked blocks |

If you've done any Verilog before, you can probably skip Ch.3 entirely.

---

## Phase 3 — MIPI-Specific Path (wiki/12, the real work, ~1-2 days)

This is where your actual goal lives. Phases 0-1 were just the prerequisite.

- [ ] Read [`12_OV5647_MIPI_CAMERA_PATH.md`](./12_OV5647_MIPI_CAMERA_PATH.md)
      §1-5 — MIPI CSI-2 fundamentals, D-PHY, packet structure. Conceptual.
- [ ] Read §6 — the AXU2CGB MIPI connectors (J23/MIPI1 on BANK64 for lanes,
      BANK24 for control/SCCB; J24/MIPI2 on BANK65 for reference). Confirm
      the pinout against your schematic.
- [ ] Read §7 — the Vivado MIPI CSI-2 Receiver Subsystem IP (PG232).
      Configuration: 2 lanes, RAW8 (or RAW10), D-PHY LVDS, target BANK64 (J23).
- [ ] Read §8-9 — OV5647 register bring-up + SCCB control. The I2C config
      is done from Vitis (the PS side via I2C0 EMIO, `xiicps.h`), not from PL logic. See
      [`13_VITIS_GETTING_STARTED.md`](../tutorials/13_VITIS_GETTING_STARTED.md) for the
      Vitis flow if you haven't done it yet.
- [ ] Read §10 — Vivado block design for the MIPI Rx IP. Add the IP, connect
      clocks (Clocking Wizard from 25 MHz ref clock), wire the AXI-Stream output.
- [ ] Read §14 — checklist before writing RTL. Go through every box.

---

## Phase 4 — Run the mipi_verify Layers (~1 day)

Now you're doing what [`src/rtl/mipi_verify/README.md`](../../src/rtl/mipi_verify/README.md)
describes. Each layer isolates a failure domain.

### Layer 0 — ILA only (optional, needs JTAG cable)
- [ ] Instantiate `ila_mipi_wrapper.v` on the MIPI Rx IP's AXI-Stream output.
- [ ] Generate the ILA IP in Vivado: 5 probes, widths = (DATA_W, 1, 1,
      USER_W, 1), depth = 1024.
- [ ] Build, download, run the OV5647 I2C bring-up from Vitis.
- [ ] Trigger on `tvalid` rising → link alive?
- [ ] Trigger on `tuser[0] = 1` → SOF decoded?
- [ ] Count `tlast` between two `tuser` pulses → row count matches resolution?
- [ ] Inspect `tdata` → non-zero, varying, Bayer-patterned?

### Layer 1 — Pixel/Line/Frame counter (~1 hour)
- [ ] Replace the wrapper with `mipi_stats.v`.
- [ ] [Optional — needs JTAG cable] Attach ILA to `pixel_cnt`, `line_cnt`, `frame_cnt`, `sof_seen`.
- [ ] Confirm `frame_cnt` ticks at the frame rate (~30/s for 30 fps).
- [ ] Confirm `line_cnt` resets to 0 at each SOF and reaches the row count
      (1080 for 1080p) just before the next SOF.
- [ ] Confirm `pixel_cnt` increments monotonically (no drops).
- [ ] Confirm `sof_seen` latches high on the first frame and stays high.

### Layer 2 — Line buffer passthrough (~2 hours)
- [ ] Insert `line_buffer_passthrough.v` between the MIPI Rx IP and a
      downstream sink.
- [ ] [Optional — needs JTAG cable] Put ILA on **both** the input (`s_axis_*`) and output (`m_axis_*`) sides.
- [ ] Compare: same pixel values, same row length, same frame rate?
- [ ] If yes → the PL has proven it can receive, store, and re-emit MIPI
      video. The data path works.

### Layer 3 — DMA to PS DDR + ARM dump (~half a day)
- [ ] Add AXI DMA (S2MM channel) in the block design.
- [ ] Connect DMA `S_AXI_HP0_FPD` to the PS high-performance slave port.
- [ ] In Vitis, allocate a DDR buffer, point the DMA at it, start transfer,
      wait for done.
- [ ] Dump the first 64 bytes to UART (`xil_printf` hex).
- [ ] If non-zero, varying, Bayer-patterned → the full path
      MIPI → PL → DMA → DDR → ARM is proven.
- [ ] (Optional) write the buffer to SD card as a `.bin`, view offline as
      an image.

### Layer 4 — Display (the "it works" moment, optional)
- [ ] Feed the stream to the HDMI path (Course 1 Ch.14, AN9134 module on J15)
      **or** the PS DisplayPort (Course 2 / `13_VITIS_GETTING_STARTED.md`).
- [ ] See the camera image on a monitor.

---

## What You Can Completely Skip from Course 1

| Chapter | Why skip |
|---------|----------|
| Ch.1 (UltraScale+ intro) | Skim only. The AXI table is useful reference. |
| Ch.2 (board hardware) | Skim the boot-mode table only. |
| Ch.6 (RAM) | Skim — `line_buffer_passthrough.v` uses the pattern, you don't need to build it. |
| Ch.7 (ROM) | Not needed for MIPI. |
| Ch.8 (FIFO) | Not needed for MIPI. |
| Ch.9 (keys) | Not needed. |
| Ch.10 (PWM) | Not needed. |
| Ch.11-13 (RS232/422/485) | Not needed. UART is a different interface. |
| Ch.14-16 (HDMI/LCD) | Not needed *yet*. Come back to Ch.14 if you want to display the camera image via PL HDMI. |

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

- [`14_ALINX_FPGA_COURSE1.md`](../tutorials/14_ALINX_FPGA_COURSE1.md) — translated Course 1
  (PL/FPGA side, prerequisite skills).
- [`13_VITIS_GETTING_STARTED.md`](../tutorials/13_VITIS_GETTING_STARTED.md) — translated
  Course 2 Ch.1 (Vitis/PS side, needed for I2C sensor config and DDR access).
- [`12_OV5647_MIPI_CAMERA_PATH.md`](./12_OV5647_MIPI_CAMERA_PATH.md) — the
  MIPI-specific build (Phases 3-4).
- [`src/rtl/mipi_verify/README.md`](../../src/rtl/mipi_verify/README.md) — the
  verification modules and their bring-up order.
