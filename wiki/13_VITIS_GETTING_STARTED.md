# 13 — Getting Started with Vitis on the ALINX ZYNQ MPSoC Board

> A translated, step-by-step English guide based on **Chapter 1 ("Experience ARM — Bare-metal Hello World")** of the
> *ALINX ZYNQ MPSoC Development Platform Vitis Application Tutorial V1.06* (Chinese, 388 pages, author 梅士清).
> Source PDF: `course_s2_ALINX_ZYNQ_MPSoC开发平台Vitis应用教程V1.06.pdf`
>
> This chapter is the canonical "first Vitis project" walkthrough for the AXU2CGA / AXU2CGB boards. It shows the full
> ZYNQ development flow: a **FPGA engineer** builds the hardware in Vivado and exports an `.xsa`, then a **software
> engineer** imports that `.xsa` into Vitis, creates an application, runs it over JTAG, and finally "solidifies" it
> (flashes it to SD card / QSPI so the board boots standalone).

---

## Table of Contents
1. [Prerequisites & Environment](#1-prerequisites--environment)
2. [The Two Roles in ZYNQ Development](#2-the-two-roles-in-zynq-development)
3. [Fast Path: Batch-Script Project Creation](#3-fast-path-batch-script-project-creation)
4. [FPGA Engineer — Build the Vivado Hardware Project](#4-fpga-engineer--build-the-vivado-hardware-project)
5. [Software Engineer — Create the Vitis Application](#5-software-engineer--create-the-vitis-application)
6. [Build, Run, and Debug over JTAG](#6-build-run-and-debug-over-jtag)
7. [Solidifying the Program (Boot Images)](#7-solidifying-the-program-boot-images)
8. [SD Card Boot Test](#8-sd-card-boot-test)
9. [QSPI Flash Boot Test](#9-qspi-flash-boot-test)
10. [Batch-Script QSPI Programming](#10-batch-script-qspi-programming)
11. [Common Pitfalls & Tips](#11-common-pitfalls--tips)
12. [Quick Command Cheat-Sheet](#12-quick-command-cheat-sheet)

---

## 1. Prerequisites & Environment

| Item | Value |
|------|-------|
| Software | **Vivado / Vitis 2020.1** (the tutorial's reference version) |
| Board model | **AXU2CGA** or **AXU2CGB** |
| Chip part | `xczu2cg-sfvc784-1-e` (Zynq UltraScale+ ZU2CG) |
| Cables needed | JTAG cable, USB-UART cable to PC |
| Serial terminal | PuTTY (or any terminal) — **115200 baud** |

> The tutorial notes that every example project ships with a `bootimage/` folder containing the matching `BOOT.bin`,
> and a `vitis/` folder containing the `.xsa` plus an auto-create script, so you can skip manual setup if you only want
> to run the demos.

---

## 2. The Two Roles in ZYNQ Development

ZYNQ's strength is the tight coupling of FPGA (PL) and ARM (PS). This requires a clean division of labor:

- **FPGA engineer** — builds the Vivado block design, configures the ZYNQ PS (MIO, clocks, DDR, peripherals),
  generates the bitstream (if PL logic is used), and exports a hardware description file **`.xsa`**.
- **Software engineer** — takes the `.xsa`, creates a **Platform project** + **Application project** in Vitis,
  writes/debugs the C application, and produces the boot image (`BOOT.bin`).

This chapter uses a trivial **UART "Hello World"** to walk through both halves. Because it only uses the PS UART,
no PL bitstream is needed — but a Vivado project is still required to configure the PS pins.

---

## 3. Fast Path: Batch-Script Project Creation

If you don't want to step through the GUI manually, ALINX provides scripts:

1. Each project has a `vitis/` folder containing the `.xsa` and an `auto_create_vitis/` directory.
2. Right-click **`build_vitis.bat`** → Edit. Change the `xsct.bat` path to your install, e.g.
   `C:\Xilinx\Vitis\2020.1\bin\xsct.bat`.
3. Save, then **double-click `build_vitis.bat`**. It runs `xsct` to auto-generate the Platform + Application projects.
4. When it finishes ("press any key to exit"), open Vitis, choose the generated workspace folder, click **Launch**,
   close the Welcome screen — the project is ready to use.

> Source files for non-template apps live in `vitis/auto_create_vitis/src/`.

---

## 4. FPGA Engineer — Build the Vivado Hardware Project

Project name: **`ps_hello`** (Vivado dir `ps_hello/vivado`, Vitis dir `ps_hello/vitis`).

### 4.1 Create the block design
1. Create a Vivado project named `ps_hello`.
2. **Create Block Design** (graphical design). Keep the default design name `design_1` (keep names short — long names
   can cause Windows build issues).
3. Click **Add IP**, search `zynq`, double-click **Zynq UltraScale+ MPSoC**.
4. Double-click the ZYNQ block to open its configuration. The first view is the ZYNQ architecture diagram (see UG1085);
   green blocks are configurable; you can also navigate via the left pane.

### 4.2 Low-Speed I/O Configuration
In **I/O Configuration**:
- Set **BANK0–BANK2 = LVCMOS18**, **BANK3 = LVCMOS33**.
- **QSPI**: enable, mode `Single`, Data Mode `x4`, enable Feedback Clk.
- **SD 0 (eMMC)**: enable, MIO 13..22, Slot Type `eMMC`, 8-bit, enable Reset → MIO 23.
  *(AXU2CGA has no eMMC — skip this.)*
- **SD 1 (SD card)**: enable, MIO 46..51, Slot Type `SD 2.0`, 4-bit, enable CD → MIO 45.
- **I2C 1** (for EEPROM etc.): enable, MIO 32..33.
- **UART 1**: enable, MIO 24..25.
- **TTC0–TTC3**: enable.

### 4.3 High-Speed Configuration
- **GEM 3 (Ethernet)**: enable, MIO 64..75; enable **MDIO 3** → MIO 76..77.
- **USB 0**: enable, MIO 52..63; enable **USB 3.0** → GT Lane1; USB reset → MIO 44.
- **PCIe**: enable. Switch to **Advanced Mode** → PCIe Configuration → set to **ROOT** mode.
- Back in I/O Configuration: **GT Lane0**, reset → MIO 37; **Display Port**: enable, MIO 27..30, Lane Selection
  `Dual Higher`.

### 4.4 Clock Configuration
In **Clock Configuration → Input Clocks**:
- `PSS_REF_CLK` (ARM reference) = 33.333 MHz (default).
- PCIe → Ref Clk0, 100 MHz.
- Display Port → Ref Clk2, 27 MHz.
- USB0 → Ref Clk1, 26 MHz.

In **Output Clocks**: make sure everything uses **IOPLL** consistently (change any non-IOPLL entry to IOPLL so the
same PLL is used). PL clocks keep defaults. Under **Full Power**, set `DP_VIDEO → VPLL`, `DP_AUDIO` and `DP_STC → RPLL`,
and adjust the Interconnect block as shown in the tutorial. Leave the rest default.

### 4.5 DDR Configuration
In **DDR Configuration → Load DDR Presets**, select **`DDR4_MICRON_MT40A256M16GE_083E`**.
- AXU2CGA and AXU2CGB use slightly different settings (see tutorial pages 27–28).
- Click **OK** to finish, then connect the clocks as shown.

### 4.6 Generate and export
1. Right-click the block design → **Create HDL Wrapper…** → keep defaults → OK. (The PS now appears as a normal IP.)
2. Right-click the block design → **Generate Output Products** → **Generate** (produces IP, instantiation templates,
   RTL, XDC, etc.).
3. Menu **File → Export → Export Hardware…** → select **Fixed** → Next.
4. Because this example uses only the PS UART (no PL), **do NOT** check `Include bitstream` → Next.
5. Keep the default export name/path (the `.xsa` can live anywhere; Vivado and Vitis are independent) → Next → **Finish**.

The exported **`.xsa`** (in the project directory) contains the full hardware design and is handed to the software
engineer. **FPGA engineer's work is done here.**

---

## 5. Software Engineer — Create the Vitis Application

### 5.1 Launch Vitis
1. Create a new empty folder and copy the exported `xx.xsa` into it.
2. Open Vitis (either directly, or from Vivado: **Tools → Launch Vitis**). Select the folder you just made → **Launch**.

### 5.2 Create the Application Project
3. On the Vitis welcome screen click **Create Application Project** (this generates both an *Application* project and
   a *Platform* project — the Platform holds the hardware support files and BSP, replacing the old SDK "hardware
   platform").
4. Skip the intro page → **Next**.
5. Choose **Create a new platform from hardware (XSA)** → **Browse** → select the `.xsa` → Open.
6. **Generate boot components** is checked by default — keep it (auto-creates the FSBL project).
7. Enter the **Application project name** (e.g. `hello`) and pick the target processor (default is fine).
8. On the next page you can rename the Domain, choose OS, ARM architecture — keep defaults: OS = **standalone**
   (bare-metal).
9. Select the **"Hello World" template** → **Finish**.

### 5.3 What gets generated
- Two projects appear: the **Platform project** and the **Application project**.
- Expanding the Platform project shows the **BSP** and the **`zynq_fsbl`** project (result of "Generate boot
  components"). Double-click `platform.spr` to view/configure the BSP.
  - Unlike old SDK, a Platform can hold **multiple BSPs**: `zynqmp_fsbl` (FSBL's BSP) and
    `domain_psu_cortexa53_0` (the app's BSP).
- Expanding a BSP shows the peripheral drivers, **Documentation** (Xilinx driver docs), and **Import Examples**
  (Xilinx example projects to speed up learning).

---

## 6. Build, Run, and Debug over JTAG

1. Select the **Application project** → right-click **Build Project** (or click the hammer icon). Watch the Console;
   on success an **`.elf`** is produced.
2. Connect **JTAG** and the **UART-USB** cable to the board.
3. Open **PuTTY** → **Serial** → Serial line = your COM port (e.g. `COM3`), Speed = **115200** → Open.
4. **Before power-on**, set the board's boot-mode switch to **JTAG mode** (slide to "ON").
5. Power on the board.
6. Right-click the `hello` application → **Run As → Launch on Hardware (Single Application Debug)**.
7. Watch the serial terminal — it prints **`Hello World`**.

### Run/Debug configuration notes
- For reliable debugging, prefer **Run As → Run Configuration…**.
- **"Reset entire system"** is selected by default (differs from old SDK). If your design includes PL logic, you must
  also enable **"Program FPGA"**.
- Use **Debug As** instead of Run As to set breakpoints and single-step — the Debug perspective works like any
  standard C IDE; switch IDE modes from the top-right corner.

---

## 7. Solidifying the Program (Boot Images)

Plain FPGAs boot from flash or load passively. ZYNQ boot is **ARM-led** — the PS even loads the PL bitstream. Per UG1085,
ZYNQ MPSoC boot has three stages:

| Stage | Who runs | What happens |
|-------|----------|--------------|
| **Pre-configuration** | PMU | Runs PMU ROM code; handles all reset/wake sequencing |
| **Configuration** | BootROM → **FSBL** | BootROM copies FSBL to OCM; FSBL inits PS (MIO, PLL, DDR, QSPI, SD), loads PL bitstream if any, copies the app to DDR, and jumps to it |
| **Post-configuration** | CSU ROM | Ongoing secure services: file verification, PCAP PL load, key management, decryption |

**FSBL** (First-Stage Boot Loader) is the second-stage bootloader that initializes MIO/clocks/PLL/DDR/SD/QSPI,
optionally configures the FPGA, then loads and hands off to your application.

### 7.1 Generate the FSBL
1. Because you checked **Generate boot components**, the Platform already imported the FSBL project and built its
   `.elf`.
2. (Optional) Define `FSBL_DEBUG_INFO_VAL` to print FSBL status during boot — useful for debugging but slows boot.
   The FSBL contains many peripheral files (`psu_init.c`, qspi, sd, …) and is modifiable to your needs.
3. Re-**Build Project**.

### 7.2 Create BOOT.bin
Two ways:

- **Easy way:** right-click the application's **`system`** → **Build Project**. A `Debug/` folder appears containing
  `BOOT.BIN`.
- **Explicit way:** right-click `system` → **Create Boot Image**. The dialog shows the **BIF** (boot image config)
  path and the output `BOOT.bin` path. In **Boot image partitions** the order **must** be:
  1. **bootloader** = `fsbl.elf`
  2. **bitstream** = the `.bit` (omit for this PS-only example)
  3. **application** = `hello.elf`
  Click **Create Image**. Find `BOOT.bin` in the output directory.

---

## 8. SD Card Boot Test

1. Format the SD card as **FAT32** (other formats will not boot).
2. Copy `BOOT.bin` to the **root directory** of the SD card.
3. Insert the SD card into the board's SD slot.
4. Set the boot-mode switch to **SD card boot**.
5. Open the serial terminal and power on. You'll see the FSBL boot messages followed by your `Hello World` application
   output.

---

## 9. QSPI Flash Boot Test

1. In Vitis: **Xilinx → Program Flash**.
2. **Hardware Platform** = the latest; **Image File** = your `BOOT.bin`; **FSBL file** = `fsbl.elf`; check
   **Verify after flash**.
3. Click **Program** and wait for completion.
4. Set boot mode to **QSPI**, power cycle — the serial output matches the SD boot behavior.

### Alternative: program QSPI from Vivado Hardware Manager
1. In **Hardware Manager**, right-click the device → **Add Configuration Memory Device**.
2. Vendor **Micron**, type **qspi**, width **x4-single**, density **256** → select `wt25qu256`.
3. Right-click → select program file; choose the `BOOT.bin` and `fsbl`. Use **JTAG boot mode** when programming
   (the tool warns otherwise).

---

## 10. Batch-Script QSPI Programming

For repeated flashing, create `program_qspi.bat`:

```bat
call E:\XilinxVitis\Vitis\2020.1\bin\program_flash ^
  -f BOOT.bin -offset 0 -flash_type qspi-x4-single ^
  -fsbl fsbl.elf -verify
pause
```

Adjust the `program_flash` path to your install. Put `BOOT.bin`, `fsbl.elf`, and the `.bat` together, connect JTAG,
power the board, and double-click the `.bat` to flash.

> ALINX also ships a `vitis_image_download/` folder under `course_s2/` with a ready `program_qspi.bat` — just edit
> the `program_flash` path inside it, drop your `BOOT.bin` in, and double-click. JTAG mode is recommended.

---

## 11. Common Pitfalls & Tips

- **PL-only designs still need the PS.** To solidify a PL-only design (e.g. the LED "Hello World"), add the ZYNQ PS
  core as in this chapter, instantiate your Verilog source into the block design, generate a **bitstream**, then
  export hardware **with `Include bitstream` checked**. The `BOOT.BIN` partition order must be
  **fsbl → bitstream → app** — do not reverse it. ALINX provides a `led_qspi_sd` reference project.
- **Build smart to save time.** When you only edit source and recompile, **Build the Application project** — it
  produces just the `.elf`. Only **Build `system`** when you actually need a new `BOOT.BIN` (it regenerates both the
  elf and the boot image, which is slow). Building `system` every time wastes time.
- **Keep block-design names short** to avoid Windows path-length build errors.
- **Use JTAG boot mode when flashing QSPI** — the tools warn (or fail) otherwise.
- **All later chapters reuse this PS configuration** — the tutorial does not repeat the basic ZYNQ setup.

---

## 12. Quick Command Cheat-Sheet

| Goal | Action |
|------|--------|
| Export hardware for Vitis | Vivado: File → Export → Export Hardware (Fixed; check `Include bitstream` only if PL is used) |
| Open Vitis | Vivado: Tools → Launch Vitis (or launch Vitis directly) |
| Create app | Vitis: Create Application Project → from XSA → standalone → "Hello World" template |
| Build app only | Right-click Application project → Build Project (→ `.elf`) |
| Build boot image | Right-click `system` → Build Project (→ `.elf` + `BOOT.BIN`) |
| Run on hardware | Right-click app → Run As → Launch on Hardware (Single Application Debug) |
| Debug on hardware | Right-click app → Debug As → … (set breakpoints, single-step) |
| Program QSPI (GUI) | Vitis: Xilinx → Program Flash → BOOT.bin + fsbl.elf + Verify |
| Program QSPI (CLI) | `program_flash -f BOOT.bin -offset 0 -flash_type qspi-x4-single -fsbl fsbl.elf -verify` |
| SD boot | FAT32 SD card, copy `BOOT.bin` to root, set boot mode = SD, power on |
| QSPI boot | Flash `BOOT.bin` to QSPI, set boot mode = QSPI, power on |

---

### What this chapter establishes
This is the foundation for **every subsequent chapter** in the ALINX tutorial (PS peripherals, PS–PL interconnect via
EMIO/AXI GPIO, custom IP, dual-core AMP, FreeRTOS, etc.). Once you can build a Vivado hardware project, export the
`.xsa`, create a Vitis application, run it over JTAG, and produce a bootable `BOOT.bin`, you have the complete ZYNQ
PS/PL co-development workflow. The rest of the tutorial layers specific peripherals and PL accelerators on top of
this same flow.

---

*Translated from ALINX ZYNQ MPSoC Vitis Application Tutorial V1.06, Chapter 1. Last updated: 2026-11-16.*
