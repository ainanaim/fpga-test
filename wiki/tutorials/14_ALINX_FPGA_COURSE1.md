# 14 — ALINX ZYNQ MPSoC FPGA Tutorial (Course 1, Translated)

> A translated, condensed English guide based on **ALINX ZYNQ MPSoC Development Platform FPGA Tutorial V1.03**
> (Chinese, 174 pages, 16 chapters, author 梅士清, 2021-03-15).
> Source PDF: [`course_s1_ALINX_ZYNQ_MPSoC开发平台FPGA教程V1.03.pdf`](../../resources/tutorial(cn)/course_s1_ALINX_ZYNQ_MPSoC开发平台FPGA教程V1.03.pdf)
>
> This is **Course 1** — the PL/FPGA side. It assumes no prior FPGA experience and walks from the ZYNQ architecture
> through Verilog fundamentals, the Vivado tool flow, and a series of hands-on PL experiments (LED, PLL, RAM, ROM,
> FIFO, keys, PWM, UART/RS232/RS422/RS485, HDMI, LCD). It is the prerequisite to Course 2 (the Vitis/PS tutorial in
> [`13_VITIS_GETTING_STARTED.md`](./13_VITIS_GETTING_STARTED.md)).

---

## Table of Contents
1. [Chapter 1 — UltraScale+ MPSoC Introduction](#chapter-1--ultrascale-mpsoc-introduction)
2. [Chapter 2 — Board Hardware (AXU2CGA/B)](#chapter-2--board-hardware-axu2cgab)
3. [Chapter 3 — Verilog Building Blocks](#chapter-3--verilog-building-blocks)
4. [Chapter 4 — PL "Hello World" LED Experiment](#chapter-4--pl-hello-world-led-experiment)
5. [Chapter 5 — PLL Experiment](#chapter-5--pll-experiment)
6. [Chapter 6 — On-Chip RAM Read/Write](#chapter-6--on-chip-ram-readwrite)
7. [Chapter 7 — On-Chip ROM Test](#chapter-7--on-chip-rom-test)
8. [Chapter 8 — On-Chip FIFO Read/Write](#chapter-8--on-chip-fifo-readwrite)
9. [Chapter 9 — Key (Button) Experiment](#chapter-9--key-button-experiment)
10. [Chapter 10 — PWM Breathing LED](#chapter-10--pwm-breathing-led)
11. [Chapter 11 — RS232 UART Experiment](#chapter-11--rs232-uart-experiment)
12. [Chapter 12 — RS422 Experiment](#chapter-12--rs422-experiment)
13. [Chapter 13 — RS485 Experiment](#chapter-13--rs485-experiment)
14. [Chapter 14 — HDMI Output Experiment](#chapter-14--hdmi-output-experiment)
15. [Chapter 15 — HDMI Character Display](#chapter-15--hdmi-character-display)
16. [Chapter 16 — 7" LCD Display](#chapter-16--7-lcd-display)
17. [Appendix — Skills Required & Tool Flow](#appendix--skills-required--tool-flow)

---

## Chapter 1 — UltraScale+ MPSoC Introduction

The Zynq UltraScale+ MPSoC is Xilinx's second-generation Zynq — a single chip combining a complete **ARM
Processing System (PS)** with **Programmable Logic (PL)**. The PS is processor-centric and fully functional without
the PL: it contains quad/dual Cortex-A53, dual Cortex-R5, AMBA interconnect, OCM, DDR controller, and peripherals
(USB, Ethernet, SD/eMMC, I2C, CAN, UART, GPIO) plus high-speed interfaces (PCIe, SATA, DisplayPort).

- **PS** = Processing System = the ARM SoC portion (independent of FPGA).
- **PL** = Programmable Logic = the FPGA portion.

### PS–PL Interconnect (AXI)
PS and PL communicate via **AXI** (Advanced eXtensible Interface), part of ARM's AMBA bus. AXI uses a
VALID/READY handshake: data transfers only when both are high. ZYNQ supports three AXI variants:

| Interface | Characteristics | Use case |
|-----------|-----------------|----------|
| **AXI4-Lite** | Address / single-word transfer | Low-speed peripherals, control registers |
| **AXI4** | Address / burst transfer | Bulk memory-mapped transfers |
| **AXI4-Stream** | Data-only, no addresses (like a FIFO) | Video streams, DSP, comms |

AXI4 and AXI4-Lite are **memory-mapped** — the ARM reads/writes your custom IP as if it were RAM. AXI4-Stream
needs a converter (e.g. AXI-DMA) since it has no addresses. AXI4/AXI4-Lite have 5 channels: Read Address, Write
Address, Read Data, Write Data, Write Response.

### Physical AXI ports in the chip (12 total)
- **Master ports (PS is master)**: `M_AXI_HPM{0,1}_FPD`, `M_AXI_HPM0_LPD` — ARM uses these to read/write PL
  registers as memory.
- **Slave ports (PL is master)**: `S_AXI_HP{0:3}_FPD` (high-performance, PL→PS DDR), `S_AXI_LPD`,
  `S_AXI_HPC{0,1}_FPD`, `S_AXI_ACE_FPD`, `S_AXI_ACP_FPD`.

Most-used in practice: `S_AXI_HP{0:3}_FPD`, `M_AXI_HPM{0,1}_FPD`, `M_AXI_HPM0_LPD`.

### Common AXI IP cores (drop in from Vivado IP catalog)
| IP | Function |
|----|----------|
| **AXI-DMA** | PS DDR ↔ PL via AXI-HP ↔ AXI-Stream |
| **AXI-FIFO-MM2S** | PS DDR ↔ PL via AXI-HPM ↔ AXI-Stream |
| **AXI-Datamover** | Like AXI-DMA but PL-controlled (PS passive) |
| **AXI-VDMA** | 2D video/frame DMA |
| **AXI-CDMA** | Central DMA, memory-to-memory (no CPU) |
| **AXI Interconnect** | Switch matrix connecting N masters ↔ M slaves (up to 16×16) |

> You rarely need to write AXI timing by hand — Xilinx wraps it. You just add IP and connect.

### ZYNQ development flow (hardware-first, then software)
1. Vivado: new project, add embedded source.
2. Configure PS peripherals + add custom PL IP.
3. Generate top HDL, add constraints, synthesize → bitstream (`.bit`).
4. Export hardware info (`.xsa`) to Vitis/SDK.
5. In Vitis: write FSBL, application; debug.
6. (For Linux) Build u-boot, kernel, device tree, rootfs in a VM.
7. Combine FSBL + bitstream + u-boot → `BOOT.bin`.
8. Put `BOOT.bin`, kernel, device tree, rootfs on SD card → boot.

ZYNQ can also be used as a pure ARM (ignore PL) or pure FPGA (but PL config still requires PS — you can't
flash a PL-only bitstream to QSPI without the PS).

---

## Chapter 2 — Board Hardware (AXU2CGA/B)

Small form-factor board built on **XCZU2CG-1SFVC784E** (Zynq UltraScale+ ZU2CG, speed grade -1, commercial,
SFVC784 package).

### PS resources (XCZU2CG)
- Dual Cortex-A53 @ 1.2 GHz (32 KB L1 each, 1 MB shared L2).
- Dual Cortex-R5 @ 500 MHz (32 KB L1 + 128 KB TCM each).
- DDR4/3/3L, LPDDR4/3 (32/64-bit); NAND, 2× Quad-SPI Flash.
- PCIe Gen2 ×4, 2× USB3.0, SATA 3.1, DisplayPort, 4× tri-mode GbE.
- 2× USB2.0, 2× SD/SDIO, 2× UART, 2× CAN, 2× I2C, 2× SPI, 4× 32-bit GPIO.
- Power management (Full/Low/PL/Battery domains); RSA/AES/SHA crypto; 10-bit 1 Mbps ADC for temp/voltage.

### PL resources (XCZU2CG)
- 154K Logic Cells, 141K flip-flops, 71K LUTs.
- 9.4 Mb Block RAM, 3 CMTs (clock management tiles), 360 × 18×25 MACCs (DSP).

### On-board peripherals
| Peripheral | Details |
|------------|---------|
| **DDR4** | AXU2CGA: 2× Micron = 1 GB, 32-bit. AXU2CGB: 4× = 2 GB, 64-bit. Up to 1200 MHz (2400 Mbps). |
| **QSPI Flash** | 256 Mb MT25QU256ABA1EW9-0SIT, on PS BANK500. |
| **eMMC** | 8 GB, AXU2CGB only, on PS BANK500. |
| **EEPROM** | 24LC04, on PS MIO (I2C1). |
| **DisplayPort** | Mini-DP, up to 4K×2K@30 fps, PS MGT Lane0/1 TX, aux via MIO 27–30. |
| **USB** | 4× USB3.0 Type-A HOST, via USB PHY + HUB, PS BANK502 + MGT Lane1. |
| **Ethernet** | 1× GbE, Micrel KSZ9031RNX PHY, PS BANK502 (GEM3). |
| **USB-UART** | CP2102, mini-USB, PS UART1 (MIO 24/25). |
| **SD card** | Micro-SD, PS BANK501 (SD1). |
| **PCIe** | ×1 slot, 5 Gbps, PS MGT Lane0. |
| **40-pin headers** | 2× (J12: BANK66, 1.8 V; J15: BANK25/26, 3.3 V). Each has 34 IO + power/gnd. |
| **MIPI** | 2× MIPI camera ports, BANK64/65 HP IO (1.2 V diff), control on BANK24 (3.3 V). |
| **JTAG** | 10-pin, for download/flash. |
| **LEDs** | 4× red user LEDs on BANK25 (high = off, low = on). |
| **Keys** | 4× user buttons + reset, on BANK24. |
| **Clocks** | RTC 32.768 kHz, PS 33.333 MHz, PL 25 MHz (BANK44, 1.8 V). |
| **Fan** | 12 V, PWM speed control. |
| **Power** | DC 12 V / 2 A adapter. |

### Boot mode switch (SW1, positions 4-3-2-1)
| Switches | MODE[3:0] | Boot mode |
|----------|-----------|-----------|
| ON,ON,ON,ON | 0000 | PS JTAG |
| ON,ON,OFF,ON | 0010 | QSPI Flash |
| ON,OFF,ON,OFF | 0101 | SD card |
| ON,OFF,OFF,ON | 0110 | eMMC |

> "ON" = 0. Use JTAG mode when downloading/debugging or flashing QSPI.

---

## Chapter 3 — Verilog Building Blocks

A condensed reference of the Verilog primitives used throughout the course. Each block below is shown with
synthesizable code + a typical testbench pattern.

### 3.1 Data types
- **Constants**: `8'b0000_1111` (8-bit binary), `4'ha` (4-bit hex). `x` = unknown, `z` = high-impedance.
  Underscores improve readability. `parameter` defines module-level constants (overridable on instantiation via
  `#(...)`); `localparam` is module-local (used for FSM states).
- **`wire`**: net type, physical connection, driven by `assign`, cannot store value.
- **`reg`**: register type, used in `always` blocks; can synthesize to a flip-flop (if clocked) or combinational
  logic (if not).
- **Memory**: `reg [7:0] ram [255:0]` = 256 words × 8 bits.

### 3.2 Operators
Arithmetic `+ - * / %`, assignment `=` (blocking) / `<=` (non-blocking), relational `> < >= <= == !=`,
logical `&& || !`, conditional `?:`, bitwise `~ | ^ & ^~`, shift `<< >>`, concatenation `{ }`.

> **Blocking vs non-blocking**: use `<=` (non-blocking) in sequential (clocked) logic to avoid races; use `=`
> (blocking) in combinational `always` and in `assign`. They produce visibly different RTL — blocking chains
> assignments in order, non-blocking evaluates all RHS first then assigns in parallel.

### 3.3 Combinational logic examples

**AND gate** — `assign c = a & b;`
**OR gate** — `assign c = a | b;`
**NOT gate** — `assign b = ~a;`
**XOR gate** — `assign c = a ^ b;`
**Comparator (greater-than)** — `assign c = a > b;`
**Half adder** — `assign sum = a ^ b; assign count = a & b;`
**Full adder** — `assign {count, sum} = a + b + cin;`
**Multiplier** — `assign c = a * b;` (width = sum of input widths)
**4:1 MUX** — `case(sel)` inside `always @(*)`:
```verilog
always @(sel or a or b or c or d) begin
  case(sel)
    2'b00: Mux = a; 2'b01: Mux = b;
    2'b10: Mux = c; 2'b11: Mux = d;
  endcase
end
```
**3-to-8 decoder** — `case(addr)` mapping 3-bit input to one-hot 8-bit output.
**Tri-state (bidirectional IO)** — `assign bio = en ? din : 1'bz; assign dout = bio;`

### 3.4 Sequential logic examples

**D flip-flop**:
```verilog
always @(posedge clk) q <= d;
```
**Two-stage D flip-flop** (q1 lags q by one clock — this is the model Vivado uses for timing analysis):
```verilog
always @(posedge clk) q  <= d;
always @(posedge clk) q1 <= q;
```
**Async-reset D flip-flop** (reset in sensitivity list; `negedge` for active-low reset):
```verilog
always @(posedge clk or negedge rst) begin
  if (!rst) q <= 0; else q <= d;
end
```
**Async-reset + sync-clear D flip-flop** (clear NOT in sensitivity list — sampled on clock):
```verilog
always @(posedge clk or negedge rst) begin
  if (!rst)       q <= 0;
  else if (clr)   q <= 0;
  else            q <= d;
end
```
**Shift register** (left shift; for right shift use `{d, q[7:1]}`):
```verilog
always @(posedge clk or negedge rst) begin
  if (!rst) q <= 0;
  else      q <= {q[6:0], d};
end
```
**Single-port RAM** (write on Port A, read via registered address — data out one cycle later):
```verilog
reg [7:0] ram [63:0]; reg [5:0] addr_reg;
always @(posedge clk) begin
  if (wr) ram[addr] <= data;
  addr_reg <= addr;
end
assign q = ram[addr_reg];
```
**Simple (pseudo) dual-port RAM** — separate read/write addresses, simultaneous R/W:
```verilog
always @(posedge clk) begin
  if (wr) ram[write_addr] <= data;
  if (rd) q <= ram[read_addr];
end
```
**True dual-port RAM** — two independent ports (A and B), each can read or write.
**Single-port ROM** — initialized via `case(addr)` (small) or via IP core + `.coe` file (large):
```verilog
always @(posedge clk) begin
  case(addr)
    4'd0: q <= 8'd15; 4'd1: q <= 8'd24; /* ... */ 4'd15: q <= 8'd67;
    default: q <= 8'd0;
  endcase
end
```

### 3.5 Finite state machines (FSM)
Two styles shown:

**Mealy (1-process)** — output depends on state AND input; everything in one `always`:
```verilog
parameter Idle=0, Start=1, Run=2, Stop=3;
always @(posedge clk or negedge rst) begin
  if (!rst) begin state<=Idle; delay_cnt<=0; q<=0; end
  else case(state)
    Idle:  if (shift_start) state <= Start;
    Start: if (delay_cnt==99) begin delay_cnt<=0; state<=Run; end
           else delay_cnt <= delay_cnt + 1;
    Run:   if (shift_stop) state <= Stop;
           else q <= {q[6:0], d};
    Stop:  begin q <= 0; state <= Idle; end
  endcase
end
```
**Moore (3-process)** — output depends only on state; cleaner for many states. Three `always` blocks:
1. State register: `current_state <= next_state` (clocked).
2. Next-state logic: combinational `always @(*)` with `case(current_state)`.
3. Output logic: clocked, depends only on `current_state`.

### 3.6 Standard testbench skeleton
```verilog
`timescale 1 ns / 1 ns
module top_tb;
  reg a, b, clk; wire c;
  initial begin a=0; b=0; clk=0; forever begin #({$random}%100) a=~a; #({$random}%100) b=~b; end end
  always #10 clk = ~clk;
  top t0(.a(a), .b(b), .c(c), .clk(clk));
endmodule
```

---

## Chapter 4 — PL "Hello World" LED Experiment

Project: `led`. Blink 4 LEDs once per second using the 25 MHz PL clock. This chapter teaches the **full Vivado
flow** that every later chapter reuses.

### 4.1 Hardware
4 red LEDs on PL BANK25 (high = off, low = on). Reset on a PL key (active-low).

### 4.2 Create the Vivado project
1. Launch Vivado → **Create New Project**.
2. Project name `led`, path with **no Chinese/spaces, not too long**.
3. Type = **RTL Project**, target language = **Verilog** (VHDL also supported, mixed OK).
4. Part: Family `Zynq UltraScale+ MPSoCs`, Package `sfvc784`, Speed `-1`, Temp `E` → select
   `xczu2cg-sfvc784-1-e`.

### 4.3 Write the Verilog
**Add Sources → Add or create design sources → Create File** `led.v`. The design:
```verilog
module led(
    input sys_clk,
    input rst_n,
    output reg [3:0] led
);
reg [31:0] timer_cnt;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        led <= 4'd0;
        timer_cnt <= 32'd0;
    end
    else if (timer_cnt >= 32'd24_999_999) begin   // 25 MHz → 1 s
        led <= ~led;
        timer_cnt <= 32'd0;
    end
    else begin
        led <= led;
        timer_cnt <= timer_cnt + 32'd1;
    end
end
endmodule
```

### 4.4 Pin constraints (XDC)
**Open Elaborated Design** → **Window → I/O Ports** → assign package pins + IOSTANDARD (LEDs are LVCMOS33 since
BANK25 is 3.3 V) → save as `led.xdc`. Or write XDC directly:
```tcl
set_property PACKAGE_PIN <pin>     [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33    [get_ports {led[0]}]
# ... repeat for led[1..3], sys_clk, rst_n
```
> PS pins (named `PS_MIO...` in the schematic) are NOT bound in XDC — only PL pins are.

### 4.5 Timing constraints
**Run Synthesis** → **Constraints Wizard** → set `sys_clk` to 25 MHz (40 ns period) → **Skip to Finish**. This
updates `led.xdc` with a `create_clock` entry.

### 4.6 Generate bitstream
**Generate Bitstream** (runs synthesis + implementation + bitstream generation). Watch the status indicator;
antivirus software can block the build.

### 4.7 Simulation (behavioral)

You **must** have a testbench (`*_tb.v`) to simulate. Without it, Vivado has nothing to drive `sys_clk` and `rst_n`, so the waveform is just flat lines.

#### 4.7.1 Why the waveform is empty without a testbench

When you click **Run Simulation** with only `led.v` in the project:
- Vivado looks for a top-level simulation source.
- If there's no testbench, it may try to simulate `led.v` directly — but `led.v` has `input sys_clk` and `input rst_n` that nobody is driving.
- With no clock toggling, `timer_cnt` never increments, `led` never toggles, the waveform is flat lines.

#### 4.7.2 Create the testbench file

1. In the **Sources** panel (left side), right-click **Simulation Sources** → **Add Sources**.
2. Select **Add or create simulation sources** → Next.
3. Click **Create File** → name it `vtf_led_test` → set file type to **Verilog** → OK → Finish.

#### 4.7.3 Write the testbench

Open `vtf_led_test.v` and paste:

```verilog
`timescale 1 ns / 1 ps

module vtf_led_test;

    // Inputs to the DUT (Device Under Test)
    reg  sys_clk;
    reg  rst_n;

    // Output from the DUT
    wire [3:0] led;

    // Instantiate the led module
    led uut (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .led     (led)
    );

    // Generate a 25 MHz clock (40 ns period = 20 ns half period)
    initial begin
        sys_clk = 1'b0;
        forever #20 sys_clk = ~sys_clk;   // toggles every 20 ns
    end

    // Reset sequence
    initial begin
        rst_n = 1'b0;          // assert reset (active-low)
        #1000;                 // hold reset for 1000 ns
        rst_n = 1'b1;          // release reset
    end

endmodule
```

> The `always #20 sys_clk = ~sys_clk;` line creates a 50 MHz clock in simulation (20 ns half period). The real board clock is 25 MHz (40 ns period). For logic verification this doesn't matter — the counter still counts to 24999999 and toggles. If you want the simulation to match real time exactly, use `#40` instead of `#20`.

#### 4.7.4 Set the testbench as the simulation top

1. In the Sources panel, under **Simulation Sources → sim_1**, find `vtf_led_test.v`.
2. Right-click it → **Set as Top** (if not already set automatically).
3. The testbench should now be the top-level for simulation, not `led.v`.

#### 4.7.5 Run the simulation

1. Click **Run Simulation → Run Behavioral Simulation**.
2. XSim opens with the waveform window.
3. You'll see `sys_clk` toggling, `rst_n` going high after 1000 ns, and `led` + `timer_cnt` (if you add it).

#### 4.7.6 Add signals to the waveform

If `timer_cnt` isn't visible:
1. In the **Scope** panel (left side of XSim), expand `vtf_led_test → uut (led)`.
2. Drag `timer_cnt` into the waveform window.
3. Right-click it → **Radix → Unsigned** (so it shows as a number, not hex).
4. Click **Restart** (the circular arrow icon).
5. Click **Run All** (or set a specific time).

#### 4.7.7 What you should see

| Time (sim) | What happens |
|------------|--------------|
| 0 ns | `sys_clk` starts toggling, `rst_n = 0` (reset held) |
| 1000 ns | `rst_n = 1` (reset released), `timer_cnt` starts counting from 0 |
| ~1 s | `timer_cnt` reaches 24999999, `led` toggles to `0xf` |
| ~2 s | `timer_cnt` reaches 24999999 again, `led` toggles to `0x0` |

#### 4.7.8 The catch — simulation time

Your counter counts to 24999999 at 25 MHz. That's **1 second of real time**. In simulation, 1 second = 25 million clock cycles = 25,000,000 × 40 ns = **1 second of simulation time**. XSim will take a while to simulate that many cycles.

**To see results faster — reduce the counter for simulation.** Temporarily change the counter in `led.v` from `24999999` to `249` (or even `24`) just for simulation:

```verilog
// For simulation only — change back to 24999999 for real hardware
else if(timer_cnt >= 32'd249)   // 10 microseconds at 25 MHz
```

Now `led` toggles every 10 microseconds of simulation time — you'll see it instantly. Change it back to `24999999` before generating the bitstream for the real board.

#### 4.7.9 Better — use a parameter so you don't modify led.v

If your `led.v` uses a parameter for the counter max:

```verilog
module led #(parameter MAX = 24999999) (
    input sys_clk,
    input rst_n,
    output reg [3:0] led
);
    reg [31:0] timer_cnt;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            led <= 4'd0;
            timer_cnt <= 32'd0;
        end
        else if (timer_cnt >= MAX) begin
            led <= ~led;
            timer_cnt <= 32'd0;
        end
        else begin
            led <= led;
            timer_cnt <= timer_cnt + 32'd1;
        end
    end
endmodule
```

Then in the testbench, override the parameter:

```verilog
led #(.MAX(249)) uut (   // 10 us toggle for fast simulation
    .sys_clk (sys_clk),
    .rst_n   (rst_n),
    .led     (led)
);
```

This way you don't modify `led.v` — the testbench sets a small `MAX` for simulation, and the real hardware uses the default `24999999`.

### 4.8 Download via JTAG
1. Connect JTAG, power on, set boot-mode switch to **JTAG** (all ON).
2. **Hardware Manager → Auto Connect** (scans ARM + FPGA cores).
3. Select the FPGA → **Program Device → Program**.
4. The 4 PL LEDs now blink once per second.

> A PL-only project **cannot** be flashed to QSPI directly — the PS must be involved (see Course 2, Ch.1 FAQ).

### 4.9 Online debug with ILA (integrated logic analyzer)
Two methods:

**Method A — Add ILA IP:**
1. **IP Catalog → search `ila`** → set name `ila`, number of probes = 2, sample depth as needed.
2. Probe widths: PROBE0 = 32 (for `timer_cnt`), PROBE1 = 4 (for `led`). Generate.
3. Instantiate `ila` in `led.v`, connect probes. Rebuild, download.
4. In Hardware Manager, run; set a trigger (e.g. `timer_cnt == 24999999`, radix = unsigned) and capture.

**Method B — MARK_DEBUG attribute:**
1. Comment out the ILA instantiation. Add `(* MARK_DEBUG = "true" *)` before `led` and `timer_cnt` declarations.
2. Run synthesis → **Set Up Debug** wizard → accept defaults → finish → save (writes ILA constraints to XDC).
3. Rebuild bitstream, download, debug as above.

---

## Chapter 5 — PLL Experiment

Project: `pll_test`. Demonstrates the on-chip PLL (Clocking Wizard IP) to generate 200/100/50/25 MHz from the
25 MHz input.

### Principle
UltraScale+ uses **CMTs** (Clock Management Tiles), each containing an **MMCM** and a **PLL**. MMCM does
frequency synthesis + deskew + jitter filtering + phase shift; PLL does frequency synthesis only (no deskew,
limited phase/divider range). See Xilinx *7 Series FPGAs Clocking Resources User Guide* (ug572).

> Gotcha: the 25 MHz `PL_REF_CLK` is on BANK44, an **HDGC** pin. Per ug572, HDGC pins **cannot** connect
> directly to MMCM/PLL — they must go through a **BUFG** first.

### Steps
1. New project `pll_test`. **IP Catalog → Clocking Wizard**.
2. **Clocking Options**: input 25 MHz, **No buffer** (we add BUFG externally).
3. **Output Clocks**: enable clk_out1–4 = 200/100/50/25 MHz, default phase. OK → Generate.
4. Top module `pll_test.v`:
```verilog
module pll_test(
  input sys_clk, input rst_n, output clk_out
);
  wire locked, sys_clkbuf;
  BUFG BUFG_inst(.O(sys_clkbuf), .I(sys_clk));
  clk_wiz_0 clk_wiz_0_inst(
    .clk_in1(sys_clkbuf),
    .clk_out1(), .clk_out2(), .clk_out3(),
    .clk_out4(clk_out),
    .reset(~rst_n),     // PLL reset is ACTIVE-HIGH; button is active-low → invert
    .locked(locked)
  );
endmodule
```
5. XDC: `sys_clk` AB11/LVCMOS33 + `create_clock -period 40`; `rst_n` AA13; `clk_out` A11.
6. Build, download, probe `clk_out` on J15 pin 3 (gnd on pin 1) with an oscilloscope → 25 MHz, 3.3 V, 50% duty.

> PLL reset is **active-high** — a common newbie mistake. Not every frequency is exactly synthesizable; the
> wizard auto-approximates. Low-bandwidth scopes may attenuate high-frequency amplitudes.

---

## Chapter 6 — On-Chip RAM Read/Write

Project: `ram_test`. Uses the **Block Memory Generator** IP configured as **Simple Dual-Port RAM** (the most
common type — independent read/write ports).

### IP config
- **Basic**: Memory Type = `Simple Dual Port RAM`.
- **Port A**: Width 16, Depth 512, Enable = Always Enable.
- **Port B**: Width 16, Enable = Always Enable, **uncheck** Primitives Output Register (otherwise data lags
  address by 2 cycles instead of 1).

### Port definitions
| Signal | Dir | Description |
|--------|-----|-------------|
| `clka`, `wea`, `addra`, `dina` | in | Port A: clock, write-enable, address, data |
| `clkb`, `addrb` | in | Port B: clock, read address |
| `doutb` | out | Port B: read data (one cycle after address) |

### Test design
Write 512 sequential values (1..512) once into Port A; continuously read Port B with a free-running address.
Instantiate `ila` on Port B's `r_data`/`r_addr` to observe. Key logic:
```verilog
// Write enable: assert until 512 writes done, then stop
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) wea <= 0;
  else if (&w_addr) wea <= 0;   // all bits of w_addr = 1 → 512 written
  else wea <= 1;
end
// Write address + data increment while wea
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin w_addr<=0; w_data<=1; end
  else if (wea) begin w_addr<=w_addr+1; w_data<=w_data+1; end
end
// Free-running read address
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) r_addr <= 0;
  else if (|w_addr) r_addr <= r_addr + 1;   // start reading once writing has begun
end
```
**Result (ILA)**: `r_addr` sweeps 0→1ff; `r_data` follows, lagging the address by 2 clocks (matches sim).

---

## Chapter 7 — On-Chip ROM Test

Project: `rom_test`. FPGA is SRAM-based (volatile), so "ROM" is really RAM preloaded at power-up.

### 7.1 Create the init file `rom_init.coe`
Format:
```
memory_initialization_radix=16;
memory_initialization_vector=
00, 01, 02, ... , 1f;
```
- Line 1: radix (16 = hex).
- Lines 3+: data values, comma-separated, semicolon-terminated. Here 32 × 8-bit values.

### 7.2 Add ROM IP
**Block Memory Generator** → Basic: `Single Port ROM`. Port A: Width 8, Depth 32, Enable = Always, uncheck
Primitives Output Register. **Other Options → Load Init File → Browse** → select `rom_init.coe`. Generate.

### 7.3 Test design
Free-running 5-bit address; ROM outputs the preloaded data; `ila` observes `rom_addr`/`rom_data`. Data lags
address by one cycle (same as RAM read).

---

## Chapter 8 — On-Chip FIFO Read/Write

Project: `fifo_test`. Asynchronous FIFO: write clock 100 MHz, read clock 75 MHz (write faster → FIFO fills).

### 8.1 FIFO IP config
**FIFO Generator** → **Independent Clocks Block RAM** (async). Native Ports: data width 16, depth 512, Read Mode
= **Standard FIFO** (data lags `rd_en` by 1 cycle; FWFT mode would pre-fetch). Data Counts: enable both Write
and Read Data Count. Generate.

### 8.2 Port definitions
`rst` (active-high), `wr_clk`, `rd_clk`, `din`, `wr_en`, `rd_en`, `dout`, `full`, `empty`, `rd_data_count`,
`wr_data_count`.

### 8.3 Design notes
- Use the PLL `locked` signal as the FIFO reset (so FIFO only releases reset after clocks are stable).
- The FIFO defaults to **safety circuit** mode: after async reset, you must wait **60 cycles of the slowest
  clock** before operating. With 75 MHz slowest and 100 MHz write: write side waits ~80 cycles, read side waits
  60 cycles before entering the W_FIFO / R_FIFO states.
- Write FSM: `W_IDLE` (wait 80 cycles) → `W_FIFO` (write while `~full`).
- Read FSM: `R_IDLE` (wait 60 cycles) → `R_FIFO` (read while `~empty`).
- Two ILAs: one on the write channel (`w_data`, `wr_en`, `full`, `wr_data_count`), one on the read channel
  (`r_data`, `rd_en`, `empty`, `rd_data_count`).

### 8.4 Result
- When `full` asserts, `wr_en` goes low (stops writing).
- Standard FIFO: `dout` valid one cycle after `rd_en`. Switch to **FWFT** mode and `dout` is valid in the same
  cycle as `rd_en`.
- Swap read/write clocks and you'll see the FIFO empty out instead.

---

## Chapter 9 — Key (Button) Experiment

Project: `key_test`. Buttons are high when released, low when pressed. LEDs are off when high, on when low.

### Design
Pass each button through an inverter, then through **two stages of D flip-flops** (synchronizer). The LED output
mirrors the registered button value:
```verilog
module key_test(
  input clk, input [3:0] key, output [3:0] led
);
  reg [3:0] led_r, led_r1;
  always @(posedge clk) led_r  <= key;   // stage 1
  always @(posedge clk) led_r1 <= led_r; // stage 2
  assign led = led_r1;
endmodule
```
Use **RTL ANALYSIS** to view the synthesized schematic — confirms two D-FF stages. On the board: LEDs are on by
default; pressing PL KEY1 turns PL LED1 off.

> This is the classic metastability / synchronizer pattern — two D-FF stages bring the probability of
> metastability to a negligible level for a single asynchronous input.

---

## Chapter 10 — PWM Breathing LED

Project: `pwm_led`. An N-bit counter increments by `period` each clock; output is high when
`period_cnt >= duty`, else low. Varying `duty` changes the duty cycle → LED brightness; sweeping `duty` up and
down creates a "breathing" effect.

### PWM module `ax_pwm.v` (parameterized)
```verilog
module ax_pwm #(parameter N = 16) (
  input clk, input rst,
  input [N-1:0] period, input [N-1:0] duty,
  output pwm_out
);
  reg [N-1:0] period_r, duty_r, period_cnt; reg pwm_r;
  assign pwm_out = pwm_r;
  always @(posedge clk or posedge rst) begin
    if (rst) begin period_r<=0; duty_r<=0; end
    else      begin period_r<=period; duty_r<=duty; end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) period_cnt <= 0;
    else     period_cnt <= period_cnt + period_r;   // step = period
  end
  always @(posedge clk or posedge rst) begin
    if (rst) pwm_r <= 0;
    else     pwm_r <= (period_cnt >= duty_r);
  end
endmodule
```
- `period` sets PWM frequency: `period = f_pwm × 2^N / f_clk`.
- `duty` sets duty cycle: `duty / 2^N × 100%`.

### Breathing effect
A small FSM ramps `duty` up by `DUTY_STEP` until near max, then ramps down until near min, repeating with a
100 µs gap between steps. PWM frequency set to 200 Hz (`period = 17179` for 25 MHz, N=32). LED = `~pwm_out`
(active-low LED). Result: PL LED1 smoothly breathes.

> PWM is widely reused — fan speed, motor speed, LED dimming, etc.

---

## Chapter 11 — RS232 UART Experiment

Project: `rs232_test`. Uses the **AN3485** module (RS232/485/422 board) with a MAX3232 level shifter. The FPGA
sends `"HELLO ALINX\r\n"` once per second and echoes any received byte.

### 11.1 UART protocol
Frame: 1 start bit (low), 7–8 data bits (LSB first), optional parity, 1+ stop bits (high). Idle line is high.
A falling edge signals a start bit. Common baud rates: 2400, 9600, 115200. Bit time = 1 / baud_rate. Here
generated from 50 MHz (note: tutorial uses 50 MHz in this chapter; the 25 MHz PL clock would need a PLL or
different `CLK_FRE`).

### 11.2 Receiver `uart_rx.v` (parameterized FSM)
Parameters: `CLK_FRE` (system clock in MHz), `BAUD_RATE`. States: `S_IDLE → S_START → S_REC_BYTE → S_STOP → S_DATA`.
- Detect falling edge on `rx_pin` → start.
- Sample each data bit at the **midpoint** of the bit period (`cycle_cnt == CYCLE/2 - 1`) for noise margin.
- `S_STOP` waits only **half** a bit period so it can catch the next start bit.
- Handshake: `rx_data_valid` + `rx_data_ready` (both high → data consumed).

### 11.3 Transmitter `uart_tx.v` (parameterized FSM)
States: `S_IDLE → S_START → S_SEND_BYTE → S_STOP`. Drives `tx_reg` per state (idle/stop = 1, start = 0, data =
`tx_data_latch[bit_cnt]`). Same VALID/READY handshake as the receiver.

### 11.4 Top test program
- FSM: `IDLE → SEND` (transmit 12 bytes `"HELLO ALINX\r\n"`) `→ WAIT` (1 s; if `rx_data_valid`, echo `rx_data`
  back via the transmitter).
- Instantiate `uart_rx` and `uart_tx` with `BAUD_RATE = 115200`.

### 11.5 Test
Plug AN3485 into J11. Connect via USB-RS232 adapter to a PC COM port (e.g. COM5). Open a serial terminal at
115200/8/N/1. The board prints `HELLO ALINX` every second; typing characters echoes them back.

---

## Chapter 12 — RS422 Experiment

Project: `rs422_test`. RS422 is differential (4 wires: TX+/TX- = Y/Z, RX+/RX- = A/B), full-duplex, up to 500 kbps.
Uses MAX3490. The FPGA interface is identical to RS232 (TXD/RXD), so the design simply **instantiates two
`uart_test` channels** connected to the two RS422 transceivers on the AN3485 module. Test: connect Y/Z to the
adapter's R+/R- and A/B to T+/T-; same serial behavior as RS232.

---

## Chapter 13 — RS485 Experiment

Project: `rs485_test`. RS485 is differential (A/B only), **half-duplex** — only one direction at a time. FPGA
interface adds a direction signal `DE` (drive enable) alongside `DI` (TXD) and `RO` (RXD). MAX3485: when `DE=1`
the chip drives A/B; when `DE=0` it receives.

### Protocol
Frame format: `0x55 (start) + length (1 byte, 1–255) + data`. The FPGA starts in receive (`DE=0`), buffers
received data into a 256-deep FIFO (excluding the 0x55 and length bytes), then switches `DE=1` and transmits
the FIFO contents back. A 1 ms `WAIT` state ensures the bus direction switch is stable.

### FSM states
`IDLE → RCV_HEAD` (check for `0x55`) `→ RCV_COUNT` (read length) `→ RCV_DATA` (write FIFO, then flip DE) `→ WAIT`
(1 ms) `→ SEND` (read FIFO, transmit) `→ SEND_WAIT` (until done) `→ IDLE`.

### Test
USB-RS485 adapter, A/B to module A/B. Send hex `55 03 01 02 03` → board echoes `01 02 03`.

---

## Chapter 14 — HDMI Output Experiment

Project: `hdmi_out_test`. The board has no PL HDMI, so the **AN9134** HDMI expansion module (SiL9134) is used on
J15. The SiL9134 encodes 24-bit RGB into TMDS differential pairs; it must be configured via I2C.

### Architecture
```
sys_clk → video_pll (Clocking Wizard) → 100 MHz + 148.5 MHz (1080p pixel clock)
        → color_bar.v  → R/G/B (8b each) + HS/VS/DE
        → SiL9134 (via TMDS)
i2c_config.v ← lut_si9134.v (register lookup table) → SCL/SDA to SiL9134
```
- **`color_bar.v`**: generates 8-color VGA bars (white, yellow, cyan, green, magenta, red, blue, black) at
  **1920×1080@60 Hz** (1080p). Outputs RGB + HSYNC/VSYNC/DE.
- **`video_pll`**: Clocking Wizard IP → 100 MHz + 148.5 MHz pixel clock from the 25 MHz input.
- **`i2c_config.v`**: I2C master that writes the SiL9134 register sequence from `lut_si9134.v` at boot.

### Test
Connect AN9134 to J15, HDMI to a **1080p-capable** monitor. Download → color bars appear.

> The tutorial notes I2C config is better done from the PS in real designs — this is a pure-PL demo.

---

## Chapter 15 — HDMI Character Display

Project: `hdmi_char`. Overlays text on the color-bar background using a ROM-stored font.

### Approach
1. Use the **"FPGA 字模提取" (font extraction) tool** (in the project folder) to convert a string into a
   `.coe` file. Set font, height (e.g. 144×32), save as `osd.coe` (Xilinx type).
2. Instantiate a **Single Port ROM** IP, width 8, depth = (144 × 32) / 8, loaded with `osd.coe`.
3. **`osd_display.v`** module contains `timing_gen_xy` (generates x/y counters from HS/VS/DE) and `osd_rom`.
   - Define an OSD region (start at (9,9), size = font box).
   - Inside the region: read ROM. ROM address is `[15:3]` — **8 pixel columns per ROM byte** (1 bit/pixel), so
     one ROM read supplies 8 horizontal pixels.
   - If the font bit = 1 → output foreground red ("ALINX 芯驿"); if 0 → output the background color bar.
4. Position is adjustable via `pos_x`/`pos_y` comparisons.

### Result
Display shows color bars with red "ALINX" text overlaid at (9,9). Don't connect to a laptop HDMI port (it's an
output too) — use a monitor/TV.

---

## Chapter 16 — 7" LCD Display

Project: `lcd7-test`. Uses the **AN970** 7" capacitive-touch TFT (800×480) on J15. Simpler than HDMI: **no I2C
config needed**, direct RGB output.

### Changes from HDMI
- Edit `video_define.v` macros for **800×480** timing.
- PLL output → **33 MHz** pixel clock (800×480).
- `top.v` instantiates `ax_pwm` (200 Hz, 30% duty) to drive the LCD backlight brightness.

### Result
Color bars on the 7" LCD. A character-display variant is also provided.

---

## Appendix — Skills Required & Tool Flow

### Skills for learning ZYNQ
**Software developers**: computer architecture, C/C++, operating systems, Tcl scripting, English reading.
**Logic developers**: computer architecture, C, digital circuit fundamentals.

### Tools
- **Vivado**: FPGA design — RTL, pin/timing constraints, synthesis, implementation, simulation, bitstream.
  Replaces ISE (Project Navigator, XST, CORE Generator, Chipscope, FPGA Editor, etc.).
- **Vitis/SDK**: ARM software — drivers for all Xilinx IP, BSP, C/C++ app dev/debug, FSBL generation. Co-debug
  of FPGA IP + processor software. (Vivado 2020.1+ bundles Vitis; older versions bundle SDK.)

### The recurring PL workflow (memorize this)
```
New Project (RTL, Verilog, xczu2cg-sfvc784-1-e)
  → Add design source (.v)
  → Add simulation source (_tb.v)
  → (optional) Add IP from IP Catalog
  → Elaborated Design → I/O Ports → pin + IOSTANDARD assignment → save .xdc
  → Run Synthesis → Constraints Wizard (create_clock) → save .xdc
  → Run Simulation (behavioral) to verify
  → Generate Bitstream
  → Hardware Manager → Auto Connect → Program Device (JTAG mode)
  → (optional) ILA online debug: add ILA IP or MARK_DEBUG
```

Every experiment in this course (and most PL work in general) follows this exact loop. Master it on the LED
example and the rest is just different RTL + different IP.

---

*Translated from ALINX ZYNQ MPSoC FPGA Tutorial V1.03 (Course 1). Last updated: 2026-11-16.*
