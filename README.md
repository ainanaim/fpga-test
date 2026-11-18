# FPGA Vision Pipeline — AXU2CGB / OV5647 MIPI

FPGA-based computer vision bring-up on the **ALINX AXU2CGB** (Zynq UltraScale+ ZU2CG).
Goal: get an **OV5647 MIPI camera** flowing through the FPGA PL, verify with RTL/ILA,
and connect to PS/DDR software — with clean, reusable RTL that translates to ASIC design.

## Hardware

| Component | Detail |
|-----------|--------|
| Board | ALINX AXU2CGB |
| FPGA | Zynq UltraScale+ XCZU2CG (speed -1E) |
| Camera | OV5647 (OmniVision, MIPI CSI-2, 2-lane, I²C/SCCB at 0x36) |
| Camera connector | MIPI1 / J23 (BANK64 D-PHY, BANK24 control) |
| Target part | `xczu2cg-sfvc784-1-e` |

## Repository Structure

```
fpga-test/
├── src/
│   ├── constraints/              XDC pin constraints
│   │   ├── mipi1.xdc             ✅ Active — J23 MIPI1 pins
│   │   └── mipi2.xdc             Reference — J24 MIPI2 pins
│   └── rtl/
│       ├── mipi_verify/          Phase 4 verification modules
│       │   ├── ila_mipi_wrapper.v  ILA probe wrapper
│       │   ├── mipi_stats.v        Frame/pixel/line counters
│       │   └── line_buffer_passthrough.v  AXI-Stream line buffer
│       └── pipeline/             Vision processing (future)
│           └── mac_array_3x3.v
├── vivado/
│   └── create_mipi_bringup.tcl   One-shot Vivado project generator
├── wiki/                         Engineering notes & course translations
│   ├── fundamentals/             FPGA basics, HDL, toolchain, memory
│   ├── hardware/                 Board selection, timing, Zynq ref
│   ├── planning/                 Roadmap, learning path
│   ├── tutorials/                ALINX course translations (EN)
│   └── vision/                   Vision pipeline docs
│       └── 12_OV5647_MIPI_CAMERA_PATH.md  ← main camera guide
└── resources/                    Reference PDFs
    ├── ds891-zynq-ultrascale-plus-overview.pdf
    ├── ug1085-zynq-ultrascale-trm.pdf
    └── tutorial(cn)/             Original ALINX Chinese course PDFs
```

## Quick Start

### 1. Generate the Vivado project

In the Vivado Tcl Console:
```tcl
cd /path/to/fpga-test
source vivado/create_mipi_bringup.tcl
```

Then **File → Open Project** → `vivado/mipi_bringup/mipi_bringup.xpr`

The script creates the full block design: Zynq PS, Clocking Wizard, MIPI CSI-2 Rx
Subystem, AXI IIC (SCCB), AXI-Stream FIFO, and loads `mipi1.xdc` automatically.

### 2. One manual step in Vivado

Connect ILA probe ports in the block design diagram (or skip if no JTAG cable yet):
```
probe0[31:0]  ← axis_data_fifo_0 m_axis_tdata
probe1[0]     ← axis_data_fifo_0 m_axis_tvalid
probe2[0]     ← axis_data_fifo_0 m_axis_tlast
probe3[0]     ← axis_data_fifo_0 m_axis_tuser[0]
probe4[0]     ← xlconstant_tready dout
```

### 3. Build bitstream

**Validate → Synthesis → Implementation → Generate Bitstream → Export Hardware (.xsa)**

### 4. Vitis — write and run the camera init app

```
Platform Project  (from .xsa)
  └── Application Project (standalone, C)
        └── main.c — OV5647 register init + stream-on
System Project
  └── Create Boot Image → BOOT.bin → SD card (FAT32)
```

### 5. Verify

```bash
# PetaLinux / serial console over PuTTY (115200 8N1)
i2cdetect -y -r 0                              # OV5647 at 0x36
i2ctransfer -y 0 w2@0x36 0x30 0x0a r1         # → 0x56 (chip ID high)
i2ctransfer -y 0 w2@0x36 0x30 0x0b r1         # → 0x47 (chip ID low)
```

## Current Status

| Stage | Status |
|-------|--------|
| Pin assignments (J23/MIPI1) | ✅ Confirmed from schematic |
| XDC constraints (`mipi1.xdc`) | ✅ Complete, pull-ups added |
| Vivado Tcl project script | ✅ Working |
| OV5647 I²C chip ID (0x5647) | ✅ Confirmed via PetaLinux |
| Bitstream generation | ✅ Working |
| Vitis BOOT.bin on SD card | 🔄 In progress |
| MIPI streaming verification (ILA/UART) | Pending JTAG cable |

## Key Docs

- **Camera path**: [`wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md`](wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md)
- **Learning path**: [`wiki/planning/15_LEARNING_PATH.md`](wiki/planning/15_LEARNING_PATH.md)
- **Toolchain guide**: [`wiki/fundamentals/04_TOOLCHAIN_AND_FLOW.md`](wiki/fundamentals/04_TOOLCHAIN_AND_FLOW.md)
- **ALINX course 1 (EN)**: [`wiki/tutorials/14_ALINX_FPGA_COURSE1.md`](wiki/tutorials/14_ALINX_FPGA_COURSE1.md)
- **Vitis guide**: [`wiki/tutorials/13_VITIS_GETTING_STARTED.md`](wiki/tutorials/13_VITIS_GETTING_STARTED.md)

## Requirements

- Vivado 2020.1+ (tested on 2020.1)
- Vitis 2020.1+ (for PS application development)
- AXU2CGB board with OV5647 MIPI camera (J23)
- USB UART cable (MINI USB → PC) for PuTTY
- JTAG cable (AL321 or compatible 10-pin) — needed for ILA/debugging (not yet available)
- SD card (FAT32) for BOOT.bin boot

## Toolchain

| Tool | Version | Purpose |
|------|---------|---------|
| Vivado | 2020.1 | Synthesis, implementation, bitstream |
| Vitis | 2020.1 | PS software, BOOT.bin generation |
| PetaLinux | — | Linux OS (alternative to baremetal Vitis) |
| PuTTY | any | UART serial output (115200 8N1) |

## Notes

- **Do not commit** `vivado/mipi_bringup/` — generated output, machine-specific.
  Only `vivado/create_mipi_bringup.tcl` is version-controlled.
- The official ALINX reference repo: [alinxalinx/AXU2CGA_AXU2CGB](https://github.com/alinxalinx/AXU2CGA_AXU2CGB)
- PS UART1 is on **MIO 24..25**, SD card on **MIO 46..51** (CD on MIO 45).
- I2C/SCCB bus is **I2C0 → AXI IIC IP** → `cam1_i2c_scl_io` (AH13) / `cam1_i2c_sda_io` (AE13).
