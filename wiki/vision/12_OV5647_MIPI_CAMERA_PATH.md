# 12 — OV5647 MIPI Camera Path on the AXU2CGB

> The concrete data path from an OmniVision OV5647 (Raspberry Pi Camera V1 sensor) through a 15-pin MIPI CSI-2 ribbon cable into the Zynq UltraScale+ ZU2CG on the ALINX AXU2CGB-E board. This document covers MIPI CSI-2 fundamentals, the D-PHY physical layer, the Vivado MIPI CSI-2 Receiver Subsystem IP, the OV5647 register bring-up sequence, and the ILA-based bring-up workflow.
>
> **Prerequisite reading**: [06 — Vision on FPGAs](./06_VISION_ON_FPGA.md) (pixel formats, pipeline architecture), [10 — Zynq UltraScale+ Reference](../hardware/10_ZYNQ_ULTRASCALE_REFERENCE.md) (PS/PL interfaces), [11 — Video Processing Fundamentals](./11_VIDEO_PROCESSING_FUNDAMENTALS.md) §16 (DVP receiver FSM — the parallel counterpart to the MIPI path described here).

---

## Table of Contents
1. [The Hardware Path at a Glance](#1-the-hardware-path-at-a-glance)
2. [Why MIPI CSI-2 Exists — The Problem It Solves](#2-why-mipi-csi-2-exists--the-problem-it-solves)
3. [MIPI CSI-2 Fundamentals — The Protocol Layer](#3-mipi-csi-2-fundamentals--the-protocol-layer)
4. [D-PHY — The Physical Layer](#4-d-phy--the-physical-layer)
5. [How the OV5647 Uses MIPI CSI-2](#5-how-the-ov5647-uses-mipi-csi-2)
6. [The AXU2CGB-E MIPI Connector](#6-the-axu2cgb-e-mipi-connector)
7. [The Vivado MIPI CSI-2 Receiver Subsystem IP](#7-the-vivado-mipi-csi-2-receiver-subsystem-ip)
8. [OV5647 Register Bring-Up Sequence](#8-ov5647-register-bring-up-sequence)
9. [SCCB Control Channel on the AXU2CGB](#9-sccb-control-channel-on-the-axu2cgb)
10. [Vivado Block Design for Bring-Up](#10-vivado-block-design-for-bring-up)
11. [ILA-Based Data Path Verification](#11-ila-based-data-path-verification)
12. [Common Failures and Debugging](#12-common-failures-and-debugging)
13. [After Bring-Up — Demosaic and Downstream](#13-after-bring-up--demosaic-and-downstream)
14. [Checklist Before Writing Any RTL](#14-checklist-before-writing-any-rtl)

---

## 1. The Hardware Path at a Glance

```
┌─────────────┐   15-pin FPC ribbon    ┌──────────────────────────────────┐
│  OV5647     │   (CLK±, D0±, D1±,     │  AXU2CGB-E carrier board         │
│  sensor     │    SDA, SCL, PWR, EN)  │                                  │
│  (Pi V1)    │───────────────────────►│  BANK64 (HP, 1.2 V) ── MIPI Rx  │
└─────────────┘                        │  BANK24 (3.3 V)    ── SCCB ctrl  │
                                       │                                  │
                                       │  Zynq UltraScale+ ZU2CG          │
                                       │  ┌──────────────────────────┐    │
                                       │  │ MIPI CSI-2 Rx Subsystem  │    │
                                       │  │ (Vivado IP, D-PHY via     │    │
                                       │  │  SelectIO LVDS)           │    │
                                       │  └────────────┬─────────────┘    │
                                       │               │ AXI4-Stream      │
                                       │               ▼                  │
                                       │  ┌──────────────────────────┐    │
                                       │  │ Demosaic → RGB888 → ...  │    │
                                       │  └──────────────────────────┘    │
                                       └──────────────────────────────────┘
```

Three things travel over the ribbon cable:
- **MIPI data lanes** (2 differential pairs) + **MIPI clock lane** (1 differential pair) — the pixel data path
- **SCCB (I²C)** — SDA + SCL, the control/configuration path
- **Power and enable** — 3.3 V (or 1.8 V), GND, and a camera enable signal

The data path and the control path are independent and must be brought up separately: SCCB first (so you can tell the sensor to start streaming), then MIPI data (the sensor's response to those commands).

---

## 2. Why MIPI CSI-2 Exists — The Problem It Solves

A parallel camera interface (DVP) uses one wire per bit: 8 data wires, a PCLK, HREF, VSYNC — roughly 11 pins. This works at VGA resolutions and low frame rates, but it breaks down as resolution and frame rate climb:

| Resolution | Format | Pixels/s | DVP bandwidth needed | DVP pin count | Problem |
|-----------|--------|----------|---------------------|---------------|---------|
| VGA (640×480) @ 30 fps | RAW8 | 9.2 M | ~74 Mb/s | 8 data + 3 ctrl | Fine |
| 720p (1280×720) @ 60 fps | RAW10 | 55.3 M | ~553 Mb/s | 10 data + 3 ctrl | Pin count rises, signal integrity gets hard |
| 1080p (1920×1080) @ 30 fps | RAW10 | 62.2 M | ~622 Mb/s | 10 data + 3 ctrl | Parallel bus at ~60 MHz over a ribbon — marginal |
| 5 MP (2592×1944) @ 15 fps | RAW10 | 75.6 M | ~756 Mb/s | 10 data + 3 ctrl | Parallel bus cannot reliably carry this over a flat cable |

The problems with parallel at high bandwidth:
1. **Pin count** — 10+ data pins plus control, all needing matched-length PCB traces.
2. **Signal integrity** — 10 parallel single-ended signals switching simultaneously create crosstalk and ground bounce; over a flat ribbon cable above ~50 MHz the eye closes.
3. **Skew** — all 10 data bits must arrive within a small window of each other relative to PCLK; over a ribbon this is hard to guarantee as length grows.

**MIPI CSI-2 (Camera Serial Interface, version 2)** solves this by serialising the data onto a small number of **differential pairs** running at high speed:

| | DVP (parallel) | MIPI CSI-2 (serial) |
|--|----------------|---------------------|
| Wires for 1080p | 10 data + 1 clk + 2 ctrl = 13 | 2 data pairs + 1 clk pair = 6 wires (3 diff pairs) |
| Signalling | Single-ended, ~50 MHz | Differential, ~400–1500 Mbps/lane |
| Pin count | High (10+ data pins) | Low (2 lanes × 2 wires + clk × 2 = 6) |
| Cable | Short, matched-length parallel | Longer ribbon, differential pairs |
| EMI | High (many simultaneous switching) | Low (differential cancellation) |
| Complexity on FPGA | Simple receiver FSM | Needs D-PHY + packet decoder IP |

The trade-off: MIPI drastically reduces pin count and improves signal integrity, but the FPGA side now needs a **D-PHY receiver** (the physical layer) and a **CSI-2 packet decoder** (the protocol layer). On UltraScale+ this is handled by the Vivado MIPI CSI-2 Receiver Subsystem IP — you do not write this RTL yourself.

---

## 3. MIPI CSI-2 Fundamentals — The Protocol Layer

MIPI CSI-2 is a **packet-based** protocol. The sensor does not send a continuous pixel clock with parallel data the way DVP does. Instead it sends **packets** over the high-speed differential lanes, with a separate clock lane providing the bit-level timing reference.

### The lane structure

A MIPI CSI-2 camera link consists of:
- **1 clock lane** (differential pair: CLK+ / CLK-) — carries only the clock, no data
- **1 to 4 data lanes** (differential pairs: D0+ / D0-, D1+ / D1-, ...) — carry packets

The OV5647 uses **2 data lanes + 1 clock lane** = 3 differential pairs = 6 wires.

### Two operating modes on each lane

Every lane (data and clock) operates in two modes, and this is fundamental to how MIPI works:

| Mode | Voltage swing | Speed | Direction | Used for |
|------|---------------|-------|-----------|----------|
| **LP (Low-Power)** | 1.2 V single-ended (0 V or 1.2 V on each wire) | ~10 Mbps | Bidirectional | Control, lane initialisation, escape commands |
| **HS (High-Speed)** | ~200 mV differential (±100 mV around a common-mode ~200 mV) | 80–2500 Mbps | Unidirectional (sensor → FPGA) | Pixel data packets |

The lane physically changes its driver circuitry when switching between LP and HS. In LP mode both wires are driven independently against ground (large swing, slow). In HS mode the two wires are driven as a differential pair against each other (tiny swing, very fast). This is why a D-PHY receiver needs both a differential receiver (for HS) and single-ended comparators (for LP) on each lane.

### The packet structure

In HS mode, the sensor sends **packets**. Each packet has this structure:

```
┌───────────┬──────────────────┬───────────────────────┬──────────┐
│ SOT       │ Header (4 bytes) │ Payload (N bytes)     │ EOT      │
│ (start)   │ + ECC (1 byte)   │ + CRC (2 bytes)       │ (end)    │
└───────────┴──────────────────┴───────────────────────┴──────────┘
```

- **SOT (Start of Transmission)** — a synchronisation pattern (SoT sequence: `00011101`) the receiver uses to lock onto the bit stream and align byte boundaries.
- **Header (4 bytes)** — contains:
  - **Data Identifier (1 byte)** — virtual channel (VC, 2 bits) + data type (DT, 6 bits). The data type tells the receiver what format the payload is (RAW8, RAW10, YUV422, RGB888, etc.).
  - **Word Count (2 bytes)** — number of bytes in the payload.
  - **ECC (1 byte)** — error correction code over the header (corrects 1-bit errors, detects 2-bit errors).
- **Payload** — the actual pixel data. For RAW10 at 1920×1080, one frame line = 1920 pixels × 10 bits = 19200 bits = 2400 bytes.
- **CRC (2 bytes)** — checksum over the payload (detects transmission errors in the pixel data).
- **EOT (End of Transmission)** — a defined pattern signalling the end of the packet.

### Two packet types

| Packet type | Purpose | Example |
|-------------|---------|---------|
| **Short packet** | No payload. Header only (4 bytes). Carries synchronisation events. | Frame Start (FS), Frame End (FE), Line Start (LS), Line End (LE) |
| **Long packet** | Header + payload + CRC. Carries actual pixel data. | One row of RAW10 pixels |

A typical frame on the wire looks like:

```
[FS short packet]              ← Frame Start (signals new frame to receiver)
   [LS short packet]            ← Line Start (optional, some sensors send it)
   [Long packet: row 0 pixels]  ← 1920 × 10-bit RAW data + CRC
   [LE short packet]            ← Line End (optional)
   [LS short packet]
   [Long packet: row 1 pixels]
   ...
   [Long packet: row 1079 pixels]
[FE short packet]               ← Frame End
```

Whether LS/LE short packets are sent depends on the sensor configuration. The OV5647 can be configured to send or omit line sync packets (register `0x4800` bit 4).

### Virtual channels

MIPI CSI-2 supports up to 4 **virtual channels** (VC 0–3) on the same physical link. This allows a single MIPI port to carry data from multiple sources (e.g. a stereo camera pair) interleaved by VC. The OV5647 uses only VC0 — you can ignore virtual channels for a single-camera design.

### Data types relevant to the OV5647

The OV5647 outputs RAW Bayer only (no on-chip ISP). The data type field in the packet header tells the receiver how to interpret the payload:

| Data type code | Format | Bits per pixel | OV5647 supports? |
|---------------|--------|---------------|-----------------|
| 0x2A | RAW8 | 8 | Yes |
| 0x2B | RAW10 | 10 | Yes (default for high-res modes) |
| 0x2C | RAW12 | 12 | No (OV5647 is 10-bit max) |
| 0x1E | YUV422 8-bit | 16 | No (OV5647 has no ISP — cannot output YUV) |
| 0x24 | RGB888 | 24 | No |

**For the OV5647 you will configure the MIPI CSI-2 Rx IP for RAW8 or RAW10.** RAW10 is the native sensor depth and recommended for full quality; RAW8 is simpler for bring-up (smaller TDATA width).

### How the receiver reconstructs the video stream

The MIPI CSI-2 Receiver Subsystem IP does the following, in order:

1. **D-PHY** receives the differential HS/LP signals on each lane, recovers the bit clock from the clock lane, and deskews across the 2 data lanes.
2. **Lane management** detects SOT, aligns byte boundaries, and merges the 2 lanes back into a single byte stream (the sensor interleaves bytes across lanes in HS mode).
3. **Packet decoder** parses the header, checks ECC, extracts the data type and word count, and passes the payload to the output FIFO.
4. **Output formatter** packs the payload pixels into the AXI4-Stream TDATA width you configured (e.g. 8-bit RAW8 → 1 pixel/cycle on an 8-bit TDATA, or 4 pixels/cycle on a 32-bit TDATA).
5. **AXI4-Stream output** carries `TDATA` (pixels), `TVALID` (data present), `TLAST` (end of line — derived from LE or the end of a long packet), `TUSER[0]` (start of frame — derived from the FS short packet).

The output is a standard AXI4-Stream video stream identical in convention to what a DVP receiver FSM produces — see [11 — Video Processing Fundamentals](./11_VIDEO_PROCESSING_FUNDAMENTALS.md) §4. Your downstream pipeline (demosaic, colour convert, filters) does not care whether the pixels arrived via DVP or MIPI; the AXI4-Stream interface is the same.

---

## 4. D-PHY — The Physical Layer

D-PHY is the MIPI physical layer specification. You do not implement it — the Vivado IP does — but you need to understand it to configure the IP and to debug signal-integrity problems.

### The differential pair

Each lane is a **differential pair** — two wires (P and N, or + and -) that carry equal-and-opposite currents. The receiver measures the **voltage difference** between them, not the absolute voltage. This rejects common-mode noise (noise that hits both wires equally, like external interference).

```
HS mode (data being sent):
  D+  ─┐    ┌─┐    ┌─
        │    │ │    │
  D-  ─┘    └─┘    └─
        │←─→│
        ~200 mV differential swing
        (common mode ~200 mV)
```

The HS swing is tiny (~200 mV) because the differential receiver can detect small differences reliably, and small swing means fast switching and low EMI.

### HS vs LP signalling on the same wires

The same two wires carry both LP and HS, but not at the same time. The lane driver switches mode:

```
LP state:   D+ = 1.2 V, D- = 0 V   (or vice versa)   ← single-ended, slow
HS state:   D+ - D- = ±100 mV      (differential)    ← fast, low swing
```

The receiver has both:
- **HS receiver** — a differential comparator (detects ±100 mV)
- **LP receiver** — two single-ended comparators (detect 0 V vs 1.2 V on each wire)

The D-PHY state machine in the IP watches the LP levels to know when the sensor is about to enter HS mode (the sensor drives a specific LP sequence called the **SoT request** before switching to HS).

### The clock lane

The clock lane carries **only the clock** in HS mode — a continuous 50% duty-cycle differential signal at the byte rate. The receiver uses this clock to sample the data lanes. The clock lane frequency is:

```
clk_lane_freq = (pixel_rate × bits_per_pixel) / (2 × num_lanes)
```

For 1080p30 RAW10 over 2 lanes:
```
pixel_rate = 1920 × 1080 × 30 ≈ 62.2 M pixels/s
bit_rate   = 62.2 M × 10 = 622 Mb/s total
clk_lane   = 622 Mb/s / (2 × 2 lanes) = 155.5 MHz
```

Wait — the factor of 2 in the denominator is because MIPI uses **double data rate (DDR)**: data is sampled on both rising and falling edges of the clock lane. So the clock lane frequency is half the bit rate per lane:

```
bit_rate_per_lane = total_bit_rate / num_lanes = 622 / 2 = 311 Mb/s/lane
clk_lane_freq     = bit_rate_per_lane / 2 = 155.5 MHz  (DDR)
```

The OV5647's MIPI TX supports up to ~1 Gbps/lane, so 311 Mb/s/lane for 1080p30 is well within range.

### Lane deskew

When 2 data lanes are used, the sensor interleaves bytes across them: lane 0 carries even bytes, lane 1 carries odd bytes (or vice versa — the CSI-2 spec defines the mapping). The receiver must **deskew** — align the two lanes so that byte N from lane 0 and byte N+1 from lane 1 are reassembled in the correct order. The D-PHY handles this using a training sequence sent at the start of each HS burst (the SoT sequence).

### Why D-PHY on UltraScale+ uses SelectIO, not GTH transceivers

The Zynq UltraScale+ has two kinds of high-speed I/O:
- **GTH/GTY transceivers** — hardened SerDes blocks, 12.5–32.75 Gbps/lane. Used for PCIe, DisplayPort, 10GbE. Overkill and wrong protocol for MIPI D-PHY.
- **SelectIO** — the general-purpose I/O fabric (HP banks), which can be configured as LVDS differential receivers with DDR sampling. This is what MIPI D-PHY at ≤1.5 Gbps/lane uses.

The Vivado MIPI CSI-2 Rx Subsystem instantiates the D-PHY receiver using **SelectIO LVDS primitives** (`IBUFDS`, `IDDR`, `IODELAY`) in the HP I/O banks. This is why the MIPI connector must land on an **HP bank** (1.0–1.8 V capable) — HD banks (1.2–3.3 V) do not have the LVDS/DDR primitives needed.

On the AXU2CGB-E, the MIPI1 connector (J23) is on **BANK64** (HP, 1.2 V) — correct for D-PHY.

---

## 5. How the OV5647 Uses MIPI CSI-2

### OV5647 sensor specifics

| Parameter | Value |
|-----------|-------|
| Active array | 2592 × 1944 (5 MP, QSXGA) |
| Pixel size | 1.4 µm, 1/4" optical format |
| Shutter | Rolling |
| Max frame rate | 15 fps @ QSXGA, 30 fps @ 1080p, 60 fps @ 720p, 60/90 fps @ VGA |
| Output format | **RAW Bayer only** (no on-chip ISP — no YUV, no RGB, no JPEG) |
| Bayer pattern | BGGR (default, verify via register 0x4300) |
| Bit depth | 8 or 10 (RAW8 / RAW10) |
| MIPI lanes | 2 data + 1 clock |
| MIPI max lane speed | ~1 Gbps/lane |
| SCCB slave address | 0x36 (7-bit) → write 0x6C, read 0x6D |
| Input clock (XCLK) | 6–54 MHz (24 MHz typical) |
| Power | Core 1.5 V, analog 2.8 V, I/O 1.8 V |

### Critical difference from OV5640/OV3640

The OV5640 and OV3640 have **on-chip ISPs** — they can output YUV422, RGB565, or even JPEG. The OV5647 does **not**. It sends raw Bayer photosite readings only. This means your PL pipeline **must** start with a demosaic block:

```
OV5647 → MIPI Rx → RAW Bayer → [Demosaic] → RGB888 → [Color convert] → processing
```

There is no shortcut. You cannot skip demosaic with this sensor.

### What the OV5647 sends on the wire

For a 1080p30 RAW10 configuration, the OV5647 sends per frame:

```
[FS short packet]                    ← Frame Start (VC=0, DT=0x00)
  [Long packet: row 0, 2400 bytes]   ← 1920 px × 10 bits / 8 = 2400 bytes
  [Long packet: row 1, 2400 bytes]
  ...
  [Long packet: row 1079, 2400 bytes]
[FE short packet]                    ← Frame End (VC=0, DT=0x01)
```

The 2400 bytes of each row are distributed across the 2 data lanes: lane 0 carries bytes 0,2,4,... and lane 1 carries bytes 1,3,5,... (byte-level interleaving). The MIPI Rx IP reassembles them.

Between packets, the lanes return to LP state. The clock lane may keep running or may be gated (register `0x4800` bit 5 on the OV5647 controls this). For bring-up, leave the clock lane free-running (bit 5 = 0) — it simplifies the receiver.

---

## 6. The AXU2CGB-E MIPI Connectors

The board has two MIPI connectors — **J23 (MIPI1)** and **J24 (MIPI2)**. The camera is connected to **J23 (MIPI1)** for this project. Both connectors have the same pin structure; only the ZYNQ package pin numbers differ.

| Parameter | MIPI1 J23 (active) | MIPI2 J24 (reference) |
|-----------|--------------------|-----------------------|
| Differential I/O bank | **BANK64** (HP, 1.2 V) | BANK65 (HP, 1.2 V) |
| Control signal bank | **BANK24** (3.3 V) | BANK24 (3.3 V) |
| XDC file | [`src/constraints/mipi1.xdc`](../../src/constraints/mipi1.xdc) | [`src/constraints/mipi2.xdc`](../../src/constraints/mipi2.xdc) |

### Confirmed J23 pin assignment — MIPI1 (active connector)

Source: ALINX AXU2CGA/B User Manual Part 14, verified against official `mipi.xdc` cam0_* entries.

| J23 pin | Signal name | ZYNQ pin name | ZYNQ pin # | Description |
|---------|-------------|---------------|------------|-------------|
| 1 | GND | — | — | Ground |
| 2 | MIPI1_LAN0_N | IO_L2N_64 | AE8 | Data lane 0 − |
| 3 | MIPI1_LAN0_P | IO_L2P_64 | AE9 | Data lane 0 + |
| 4 | GND | — | — | Ground |
| 5 | MIPI1_LAN1_N | IO_L3N_64 | AC8 | Data lane 1 − |
| 6 | MIPI1_LAN1_P | IO_L3P_64 | AB8 | Data lane 1 + |
| 7 | GND | — | — | Ground |
| 8 | MIPI1_CLK_N | IO_L1N_64 | AD9 | D-PHY clock lane − |
| 9 | MIPI1_CLK_P | IO_L1P_64 | AC9 | D-PHY clock lane + |
| 10 | GND | — | — | Ground |
| 11 | CAM1_GPIO | IO_L2N_24 | AH14 | Camera enable / GPIO |
| 12 | CAM1_CLK | IO_L3P_24 | AG13 | **XCLK output to OV5647** (drive at 24 MHz) |
| 13 | CAM1_SCL | IO_L3N_24 | AH13 | SCCB / I2C clock |
| 14 | CAM1_SDA | IO_L4P_24 | AE13 | SCCB / I2C data |
| 15 | VCC_3V3 | — | — | 3.3 V power to camera module |

### Comparison with official ALINX mipi.xdc

Source: [`alinxalinx/AXU2CGA_AXU2CGB` → `vivado/auto_create_project/src/constraints/mipi.xdc`](https://github.com/alinxalinx/AXU2CGA_AXU2CGB/blob/master/vivado/auto_create_project/src/constraints/mipi.xdc)

| Item | Official repo | Our mipi1.xdc | Status |
|------|--------------|---------------|--------|
| GPIO pin | AH14 | AH14 | ✅ match |
| SCL pin | AH13 | AH13 | ✅ match |
| SDA pin | AE13 | AE13 | ✅ match |
| IOSTANDARD | LVCMOS33 | LVCMOS33 | ✅ match |
| `PULLUP true` on SCL/SDA/GPIO | ✅ present | ✅ added | ✅ synced |
| XCLK pin (AG13) | not in official file | ✅ present | added by us |
| Differential pair pins | not in official file | ✅ present | added by us — IP manages IOSTANDARD |
| Port naming | `cam0_gpio[0]`, `cam0_i2c_scl_io` | `cam1_gpio`, `cam1_scl` | different style — see note below |

**Why the official file has no differential pair pins:** The MIPI CSI-2 Rx Subsystem IP (PG232) auto-generates IOSTANDARD constraints for the D-PHY differential pairs itself. You only provide `PACKAGE_PIN`. Our XDC has them for completeness.

**Port naming difference:** The official uses `cam0_i2c_scl_io` / `cam0_i2c_sda_io` (the `_io` suffix and bidirectional style comes from the AXI IIC IP). Our XDC uses `cam1_scl` / `cam1_sda` for the PS EMIO I2C0 style. If you use the AXI IIC IP instead of PS EMIO, rename ports to match.

**Why PULLUP matters:** The SCCB/I2C lines are open-drain. Without a pull-up, the lines float high only via the camera module's on-board resistors (1.5 kΩ on Pi V1). The FPGA's internal weak pull-up adds an extra path to VCC and reduces the chance of a floating line if the resistors are marginal. The official ALINX file enables it on GPIO too.

### J24 pin assignment — MIPI2 (reference only)

| J24 pin | Signal name | ZYNQ pin # | Description |
|---------|-------------|------------|-------------|
| 2/3 | MIPI2_LAN0_N/P | V9 / U9 | Data lane 0 |
| 5/6 | MIPI2_LAN1_N/P | V8 / U8 | Data lane 1 |
| 8/9 | MIPI2_CLK_N/P | Y8 / W8 | D-PHY clock |
| 12 | CAM2_CLK | AC14 | XCLK |
| 13/14 | CAM2_SCL/SDA | AD14 / AC13 | SCCB |

### XCLK — confirmed present on pin 12 ✅

**Pin 12 (CAM1_CLK, AG13, IO_L3P_24, BANK24) is the XCLK line for MIPI1.**
Drive AG13 at 24 MHz from a Clocking Wizard output. The OV5647 will not respond on SCCB until XCLK is running.

In the block design, the Clocking Wizard (25 MHz PL ref → 24 MHz) output connects through an OBUF to the `cam1_clk` top-level port.

### Power considerations

The OV5647 needs three supply rails:
- **1.5 V core** — generated on the camera module (Pi V1 has an on-board regulator)
- **2.8 V analog** — generated on the camera module
- **1.8 V I/O** — the MIPI lane I/O voltage; the AXU2CGB-E provides 1.2 V on BANK64 (MIPI1), within the D-PHY common-mode range

The Pi V1 camera module takes 3.3 V from pin 15 of the ribbon (VCC_3V3) and generates 1.5 V and 2.8 V on-board.

---

## 7. The Vivado MIPI CSI-2 Receiver Subsystem IP

### What the IP is

The **MIPI CSI-2 Receiver Subsystem** (PG232) is a free Xilinx IP core that implements:
- **D-PHY receiver** — using SelectIO LVDS primitives in HP I/O banks (not GTH transceivers)
- **CSI-2 packet decoder** — SOT detection, lane deskew, header ECC, payload CRC, data type extraction
- **Video format bridge** — packs received pixels into AXI4-Stream TDATA of your chosen width
- **AXI4-Stream output** — standard video stream with TVALID/TLAST/TUSER

You configure it through the Vivado IP customisation dialog and connect it in the block design. You do not write the D-PHY or packet decoder RTL.

### Key configuration parameters

| Parameter | Value for OV5647 on AXU2CGB-E | Notes |
|-----------|------------------------------|-------|
| Number of lanes | **2** | OV5647 uses 2 data lanes |
| Data rate per lane | Set to match OV5647 output (e.g. 800 Mbps/lane for 1080p30 RAW10) | Calculated from resolution × fps × bits / lanes / 2 (DDR) |
| Pixel format | **RAW8** or **RAW10** | Must match what the OV5647 is configured to send |
| TDATA width | 8 (RAW8) or 16/32 (RAW10 packed) | Wider TDATA = more pixels/cycle, higher throughput |
| D-PHY mode | **LVDS** (SelectIO-based) | Not GTH — D-PHY at ≤1.5 Gbps uses SelectIO |
| Target I/O bank | **65** (HP, 1.2 V) | From the ALINX schematic |
| Virtual channels | 1 (VC0 only) | OV5647 uses VC0 |
| Byte clock | Derived from the MIPI clock lane | The IP generates this internally |
| AXI-Lite clock | 100 MHz (from FCLK0) | For register access to the IP's control/status |

### Clocking requirements

The IP needs several clocks:
- **AXI-Lite clock** (e.g. 100 MHz) — for the IP's register interface, connected to the PS `M_AXI_HPM0_FPD` via an AXI Interconnect.
- **Video clock** — the pixel output clock; the IP generates this from the MIPI byte clock internally, or you provide it. Check PG232 for the exact clocking diagram for your configuration.
- **D-PHY reference clock** — some configurations need a 200 MHz reference for the IODELAY/IDELAYE2 primitives. Verify from PG232.

On the AXU2CGB, derive these from the PS `FCLK0` (e.g. 100 MHz) through a PL Clocking Wizard that multiplies/divides to the required frequencies.

### I/O constraints (XDC)

The complete, confirmed constraints are in [`src/constraints/mipi1.xdc`](../../src/constraints/mipi1.xdc).
The key sections are shown below.

**Important:** do NOT set `IOSTANDARD` for the differential D-PHY pairs here.
The MIPI CSI-2 Rx Subsystem IP (PG232) auto-generates those constraints itself.
Only `PACKAGE_PIN` is needed for the differential ports. Setting `LVDS` manually
in the user XDC conflicts with the IP and causes a DRC error.

```tcl
# ── PL reference clock (25 MHz) ──────────────────────────────────────────────
set_property PACKAGE_PIN AB11 [get_ports pl_ref_clk]
set_property IOSTANDARD  LVCMOS33 [get_ports pl_ref_clk]
create_clock -period 40.000 -name pl_ref_clk -waveform {0.000 20.000} \
    [get_ports pl_ref_clk]

# ── MIPI1 J23  D-PHY differential pairs — BANK64 (HP, 1.2 V) ────────────────
# IOSTANDARD is NOT set here — the MIPI CSI-2 Rx Subsystem IP manages it.
set_property PACKAGE_PIN AC9 [get_ports mipi_phy_if_clk_p]       ;# J23 pin 9
set_property PACKAGE_PIN AD9 [get_ports mipi_phy_if_clk_n]       ;# J23 pin 8
set_property PACKAGE_PIN AE9 [get_ports {mipi_phy_if_data_p[0]}] ;# J23 pin 3
set_property PACKAGE_PIN AE8 [get_ports {mipi_phy_if_data_n[0]}] ;# J23 pin 2
set_property PACKAGE_PIN AB8 [get_ports {mipi_phy_if_data_p[1]}] ;# J23 pin 6
set_property PACKAGE_PIN AC8 [get_ports {mipi_phy_if_data_n[1]}] ;# J23 pin 5

# ── CAM1 control signals — BANK24 (3.3 V) ────────────────────────────────────
# Pin numbers confirmed from AXU2CGA/B user manual Part 14 and
# official ALINX mipi.xdc (cam0_* entries).
set_property PACKAGE_PIN AH14 [get_ports cam1_gpio]  ;# J23 pin 11
set_property PACKAGE_PIN AG13 [get_ports cam1_clk]   ;# J23 pin 12 — XCLK to OV5647
set_property PACKAGE_PIN AH13 [get_ports cam1_scl]   ;# J23 pin 13 — SCCB SCL
set_property PACKAGE_PIN AE13 [get_ports cam1_sda]   ;# J23 pin 14 — SCCB SDA
set_property IOSTANDARD LVCMOS33 [get_ports {cam1_gpio cam1_clk cam1_scl cam1_sda}]

# Pull-ups confirmed in official ALINX mipi.xdc — required for open-drain SCCB.
set_property PULLUP true [get_ports cam1_gpio]
set_property PULLUP true [get_ports cam1_scl]
set_property PULLUP true [get_ports cam1_sda]
```

### What the IP outputs

The IP's AXI4-Stream output (`m00_axis`) carries:

| Signal | Meaning |
|--------|---------|
| `m00_axis_tdata` | Pixel data. For RAW8 with 8-bit TDATA: 1 pixel/cycle. For RAW10 with 32-bit TDATA: 4 pixels/cycle (packed). |
| `m00_axis_tvalid` | 1 = a valid pixel is on the wire this cycle |
| `m00_axis_tlast` | 1 = last pixel of a row (end of line) |
| `m00_axis_tuser[0]` | 1 = first pixel of a frame (start of frame, derived from FS short packet) |
| `m00_axis_tready` | Consumer says "I can accept" — tie to 1 for bring-up, or connect to a FIFO |

This is the **same AXI4-Stream video convention** used everywhere else in this wiki (see [05 — Memory and Interfaces](../fundamentals/05_MEMORY_AND_INTERFACES.md) §5 and [11 — Video Processing Fundamentals](./11_VIDEO_PROCESSING_FUNDAMENTALS.md) §4). Your downstream pipeline does not know or care that the pixels came via MIPI rather than DVP.

---

## 8. OV5647 Register Bring-Up Sequence

The OV5647 will not emit MIPI data until you write a specific register sequence over SCCB. The sensor powers up in a low-power idle state. The sequence below is a **skeleton** — the exact PLL values depend on your XCLK frequency and target resolution. The canonical reference for the full register tables is the Linux kernel driver `drivers/media/i2c/ov5647.c` (or the Raspberry Pi fork), which has complete mode tables for 1080p30, 720p60, and VGA.

### Register access conventions

- OV5647 registers are **16-bit addressed**, **8-bit data**.
- SCCB is I²C-compatible: the PS I²C controller writes `[slave_addr_W, reg_high, reg_low, data]`.
- The 7-bit slave address is **0x36** → 8-bit write address 0x6C, read address 0x6D.

### Skeleton bring-up sequence (1080p30, RAW10, 2-lane MIPI, 24 MHz XCLK)

```
# 1. Software reset
0x3008 = 0x82      # reset sensor, wait 5 ms
0x3008 = 0x02      # power up (take out of reset)

# 2. PLL configuration (assumes 24 MHz XCLK — adjust for your XCLK)
0x3103 = 0x13      # system clock from PLL, not bypass
0x3035 = 0x21      # PLL pre-divider (verify against datasheet §3.5)
0x3036 = 0x69      # PLL multiplier
0x3037 = 0x03      # PLL root divider / system div
0x3108 = 0x01      # PLL root divider
0x3034 = 0x1a      # PLL control

# 3. MIPI configuration (2-lane)
0x300E = 0x58      # MIPI enable, 2 lanes
0x4800 = 0x04      # MIPI CTRL: HS mode, clock lane free-running
0x3016 = 0x3A      # D-PHY lane enable (lane 0 + lane 1 + clock)
0x3017 = 0x00
0x3018 = 0x00

# 4. Format: RAW10, Bayer BGGR
0x4300 = 0x00      # format select (verify bits for RAW10 + BGGR)
0x501F = 0x00      # ISP format (RAW path)

# 5. Resolution: 1920x1080 (cropped from 2592x1944)
0x3800 = 0x00      # H start high
0x3801 = 0x00      # H start low
0x3802 = 0x00      # V start high
0x3803 = 0x00      # V start low
0x3804 = 0x0A      # H end high   (2592 = 0x0A20)
0x3805 = 0x20      # H end low
0x3806 = 0x07      # V end high   (1944 = 0x0798)
0x3807 = 0x98      # V end low
0x3808 = 0x07      # H output size high (1920 = 0x0780)
0x3809 = 0x80      # H output size low
0x380A = 0x04      # V output size high (1080 = 0x0438)
0x380B = 0x38      # V output size low

# 6. Blanking (HTS, VTS — adjust for 30 fps)
0x380C = 0x0A      # HTS high (total horizontal)
0x380D = 0x20      # HTS low
0x380E = 0x07      # VTS high (total vertical)
0x380F = 0x98      # VTS low

# 7. Sub-sampling / scaling (for 1080p from 5MP, you may crop or subsample)
0x3814 = 0x00      # H offset
0x3816 = 0x00      # V offset
# (subsampling registers — see datasheet §4 if you want 720p or VGA)

# 8. Frame rate control (derived from PLL + HTS + VTS)
# (already set above via PLL + blanking)

# 9. Start streaming
0x4202 = 0x00      # disable sleep mode
0x300F = 0x00      # enable MIPI output (un-gate lanes)
```

**Do not copy this blindly.** The PLL values (`0x3035`–`0x3108`) are sensitive to your XCLK frequency and target MIPI lane speed. Wrong PLL values produce wrong frame rates or no MIPI output at all. Always cross-check against:
- The OV5647 datasheet §3.5 (PLL) and §6.8 (MIPI)
- The Linux `ov5647.c` driver mode tables (the most reliable source of known-good register sequences)

### Practical bring-up script in PetaLinux

Write a small script that issues the I²C writes from PetaLinux. Two approaches:

**Approach 1 — shell script with `i2cset`:**
```bash
#!/bin/sh
BUS=0      # the I2C bus number — verify with `i2cdetect -l`
ADDR=0x36  # 7-bit OV5647 SCCB address

i2cset -y $BUS $ADDR 0x30 0x08 0x82 i   # 16-bit reg: write 0x30, 0x08, 0x82
sleep 0.01
i2cset -y $BUS $ADDR 0x30 0x08 0x02 i
sleep 0.01
i2cset -y $BUS $ADDR 0x31 0x03 0x13 i
# ... continue for the full sequence
```

Note: `i2cset` with the `i` suffix uses I²C block write. The OV5647 uses 16-bit register addresses, so each write is `[reg_high, reg_low, data]` — a 3-byte block write.

**Approach 2 — C program using `/dev/i2c-N`:**
```c
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <unistd.h>

int i2c_fd = open("/dev/i2c-0", O_RDWR);
unsigned char addr = 0x36;
ioctl(i2c_fd, I2C_SLAVE, addr);

void ov5647_write(uint16_t reg, uint8_t val) {
    unsigned char buf[3] = { reg >> 8, reg & 0xFF, val };
    write(i2c_fd, buf, 3);
}

ov5647_write(0x3008, 0x82);  usleep(5000);
ov5647_write(0x3008, 0x02);  usleep(5000);
// ... full sequence
```

### Verifying the sensor is streaming

After writing the full sequence, check:
- **Register `0x3029`** (or the MIPI status register — verify the address in the datasheet) — should indicate lanes are in HS mode.
- **MIPI clock lane** — if you have an oscilloscope or high-speed probe, the CLK± pair should show a continuous differential clock at the calculated frequency (e.g. ~155 MHz for 1080p30 RAW10 2-lane).
- **MIPI data lanes** — should show bursts of HS activity (LP-00 between packets, HS during packets).

If the lanes stay in LP (no HS activity), the sensor did not start streaming — recheck the PLL and MIPI enable registers.

---

## 9. SCCB Control Channel on the AXU2CGB

### What SCCB is

SCCB (Serial Camera Control Bus) is OmniVision's I²C-compatible 2-wire serial bus:
- **SCLK** — serial clock (open-drain, needs a pull-up)
- **SDAT** — serial data (open-drain, needs a pull-up)

Electrically and protocol-wise it is I²C. The Linux `i2c` subsystem drives it as a normal I²C bus. The only nuance: SCCB traditionally uses a simplified I²C variant (no repeated start, fixed read sequence), but in practice the standard Linux I²C driver works with OmniVision sensors without modification.

### Routing on the AXU2CGB-E

The MIPI1 connector's SCCB lines (SDA, SCL) land on **BANK24** at 3.3 V (confirmed from J23 pin table — `cam1_scl` = AH13, `cam1_sda` = AE13). To drive them from the PS:

1. **Enable a PS I²C controller** in the Vivado Zynq PS block configuration — use **I2C0** (confirmed: bus 0 on this board).
2. **Route the I²C signals to EMIO** (not MIO) — because the SCCB pins are on PL I/O (BANK24), not MIO pins. EMIO extends the PS I²C controller through the PL to package pins.
3. In `mipi1.xdc`, the EMIO I²C SCL/SDA are already constrained to AH13/AE13 on BANK24.

### Finding the sensor: i2cdetect

> **Confirmed for this board:** OV5647 on MIPI1 J23 appears on **i2c-0** (`i2cdetect -y -r 0`).

**Step 1 — list buses (for reference):**
```bash
i2cdetect -l
```
```
i2c-0   i2c         ff020000.i2c                    I2C adapter   ← OV5647 is here
i2c-1   i2c         ff030000.i2c                    I2C adapter
```

**Step 2 — scan bus 0 for the OV5647 ✅ confirmed:**
```bash
i2cdetect -y -r 0
```
The OV5647 appears at address **36**:
```
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:          -- -- -- -- -- -- -- -- -- -- -- -- --
...
30: -- -- -- -- -- -- 36 -- -- -- -- -- -- -- -- --
...
```
If nothing appears: XCLK is not running, the ribbon cable is not seated, or the sensor has no power (check VCC_3V3 on pin 15).

**Step 3 — verify chip ID (run this next to confirm it's OV5647 and not another sensor):**

OV5647 uses 16-bit register addresses, so use `i2ctransfer` (not `i2cget`):
```bash
# Register 0x300A = chip ID high byte → should return 0x56
i2ctransfer -y 0 w2@0x36 0x30 0x0a r1

# Register 0x300B = chip ID low byte → should return 0x47
i2ctransfer -y 0 w2@0x36 0x30 0x0b r1
```
`0x56` + `0x47` = `"VG"` in ASCII = **OV5647** confirmed. If you get `0xFF`, the sensor is not responding — recheck XCLK and ribbon orientation.

### Pull-ups

The I²C/SCCB lines need pull-up resistors to VCC. The Pi V1 camera module has on-board 1.5 kΩ pull-ups (smaller than the usual 4.7 kΩ — the OV5647 needs them low to meet SCCB timing). If your module does not have on-board pull-ups, add 1.5–2.2 kΩ pull-ups on the carrier board or in your wiring.

### Which CPU drives SCCB

| CPU | Use case |
|-----|----------|
| **Cortex-A53 (Linux)** | Default — drive SCCB from a user-space script or kernel driver. Simplest for bring-up. |
| **Cortex-R5F (bare-metal/RTOS)** | If you need hard real-time exposure/gain control without Linux jitter. The R5F accesses the PL via `M_AXI_HPM0_LPD`. |
| **Soft I²C master in PL** | If you want the camera control entirely in FPGA logic, with no CPU involvement. More work, rarely needed. |

For bring-up, use the A53 under Linux — it is by far the easiest to debug (`i2cdetect`, `i2cset`, kernel logs).

---

## 10. Vivado Block Design for Bring-Up

The minimal block design to verify the MIPI data path:

```
┌─────────────────────────────────────────────────────────────┐
│  Zynq UltraScale+ ZU2CG (PS)                                │
│                                                             │
│  M_AXI_HPM0_FPD ──────► AXI Interconnect ──────► ┌──────────┐ │
│  (100 MHz)                                      │ MIPI     │ │
│                                                 │ CSI-2 Rx │ │
│  FCLK0 (100 MHz) ──► Clocking Wizard ──► ──────► │ Subsystem│ │
│                          (generates video clk,  │          │ │
│                           D-PHY ref clk, etc.)   └────┬─────┘ │
│                                                    │        │
│                                                    │ AXI4-  │
│                                                    │ Stream │
│                                                    ▼        │
│                                              ┌──────────┐   │
│                                              │ AXI4-    │   │
│                                              │ Stream   │   │
│                                              │ Data FIFO│   │
│                                              └────┬─────┘   │
│                                                   │         │
│                                                   ▼         │
│                                              ┌──────────┐   │
│                                              │ ILA      │   │
│                                              │ (probe   │   │
│                                              │  tdata,  │   │
│                                              │  tvalid, │   │
│                                              │  tlast,  │   │
│                                              │  tuser)  │   │
│                                              └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Step-by-step: Vivado block design

#### A. Create the project

1. Open Vivado → **Create Project** → RTL Project.
2. Part: `xczu2cg-sfvc784-1-e` (note: `-1-e`, not `-1-i`).
3. Add `src/constraints/mipi1.xdc` as a constraint source (tick "Copy into project").
4. Do not add any RTL sources yet — the MIPI Rx IP wraps everything.

#### B. Create the block design

1. Flow Navigator → **IP Integrator → Create Block Design**. Name it `mipi_bd`.
2. Add **Zynq UltraScale+ MPSoC** IP → Run Block Automation (defaults OK).
3. Double-click the Zynq block → **PS-PL Configuration**:
   - **PL Fabric Clocks**: FCLK0 = 100 MHz.
   - **PS-PL Interfaces → Master AXI HPM0 FPD**: enable (for MIPI IP register access from PS).
4. Still in the Zynq config → **I/O Configuration → I/O Peripherals → I2C**:
   - Enable **I2C0** → route to **EMIO** (not MIO — the SCCB pins are on PL BANK24, not MIO).
   - This exposes `iic_0` ports on the block design which you'll connect to `cam1_scl`/`cam1_sda` through top-level ports.
5. Click OK.

#### C. Add the Clocking Wizard

1. Add IP → search **Clocking Wizard**. Add it.
2. Double-click to configure:
   - Input: Primary = `clk_in1` from `pl_ref_clk` (25 MHz from the board — your PL reference).
     - Or use `FCLK0` from the Zynq PS (100 MHz). Either works; using `pl_ref_clk` is simpler for bring-up.
   - Output clocks:
     | Output | Frequency | Purpose |
     |--------|-----------|---------|
     | `clk_out1` | 200 MHz | D-PHY reference clock (required by MIPI Rx IP) |
     | `clk_out2` | 100 MHz | Video/AXI-Stream processing clock |
     | `clk_out3` | 24 MHz | XCLK for OV5647 sensor (drives AG13 / `cam1_clk`) |
3. Connect `clk_in1` to `pl_ref_clk` external port (create port, 25 MHz input).

#### D. Add the MIPI CSI-2 Receiver Subsystem IP

1. Add IP → search **MIPI CSI-2 Receiver Subsystem** (PG232). Add it.
2. Double-click to configure:
   - **Lanes**: 2.
   - **Pixel Format**: RAW8 (simpler for first bring-up) or RAW10.
   - **D-PHY Mode**: LVDS (not GTH).
   - **Line Rate**: set to match your OV5647 config — start with 400 Mbps per lane for 1080p30.
   - **AXI4-Lite Data Width**: 32.
3. Connect:
   - `lite_aclk` → `clk_out2` (100 MHz from Clocking Wizard).
   - `video_aclk` → `clk_out2`.
   - `dphy_clk_200M` → `clk_out1` (200 MHz D-PHY ref).
   - `s_axi_lite` → AXI Interconnect from `M_AXI_HPM0_FPD`.
   - `mipi_phy_if` → external port (this exposes the differential D-PHY pins — `mipi_phy_if_clk_p/n`, `mipi_phy_if_data_p/n[0]`, `mipi_phy_if_data_p/n[1]`).

#### E. Add the AXI4-Stream FIFO

1. Add IP → **AXI4-Stream Data FIFO**. Add it.
2. Configure: depth = 4096, data width matches MIPI Rx output (32 for RAW8, 40 for RAW10).
3. Connect `S_AXIS` to the MIPI Rx IP's `m00_axis` output.
4. Connect clocks to `clk_out2`.

#### F. Add the ILA

1. Add IP → **ILA (Integrated Logic Analyzer)**. Add it.
2. Configure:
   - Number of probes: 5.
   - Probe widths: `probe0` = 32 (tdata), `probe1` = 1 (tvalid), `probe2` = 1 (tlast), `probe3` = 1 (tuser), `probe4` = 1 (tready).
   - Sample depth: 4096.
3. Connect probes to the FIFO output `M_AXIS` signals.
4. Connect `clk` to `clk_out2`.
5. Tie the FIFO `M_AXIS_TREADY` to 1 (we don't consume data for bring-up).

#### G. Add the XCLK and I2C output ports

1. Add output port `cam1_clk` (1-bit output). Connect to `clk_out3` (24 MHz) through a Utility Buffer (OBUF).
2. Add output port `cam1_scl`, `cam1_sda` — connect to the Zynq `IIC0_SCL_O` / `IIC0_SDA_O` EMIO outputs.
3. Add output port `cam1_gpio` — tie to `1` for now (holds camera out of reset).

#### H. Validate and generate

1. **Tools → Validate Block Design** (or the tick icon). Fix any critical errors (usually unconnected clocks or resets).
2. Right-click the block design in Sources → **Create HDL Wrapper** → Let Vivado manage.
3. The wrapper (e.g., `mipi_bd_wrapper.v`) is now the synthesis top.

---

### Step-by-step: Synthesis → Bitstream

Once the block design is valid:

#### I. Run Synthesis

1. Flow Navigator → **Synthesis → Run Synthesis**.
2. When done: **Open Synthesized Design**.
3. Check the **Device view** — confirm the MIPI pins (AC9/AD9/AB8/AC8/AE9/AE8) appear in BANK64 and the control pins (AG13/AH13/AE13/AH14) appear in BANK24. If any pin is red/unassigned, the XDC is not being applied — verify `mipi1.xdc` is listed under **Sources → Constraints**.
4. Check **Utilization** — verify BRAM/LUT/FF counts look reasonable for the IP.

#### J. Run Implementation

1. Flow Navigator → **Implementation → Run Implementation**.
2. When done: **Open Implemented Design → Timing Summary**.
3. Check **WNS (Worst Negative Slack)**:
   - WNS ≥ 0 → timing met, proceed.
   - WNS < 0 → timing violation. For bring-up, a small negative slack (< −0.5 ns) on non-critical paths is usually OK. A large violation means a clock constraint or Clocking Wizard setting is wrong.

#### K. Generate Bitstream

1. Flow Navigator → **Generate Bitstream**.
2. When done: a dialog asks to **Open Hardware Manager** or **View Reports**. Click **Open Hardware Manager**.

---

### Step-by-step: Export to Vitis (PS bring-up)

You need Vitis to write the OV5647 I2C register sequence from the ARM side.

#### L. Export Hardware

1. In Vivado: **File → Export → Export Hardware**.
2. Select **Include Bitstream** (the PL config must be in the .xsa because Vitis will program both PS and PL).
3. Output: `mipi_bd_wrapper.xsa`. Note where it's saved.

#### M. Create the Vitis platform and application

1. Launch Vitis (from Vivado: **Tools → Launch Vitis**, or open separately).
2. **File → New → Platform Project**:
   - Name: `mipi_platform`.
   - Hardware: select the `.xsa` you just exported.
   - OS: **standalone** (baremetal).
   - CPU: `psu_cortexa53_0`.
   - Vitis auto-creates the FSBL and BSP.
3. **File → New → Application Project**:
   - Platform: `mipi_platform`.
   - Name: `ov5647_init`.
   - Template: **Empty Application** (or Hello World — you'll replace it).

#### N. Write the OV5647 I2C init code

In `src/main.c` of the `ov5647_init` app:

```c
#include "xparameters.h"
#include "xiicps.h"
#include "xil_printf.h"
#include "sleep.h"

#define IIC_DEVICE_ID   XPAR_XIICPS_0_DEVICE_ID   // I2C0 → EMIO → cam1_scl/sda (confirmed: bus 0)
#define OV5647_ADDR     0x36                        // 7-bit I2C address

static XIicPs iic;

// Write one register: reg_addr (16-bit), data (8-bit)
static int ov5647_write(u16 reg, u8 val) {
    u8 buf[3] = { (reg >> 8) & 0xFF, reg & 0xFF, val };
    return XIicPs_MasterSendPolled(&iic, buf, 3, OV5647_ADDR);
}

int main(void) {
    XIicPs_Config *cfg = XIicPs_LookupConfig(IIC_DEVICE_ID);
    XIicPs_CfgInitialize(&iic, cfg, cfg->BaseAddress);
    XIicPs_SetSClk(&iic, 100000);    // 100 kHz SCCB clock

    xil_printf("OV5647 init start\r\n");

    // Soft reset
    ov5647_write(0x0103, 0x01);
    usleep(10000);

    // Stream on (minimal — sensor starts sending MIPI data)
    ov5647_write(0x0100, 0x01);

    xil_printf("OV5647 streaming\r\n");
    // At this point the ILA should trigger on tvalid rising.

    while (1) {}
    return 0;
}
```

> This is the minimal "stream on" sequence. See §8 for the full register table including resolution, frame rate, exposure, and test pattern settings.

#### O. Build, program, and run

1. Right-click `ov5647_init` → **Build Project**.
2. Connect the JTAG cable (AL321) to the board and your PC.
3. Power on the board. Set boot-mode switch to **JTAG** (all ON).
4. In Vitis: right-click `ov5647_init` → **Run As → Launch on Hardware (Single Application Debug)**.
   - Vitis programs the PL bitstream + runs the FSBL + runs your app — all via JTAG in one click.
5. Watch the UART terminal (`115200 8N1`) — you should see `OV5647 init start` then `OV5647 streaming`.

#### P. Switch to Vivado Hardware Manager for ILA

1. While the board is running, open Vivado → **Hardware Manager → Open Target → Auto Connect**.
2. The ZU2CG device appears. Under it you'll see the ILA core (`hw_ila_1`).
3. **Set up a trigger**: probe1 (tvalid) = rising edge.
4. Click **Run Trigger**. If the sensor is streaming, the ILA captures immediately.
5. See §11 for what to look for in the waveform.

---

### UART logging — real-time stats via PuTTY

The ILA gives you one snapshot. For continuous feedback ("is data still arriving while I move the sensor?") use UART logging from the Vitis app. `xil_printf()` output goes through the board's USB-to-UART chip to PuTTY — completely independent of JTAG.

```
[Vitis app: xil_printf()]
        │
        ▼
  PS UART (MIO pins)
        │
        ▼
  USB-to-UART on board (MINI USB port, separate from JTAG port)
        │  USB cable
        ▼
  PuTTY (115200 8N1)   ← you read output here in real time
```

**PuTTY settings:** Connection type = Serial, Speed = 115200, Data = 8, Stop = 1, Parity = None, Flow = None. Port = whatever COM port the MINI USB shows up as (Windows Device Manager → Silicon Labs CP210x or CH340).

#### Add two AXI GPIO IPs to the block design (for counter readback)

After step F (ILA), add these two IPs to expose `mipi_stats` counters to the PS:

1. Add IP → **AXI GPIO** (first instance):
   - Name it `axi_gpio_frame`.
   - Configure: GPIO Width = 32, All Inputs = ✅, 1 channel.
   - Connect `GPIO_I[31:0]` to `frame_cnt[31:0]` output of `mipi_stats`.
   - Connect to AXI Interconnect from `M_AXI_HPM0_FPD`.
2. Add IP → **AXI GPIO** (second instance):
   - Name it `axi_gpio_pixel`.
   - Configure: GPIO Width = 32, All Inputs = ✅.
   - Connect `GPIO_I[31:0]` to `pixel_cnt[31:0]` output of `mipi_stats`.
   - Connect to same AXI Interconnect.
3. Connect both clocks to `clk_out2` (100 MHz).

After re-exporting the `.xsa`, Vitis auto-generates `XPAR_AXI_GPIO_0_DEVICE_ID` and `XPAR_AXI_GPIO_1_DEVICE_ID` in `xparameters.h`.

#### Vitis UART logging code

Replace the `main.c` from step N with this version — it streams live stats to PuTTY every 500 ms:

```c
#include "xparameters.h"
#include "xgpio.h"
#include "xiicps.h"
#include "xil_printf.h"
#include "sleep.h"

// Check xparameters.h after export — IDs may differ
#define GPIO_FRAME_ID   XPAR_AXI_GPIO_0_DEVICE_ID
#define GPIO_PIXEL_ID   XPAR_AXI_GPIO_1_DEVICE_ID
#define IIC_DEVICE_ID   XPAR_XIICPS_0_DEVICE_ID   // I2C0, confirmed bus 0 on this board
#define OV5647_ADDR     0x36

static XGpio  gpio_frame, gpio_pixel;
static XIicPs iic;

static int ov5647_write(u16 reg, u8 val) {
    u8 buf[3] = { (reg >> 8) & 0xFF, reg & 0xFF, val };
    return XIicPs_MasterSendPolled(&iic, buf, 3, OV5647_ADDR);
}

int main(void) {
    // Init I2C
    XIicPs_Config *cfg = XIicPs_LookupConfig(IIC_DEVICE_ID);
    XIicPs_CfgInitialize(&iic, cfg, cfg->BaseAddress);
    XIicPs_SetSClk(&iic, 100000);   // 100 kHz SCCB

    // Init GPIO readers
    XGpio_Initialize(&gpio_frame, GPIO_FRAME_ID);
    XGpio_Initialize(&gpio_pixel, GPIO_PIXEL_ID);
    XGpio_SetDataDirection(&gpio_frame, 1, 0xFFFFFFFF); // all inputs
    XGpio_SetDataDirection(&gpio_pixel, 1, 0xFFFFFFFF);

    xil_printf("\r\n=== OV5647 MIPI bring-up ===\r\n");

    // Soft reset then stream on
    ov5647_write(0x0103, 0x01);
    usleep(10000);
    ov5647_write(0x0100, 0x01);

    xil_printf("OV5647 streaming. Move the sensor and watch below.\r\n\r\n");

    u32 prev_frame = 0;
    u32 prev_pixel = 0;

    while (1) {
        u32 frames = XGpio_DiscreteRead(&gpio_frame, 1);
        u32 pixels = XGpio_DiscreteRead(&gpio_pixel, 1);
        u32 new_frames = frames - prev_frame;
        u32 new_pixels = pixels - prev_pixel;

        xil_printf("frames=%lu (+%lu)  pixels=%lu (+%lu)  %s\r\n",
            frames, new_frames, pixels, new_pixels,
            new_frames > 0 ? "STREAMING" : "*** NO DATA ***");

        prev_frame = frames;
        prev_pixel = pixels;
        usleep(500000);     // update every 500 ms
    }
}
```

#### What you'll see in PuTTY

When the sensor is pointing at a scene at 30 fps:
```
=== OV5647 MIPI bring-up ===
OV5647 streaming. Move the sensor and watch below.

frames=0 (+0)    pixels=0 (+0)          *** NO DATA ***
frames=15 (+15)  pixels=32400000 (+32400000)  STREAMING
frames=30 (+15)  pixels=64800000 (+32400000)  STREAMING
frames=45 (+15)  pixels=97200000 (+32400000)  STREAMING
```
~15 new frames every 500 ms = 30 fps. Cover the lens or unplug the ribbon — `new_frames` drops to 0 and you see `*** NO DATA ***` immediately. This gives you live feedback while physically handling the camera.

| ILA | UART logging | Use for |
|-----|-------------|---------|
| One-shot snapshot | Continuous stream | ILA: confirm signal correctness once |
| Freeze on trigger | Updates every 500 ms | UART: watch it react to sensor movement |
| Shows raw tdata values | Shows frame/pixel counts | Both together = full picture |

### Why the ILA, not HDMI, for first bring-up

Do not connect HDMI or DDR output for the first data-path test. The ILA lets you see the raw AXI4-Stream directly:
- You can trigger on `tuser=1` (SOF) and see exactly one frame.
- You can inspect `tdata` values to confirm they are non-zero and varying (real Bayer data, not stuck).
- You can check `tlast` pulses per row and count them (should be 1080 for 1080p).
- If something is wrong, the ILA shows you exactly where — HDMI adds a display pipeline with its own failure modes that obscure the camera problem.

Only after the ILA shows a clean, complete frame should you add demosaic + HDMI or DMA-to-DDR output.

---

## 11. ILA-Based Data Path Verification

After programming the PL and running the OV5647 I²C bring-up script from PetaLinux:

### Step 1 — Trigger on `tvalid` rising edge

If `tvalid` toggles (goes high, then low during blanking, then high again), the MIPI link is alive and the sensor is sending packets. The MIPI Rx IP is decoding them and producing an AXI4-Stream.

If `tvalid` never goes high:
- The sensor is not streaming (recheck I²C sequence, XCLK, MIPI enable registers).
- The MIPI Rx IP is not seeing valid HS data (recheck pin constraints, bank voltage, D-PHY configuration).
- The IP's internal status registers (read via AXI-Lite from PetaLinux) may indicate lane state — check for error flags.

### Step 2 — Trigger on `tuser=1` (SOF)

`tuser` pulsing once per frame confirms the sensor's Frame Start short packets are being decoded. You should see `tuser=1` on exactly one cycle, followed by `tvalid` high for the first row, then `tlast`, then the next row, etc.

If `tvalid` toggles but `tuser` never pulses:
- The FS short packet is not being detected. Check the OV5647's MIPI CTRL register (`0x4800`) — ensure frame sync packets are enabled.
- The virtual channel in the FS packet does not match the IP's configured VC. The OV5647 uses VC0; ensure the IP is set to accept VC0.

### Step 3 — Check `tlast` per row

`tlast` should pulse once per row. For 1080p, you should see 1080 `tlast` pulses between two `tuser` pulses. Count them in the ILA waveform.

If `tlast` never pulses:
- The sensor is sending data but not line-end markers. Check whether the OV5647 is configured to send LE short packets or whether the IP derives TLAST from the long-packet word count (some IP configurations do this — check PG232).

### Step 4 — Inspect `tdata`

For RAW10, `tdata` carries 10-bit Bayer photosite values. They should be:
- **Non-zero** (unless the lens cap is on or exposure is zero).
- **Varying** across pixels (real scene content).
- **In the expected Bayer pattern** — for BGGR, even rows alternate B/G, odd rows alternate G/R.

If `tdata` is all 0x00:
- The sensor is not exposing (check AEC registers, exposure time, or the lens cap).
- The MIPI payload is all zero (sensor in test pattern mode? check register `0x501F` or the test pattern enable register).

If `tdata` shows a repeating pattern of fixed values:
- The sensor may be in test pattern mode (some OV5647 configs boot into a test pattern). Disable it via the test pattern register.

If `tdata` looks like random noise:
- Signal integrity problem — check the ribbon cable seating, cable length, and bank voltage.
- Wrong RAW format — if the IP expects RAW8 but the sensor sends RAW10 (or vice versa), the byte alignment will be wrong and the data will look like garbage.

### Step 5 — Check `tready` stalls

If your ILA FIFO or downstream consumer is not ready, `tready` goes low and `tvalid` stays high with data held — this is normal backpressure. For bring-up, tie `tready` to 1 (or use a FIFO deep enough that it never fills). If you see `tready` stalls, the consumer is too slow — increase FIFO depth or clock the consumer faster.

---

## 12. Common Failures and Debugging

| Symptom | Likely cause | Check |
|---------|-------------|-------|
| `i2cdetect` does not find 0x36 | SCCB wiring, pull-ups, wrong I²C bus, sensor not powered | Verify 3.3 V on the module, check SDA/SCL with a scope, try `i2cdetect -y <N>` on each bus |
| I²C finds 0x36 but writes have no effect | Wrong register address format (16-bit vs 8-bit), or sensor in reset | Ensure you write `[reg_hi, reg_lo, data]` as a 3-byte block; check `0x3008` is not 0x82 (reset) |
| Sensor configured but no MIPI activity (CLK lane idle) | MIPI not enabled, PLL not running, XCLK missing | Check `0x300E`, `0x4800`, `0x3016`; verify XCLK with a scope on the sensor's XCLK pin |
| MIPI clock present but no data lane activity | Lanes not enabled, or sensor in sleep | Check `0x3016`/`0x3017` lane enable bits; check `0x4202` (sleep mode) |
| MIPI Rx IP reports no valid packets | Pin constraints wrong, bank voltage wrong, signal integrity | Recheck XDC pin assignments against the ALINX schematic; verify BANK64 VCCO = 1.2 V; check cable seating |
| `tvalid` toggles but `tuser` never pulses | FS short packet not sent or not decoded | Check OV5647 `0x4800` bit 4 (line sync); check IP VC configuration |
| `tdata` all zeros | Sensor not exposing, or in test pattern mode | Check AEC/exposure registers; disable test pattern |
| `tdata` looks like garbage | RAW8/RAW10 mismatch between sensor config and IP config | Ensure both sides agree on RAW8 or RAW10; check the IP's data type setting |
| Intermittent `tvalid` / corrupted frames | Signal integrity over the ribbon cable | Shorten the cable; ensure it is fully seated; verify differential pair routing on the PCB |
| Frame rate wrong | PLL misconfigured for your XCLK | Recalculate PLL registers from the datasheet for your XCLK frequency |

### Debugging with the MIPI Rx IP status registers

The MIPI CSI-2 Rx Subsystem exposes status registers via AXI-Lite. From PetaLinux, you can read these with `devmem` or a small program:

```bash
# Read the IP's status register (address depends on your AXI base — e.g. 0x80000000)
devmem 0x80000040 32    # example: lane status register
```

Useful status bits (exact addresses from PG232):
- **Lane stop state** — are the lanes in LP-11 (stop) or LP-00 (idle)?
- **HS receive active** — is the IP currently receiving an HS burst?
- **ECC error count** — header corruption (signal integrity problem)
- **CRC error count** — payload corruption (signal integrity problem)
- **Packet errors** — malformed packets (protocol mismatch)

Non-zero ECC/CRC error counts that grow over time indicate a signal integrity problem on the ribbon cable or PCB — not a configuration problem.

---

## 13. After Bring-Up — Demosaic and Downstream

Once the ILA confirms a clean, complete frame of RAW Bayer data, the MIPI data path is working. The next step is to convert the RAW Bayer stream into something useful.

### The mandatory first block: demosaic

The OV5647 outputs RAW Bayer only. Every pixel carries only one of R/G/B (depending on its position in the Bayer grid). To get full RGB at every pixel, you must **interpolate** the missing two channels from neighbours — this is **demosaicing**.

```
MIPI Rx output (RAW Bayer, 1 pixel/cycle)
    │
    ▼
[Demosaic]  ── 2 BRAM line buffers + 3×3 sliding window
    │           Bilinear interpolation: ~6 DSPs, ~150 LUTs
    │           Or use Xilinx v_demosaic IP (free, Vivado)
    ▼
RGB888 (24-bit TDATA: {R[7:0], G[7:0], B[7:0]})
    │
    ▼
[Color space convert]  ── RGB → YUV422 or grayscale, as needed
    │                     3 DSPs for matrix multiply, or Xilinx v_rgb2ycrcb IP
    ▼
[Your processing pipeline]  ── filters, detection, CNN, etc.
    │
    ▼
[HDMI output] or [AXI DMA → DDR → PetaLinux reads frame]
```

### Bayer pattern on the OV5647

The OV5647's default Bayer pattern is **BGGR**:

```
      col0  col1  col2  col3
row0:  B     G     B     G
row1:  G     R     G     R
row2:  B     G     B     G
row3:  G     R     G     R
```

Verify the actual pattern via register `0x4300` (and `0x501F`) after configuration. Your demosaic block's phase logic must match — a BGGR demosaic fed RGGR data produces wrong colours.

### Demosaic resource cost

For bilinear demosaic (the simplest method):
- **2 BRAM line buffers** (one row width each — 1920 × 10 bits ≈ 20 Kb per buffer, fits in one 36 Kb BRAM block each)
- **3×3 sliding window** (shift registers + line buffer reads)
- **~6 DSPs** (multiplications for the interpolation weights)
- **~150 LUTs, ~200 FFs**
- **Latency**: 2 rows + a few cycles (the time to fill the line buffers before the first output pixel)

Or use the **Xilinx `v_demosaic` IP** (free, included with Vivado) — it handles the window logic and interpolation for you, parameterised by Bayer pattern and bit width. See [06 — Vision on FPGAs](./06_VISION_ON_FPGA.md) §6 (Bayer Demosaicing).

### Output options after demosaic

| Destination | How | When to use |
|-------------|-----|------------|
| **HDMI output** | `v_axi4s_vid_out` IP + TMDS I/O (or PS DisplayPort) | Visual confirmation, real-time display |
| **DDR via AXI DMA** | AXI DMA → `S_AXI_HP0_FPD` → DDR; PetaLinux reads frame and saves as PNG | Frame capture, offline analysis, debugging |
| **Direct to processing** | Feed the RGB stream into your filter/detection/CNN pipeline | The actual application |

For first visual confirmation, route to DDR and save a frame as a PNG from PetaLinux — you can then inspect it on your PC and confirm the colours and content are correct before trusting the pipeline further.

---

## 14. Checklist Before Writing Any RTL

- [ ] **Camera module identified** — Raspberry Pi V1 (OV5647, MIPI-only) or ALINX AN5641-style (OV5640/5647, MIPI)?
- [ ] **Ribbon cable pinout verified** — ALINX 15-pin FPC pinout matches your camera module's pinout (pin-by-pin comparison against the schematic)
- [ ] **SCCB working** — `i2cdetect` finds the OV5647 at 0x36 from PetaLinux
- [ ] **XCLK source confirmed** — the OV5647 has a 24 MHz (or other) input clock, either from the module's on-board oscillator or from a PL clock output pin
- [ ] **Power rails correct** — 3.3 V on the module (Pi V1 generates 1.5 V and 2.8 V internally); BANK64 at 1.2 V for MIPI1 (J23); BANK24 at 3.3 V for SCCB
- [ ] **Vivado part** — `xczu2cg-sfvc784-1-e` (verify exact speed grade and package from your board)
- [ ] **MIPI CSI-2 Rx Subsystem configured** — 2 lanes, RAW10 (or RAW8), D-PHY LVDS, target bank 64 (MIPI1/J23)
- [ ] **XDC constraints written** — use [`src/constraints/mipi1.xdc`](../../src/constraints/mipi1.xdc); MIPI lane pins (CLK±, D0±, D1±) on BANK64; SCCB pins (AH13/AE13) on BANK24
- [ ] **Clocking verified** — Clocking Wizard generates the IP's required clocks from FCLK0; frequencies match PG232
- [ ] **ILA attached** — probing `tdata`, `tvalid`, `tlast`, `tuser`, `tready` on the MIPI Rx output
- [ ] **OV5647 register sequence ready** — pulled from the Linux `ov5647.c` driver for your target resolution; PLL values matched to your XCLK
- [ ] **Bring-up script ready** — shell or C script to issue the I²C writes from PetaLinux
- [ ] **Demosaic planned** — either hand-written (2 line buffers + 3×3 window) or Xilinx `v_demosaic` IP; Bayer pattern (BGGR) confirmed

---

**Previous**: [11 — Video Processing Fundamentals](./11_VIDEO_PROCESSING_FUNDAMENTALS.md)
**Back to index**: [00 — Wiki Index](../00_INDEX.md)
