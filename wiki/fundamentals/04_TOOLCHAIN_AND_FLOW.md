# 04 — Toolchain and Design Flow

> From HDL source to running hardware: the complete FPGA development flow, tools, and what happens inside each step.

---

## Table of Contents
1. [The Complete Design Flow](#1-the-complete-design-flow)
2. [Vivado (Xilinx/AMD)](#2-vivado-xilinxamd)
3. [Open-Source Tools](#3-open-source-tools)
4. [Synthesis Deep Dive](#4-synthesis-deep-dive)
5. [Implementation: Place and Route](#5-implementation-place-and-route)
6. [Timing Constraints (XDC)](#6-timing-constraints-xdc)
7. [Bitstream Generation and Programming](#7-bitstream-generation-and-programming)
8. [In-Circuit Debugging with ILA](#8-in-circuit-debugging-with-ila)
9. [Project Structure and Build Automation](#9-project-structure-and-build-automation)
10. [Compile Time Reality Check](#10-compile-time-reality-check)

---

## 1. The Complete Design Flow

```
┌──────────────────────────────────────────────────────────────┐
│                        DESIGN FLOW                            │
│                                                              │
│  Source RTL / HLS C++                                        │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │  SYNTHESIS  │  RTL → gate-level netlist                   │
│  │             │  Checks: syntax, semantics, latch inference │
│  └──────┬──────┘                                             │
│         │  netlist (.dcp)                                    │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │    OPT /    │  Logic optimization, retiming               │
│  │   OPTDESIGN │                                             │
│  └──────┬──────┘                                             │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │    PLACE    │  Assign netlist cells to physical sites     │
│  └──────┬──────┘                                             │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │    ROUTE    │  Connect placed cells through routing       │
│  └──────┬──────┘                                             │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────────┐                                         │
│  │ TIMING ANALYSIS │  Static timing analysis — all paths     │
│  │   (STA)         │  must have positive slack               │
│  └──────┬──────────┘                                         │
│         │  PASS?                                             │
│         │  ├── YES → Bitstream generation → Program FPGA    │
│         │  └── NO  → Adjust constraints / RTL / directives  │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │  BITSTREAM  │  .bit file (JTAG) or .bin (flash)           │
│  └──────┬──────┘                                             │
│         ▼                                                    │
│    FPGA Hardware                                             │
└──────────────────────────────────────────────────────────────┘
```

**Total flow time**: 15 minutes (small design, Artix-7) to 4+ hours (large Zynq UltraScale+ design).

### What Each Step Produces — and What the Views Mean

Every Vivado stage produces a checkpoint (`.dcp`) and opens a different view of your design. Knowing which view you're looking at, and what it tells you, is the key to not getting lost in the GUI.

#### The Flow Navigator (left sidebar in Vivado)

The Flow Navigator is the column of buttons on the left side of the Vivado window. It's the main menu for the design flow — you click top-to-bottom, and each button runs a stage and opens a view. Here's what every button does and what you see after clicking it:

```
┌──────────────────────────────────┐
│  Flow Navigator                   │
│                                   │
│  ┌─────────────────────────────┐  │
│  │ 1. Simulation               │  │  ← Run Simulation (behavioral)
│  └─────────────────────────────┘  │
│  ┌─────────────────────────────┐  │
│  │ 2. RTL Analysis              │  │  ← Open Elaborated Design / Run Linter
│  └─────────────────────────────┘  │
│  ┌─────────────────────────────┐  │
│  │ 3. Synthesis                 │  │  ← Run Synthesis → Open Synthesized Design
│  └─────────────────────────────┘  │
│  ┌─────────────────────────────┐  │
│  │ 4. Implementation            │  │  ← Run Implementation → Open Implemented Design
│  └─────────────────────────────┘  │
│  ┌─────────────────────────────┐  │
│  │ 5. Generate Bitstream         │  │  ← Write .bit file
│  └─────────────────────────────┘  │
│  ┌─────────────────────────────┐  │
│  │ 6. Hardware Manager          │  │  ← Program FPGA + ILA debug
│  └─────────────────────────────┘  │
└──────────────────────────────────┘
```

| # | Flow Navigator button | What it runs | What you see after | What the view tells you |
|---|------------------------|--------------|---------------------|-------------------------|
| 1 | **Simulation** → Run Simulation | Behavioral simulation of your RTL against a testbench. No synthesis, no timing — purely "does the logic do what I want?" | **Waveform window** (XSim) — signals over simulation time. | "Does my logic produce the right outputs for the right inputs?" You add signals to the waveform, restart, run, and inspect. This is where you verify the LED counter actually counts to 24999999 and toggles. |
| 2 | **RTL Analysis** → Open Elaborated Design (a.k.a. Run Linter) | Parses your Verilog, resolves parameters, builds the module hierarchy, and runs lint checks. **No technology mapping yet** — it's still abstract RTL, not gates. | **Schematic (RTL)** — a block diagram of your modules and how they connect, plus the **I/O Ports** table and **Messages** pane. | "Did Vivado understand my Verilog the way I intended?" The RTL Schematic shows the module hierarchy and interconnects. The Messages pane shows warnings (latches inferred, undriven signals, multi-driver nets). This is the cheapest place to catch bugs — fix them here before synthesis. |
| 3 | **Synthesis** → Run Synthesis | Maps your RTL to FPGA primitives (LUTs, FFs, BRAM, DSP48). Runs logic optimization (constant folding, dead-code elimination, retiming). | **Schematic (gate-level)** — real LUTs, FFs, and gates, not abstract modules. Also: Utilization report, Synthesis log. | "What circuit did the synthesizer build from my code?" If you see 32 `FDRE` blocks for `timer_cnt`, your 32-bit counter inferred correctly. If you see a `LATCH` block, you have a combinational `always` that doesn't cover all cases. Check the Utilization report for LUT/FF/BRAM/DSP counts. |
| 4 | **Implementation** → Run Implementation | Two sub-steps: **Place** (assign each netlist cell to a physical site on the die) then **Route** (program the routing fabric to connect them). Then runs **Static Timing Analysis**. | **Device view** (the FPGA floorplan, now filled with your placed logic and routing), **Timing Summary** (WNS/TNS/critical paths), **Utilization report** (final). | "Where on the die did the placer put my logic, and will it run at my target clock?" WNS ≥ 0 means timing met. WNS < 0 means it won't — you need to fix RTL, constraints, or implementation strategy. The Device view shows congestion (dense wire tangles = bad). |
| 5 | **Generate Bitstream** | Converts the placed-and-routed design into a `.bit` file (for JTAG) or `.bin` (for flash). | No view — just a file and a "Bitstream Generation Completed" dialog. | The `.bit` is what you download to the FPGA. If this succeeds, your design is physically realizable on this chip. |
| 6. | **Hardware Manager** → Open Target → Auto Connect → Program Device | Downloads the bitstream to the FPGA via JTAG. Optionally attaches ILA for live signal capture. | **ILA Dashboard** — live waveform captures from the running FPGA. | "Is my design actually working on real hardware?" This is the only view that shows real-world behavior. Trigger on `tvalid`, `tuser`, etc. and watch the actual signals. |

#### The typical order (and when to skip)

You don't have to run every step every time. Here's the practical order for different goals:

| Goal | Run these | Skip |
|------|-----------|------|
| **Verify logic only** (no hardware) | 1. Simulation | Everything else |
| **Check Verilog compiles + lint** | 2. RTL Analysis | Synthesis, Implementation, Bitstream |
| **Check it fits on the chip** | 2 → 3. Synthesis | Implementation, Bitstream |
| **Check timing meets target** | 2 → 3 → 4. Implementation | Bitstream, Hardware Manager |
| **Run on real hardware** | 2 → 3 → 4 → 5 → 6. All steps | None |
| **Debug on hardware** | All steps + add ILA before synthesis | None |

For your LED bring-up without a JTAG cable: just run **step 1 (Simulation)**. That verifies the logic without any hardware. When you get a JTAG cable, run the full flow 2 → 6.

#### How to tell which view you're in

Vivado changes the active view based on which design is open. Look at the dropdown at the top of the main window:

| Dropdown says | You're viewing | After which Flow Navigator step |
|---------------|----------------|----------------------------------|
| **Schematic** (RTL) | Module-level block diagram | RTL Analysis (Open Elaborated Design) |
| **Schematic** (gate-level) | LUTs, FFs, gates | Synthesis (Open Synthesized Design) |
| **Device** | FPGA floorplan | Synthesis (empty) or Implementation (filled) |
| **I/O Ports** | Pin assignment table | RTL Analysis or Synthesis |
| **Timing Summary** | STA reports | Implementation (Open Implemented Design) |
| **ILA Dashboard** | Live hardware waveforms | Hardware Manager |
| **Waveform** (XSim) | Simulation signals over time | Simulation |

#### The mental model

```
Your Verilog code
      │
      ▼  (1. Simulation)
Waveform            ← "does my logic produce the right outputs?"
      │
      ▼  (2. RTL Analysis)
RTL Schematic       ← "did you understand my code?" + lint warnings
      │
      ▼  (3. Synthesis)
Gate-level Schematic  ← "what circuit did you build from my code?"
      │
      ▼  (4. Implementation: Place)
Device view (placed)  ← "where on the chip did you put my circuit?"
      │
      ▼  (4. Implementation: Route)
Device view (routed)  ← "how did you wire it up?"
      │
      ▼  (4. Implementation: Timing)
Timing Summary      ← "will it run at my target clock speed?"
      │
      ▼  (5. Generate Bitstream)
.bit file           ← "the thing I download to the FPGA"
      │
      ▼  (6. Hardware Manager + ILA)
ILA waveform        ← "is it actually working on real hardware?"
```

Each view answers a different question. If you don't know which question you're asking, you'll be confused about what you're looking at.

> **ASIC note:** The RTL Schematic, gate-level Schematic, and Timing Summary all have direct ASIC equivalents (gate-level netlist, STA). The Device view does not — ASIC has no fixed floorplan; you design it yourself. See the FPGA-vs-ASIC comparison later in this doc.

---

## 2. Vivado (Xilinx/AMD)

Vivado is the primary tool for all Xilinx/AMD 7-series and later devices.

### Installation

- Download from: https://www.xilinx.com/support/download.html
- Choose "Vivado ML Standard" (free) or "Vivado ML Enterprise" (paid)
- **Free license covers**: Artix-7, Kintex-7, Zynq-7000 (limited), Spartan-7
- Size: ~40–80 GB installed
- OS: Linux (preferred), Windows (supported)

### Vivado Editions for This Project

| Edition | Cost | Covers for Vision |
|---------|------|------------------|
| **Vivado ML Standard** | Free | Artix-7, partial Zynq-7000 (up to Z7-010) |
| **Vivado ML Enterprise** | Paid | All devices including UltraScale+ |
| **Vitis Unified** | Free | Adds HLS + AI Engine support |

**Recommendation**: Start with Vivado ML Standard + a PYNQ-Z1 or Arty Z7-10 board (both are within the free license).

### Vivado Workflow Options

#### GUI Workflow (learning)
```
Create Project → Add Sources → Add Constraints → Run Synthesis →
Run Implementation → Generate Bitstream → Open Hardware Manager →
Program Device
```

#### Tcl Script Workflow (production)
Everything Vivado does in the GUI generates Tcl commands. You can run Vivado in batch mode:
```bash
vivado -mode batch -source build.tcl
```

A `build.tcl` for a simple project:
```tcl
create_project my_proj ./my_proj -part xc7z020clg400-1
add_files -fileset sources_1 [glob ./src/rtl/**/*.sv]
add_files -fileset constrs_1 ./constraints/top.xdc
set_property top top_module [current_fileset]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

#### IP Integrator (Block Design)
Vivado's Block Design view lets you assemble designs from IP cores with a graphical interface. Essential for Zynq designs where you need to configure the ARM PS, AXI interconnect, DMA controllers, etc.

```
Block Design components for a Zynq vision pipeline:
┌─────────┐    AXI    ┌─────────┐    AXI    ┌──────────────┐
│ Zynq PS │◄─────────►│ AXI DMA │◄─────────►│ Your custom  │
│ ARM+DDR │           │         │  Stream   │ image filter │
└─────────┘           └─────────┘           └──────────────┘
```

### Key Vivado Reports to Read

| Report | Location | What to look for |
|--------|----------|-----------------|
| Synthesis Report | `synth_1/runme.log` | Warnings about latches, undriven signals |
| Utilization | Implementation → Reports → Utilization | Resource % used |
| Timing Summary | Implementation → Reports → Timing Summary | Worst Negative Slack (WNS) must be ≥ 0 |
| Clock Interaction | Timing → Clock Interaction | CDC paths between clock domains |
| DRC (Design Rule Checks) | Implementation → Reports → DRC | Physical design rule violations |

---

## 3. Open-Source Tools

For learning and experimentation (not recommended as a substitute for Vivado on real Xilinx hardware):

| Tool | Role | Supports |
|------|------|---------|
| **Yosys** | Synthesis | Most Verilog, some SV; targets iCE40, ECP5, Xilinx (via nextpnr) |
| **nextpnr** | Place & Route | iCE40, ECP5, Nexus, Xilinx (experimental) |
| **iverilog** | Verilog simulation | Verilog-2005 |
| **Verilator** | Fast simulation (C++) | Synthesizable Verilog/SV |
| **GTKWave** | Waveform viewer | .vcd, .fst files |
| **F4PGA (formerly SymbiFlow)** | Full flow | Xilinx 7-series (limited) |

The **iCE40** (Lattice) + **nextpnr** combination has the most mature open-source support. Useful for learning without proprietary tools, but limited for real vision projects (small device, few DSPs).

---

## 4. Synthesis Deep Dive

Synthesis converts your HDL into a **technology-specific netlist** (gates, FFs, BRAMs, DSPs).

### What Synthesis Does

1. **Parsing**: parse Verilog/SystemVerilog into an AST
2. **Elaboration**: resolve parameters, generate blocks, hierarchies
3. **RTL optimization**: constant folding, dead code elimination, Boolean optimization
4. **Technology mapping**: map abstract logic to target library primitives (LUT6, FDRE, DSP48E1...)
5. **Inference**: recognize patterns and infer BRAMs, DSP slices, shift registers

### Key Synthesis Warnings to Never Ignore

| Warning | Meaning | Fix |
|---------|---------|-----|
| `Latch inferred` | Your combinational `always` doesn't cover all conditions | Add `default` to `case`, or add `else` |
| `Net is unconnected` | Signal declared but never driven or used | Remove or connect |
| `Timing constraint not found` | A clock isn't constrained | Add XDC `create_clock` for every clock |
| `DSP not inferred` | Multiply didn't map to DSP (using LUTs instead) | Check data widths and coding style |
| `Shift register inferred` | A chain of FFs became an SRL32 (fine) | Usually intentional |

### BRAM Inference

The synthesizer automatically infers BRAM when it sees a specific coding pattern:

```verilog
// This pattern synthesizes to a BRAM:
reg [7:0] mem [0:255];  // 256-byte array

always @(posedge clk) begin
    if (we) mem[addr] <= data_in;  // write port
    data_out <= mem[addr];          // read port (registered = BRAM, non-registered = LUTRAM)
end
```

If you use `mem[addr]` without registering the output, the tool may use distributed (LUT) RAM instead of BRAM.

### DSP48 Inference

```verilog
// This maps to a DSP slice:
wire signed [15:0] a, b;
reg  signed [31:0] result;

always @(posedge clk)
    result <= a * b;  // 16×16 multiply → maps to DSP48E1

// This may NOT map to DSP (too wide or complex expression):
wire [24:0] a_wide;
wire [19:0] b_wide;
// 25×20 = 45 bits → needs 2 DSPs and careful coding
```

---

## 5. Implementation: Place and Route

After synthesis produces a netlist, **implementation** places and routes it.

### Place

The **placer** assigns each netlist cell to a physical FPGA site:
- LUT → specific CLB slice, LUT position
- BRAM → specific BRAM tile
- DSP → specific DSP48 site
- I/O → specific I/O bank, pin

The placer tries to minimize wire lengths between connected cells.

### Route

The **router** programs the routing fabric to connect placed cells. This is the most time-consuming step for large designs.

### Timing-Driven P&R

Modern tools use the timing constraints (see next section) to guide placement and routing. If a path is timing-critical, the tool places the two endpoints physically close together.

### Implementation Strategies

Vivado offers multiple implementation strategies — try these when timing fails:

| Strategy | Use when |
|----------|---------|
| `Default` | First try |
| `Performance_ExplorePostRoutePhysOpt` | Timing close but not meeting |
| `Area_Explore` | Running out of resources |
| `Flow_AlternateRoutability` | Routing congestion |

---

## 6. Timing Constraints (XDC)

**Constraints are mandatory.** Without them, the tool doesn't know what clock frequency you need and won't optimize properly.

### Minimum Required XDC (Xilinx)

```tcl
# 1. Create clock constraint for every clock in the design
# (check your board's schematic for the oscillator frequency)
create_clock -period 10.000 -name clk_sys [get_ports clk]
# Period = 10 ns → 100 MHz

# For a Zynq design, the PS generates clocks for the PL:
# (use create_generated_clock if derived from PS clock)
create_clock -period 13.468 -name clk_pixel [get_ports hdmi_clk_p]
# 74.25 MHz pixel clock for 720p video

# 2. I/O timing (optional but recommended)
set_input_delay  -clock clk_sys 2.0 [get_ports data_in]
set_output_delay -clock clk_sys 2.0 [get_ports data_out]

# 3. False paths (signals that don't need timing analysis)
set_false_path -from [get_clocks clk_sys] -to [get_clocks clk_pixel]
# (use proper CDC — async FIFO — not false paths for real data)

# 4. Pin location constraints (from board schematic)
set_property PACKAGE_PIN H16 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
```

### Clock Domain Interaction

After running timing, check the **Clock Interaction report**:
- Green: safe (clocks are unrelated or properly constrained)
- Yellow: warning (potential issue)
- Red: unsafe CDC — you have logic crossing clock domains without synchronization

> **Timing constraints are a deep topic.** For a full treatment of STA, generated clocks, CDC constraints, multi-cycle paths, reading critical-path reports, and the timing closure workflow, see [09 — Timing Constraints (XDC) Deep Dive](../hardware/09_TIMING_CONSTRAINTS.md).

---

## 7. Bitstream Generation and Programming

### Generating the Bitstream

In Vivado: `Flow → Generate Bitstream` (or `write_bitstream` in Tcl).
Output: `project.bit` (for JTAG loading) or `project.bin` (for flash programming).

### Programming via JTAG (Vivado Hardware Manager)

```
1. Connect USB-JTAG cable (Xilinx JTAG cable or Digilent JTAG-HS2)
2. Open Hardware Manager in Vivado
3. Open Target → Auto Connect
4. Program Device → select .bit file
5. Wait ~1-10 seconds
6. FPGA is now running your design
```

This loads to volatile configuration RAM — lost on power cycle.

### Programming to Flash (persistent)

For Zynq boards with on-board QSPI flash (like PYNQ-Z1):

```
1. Generate .bit file
2. Create a boot image (.bin) using bootgen tool (Xilinx)
3. Copy BOOT.BIN to the SD card
4. The Zynq boot ROM loads it at power-up
```

---

## 8. In-Circuit Debugging with ILA

Simulation only goes so far. For bugs that only appear in real hardware, use the **Integrated Logic Analyzer (ILA)** — a logic analyzer embedded in your FPGA design.

### How ILA Works

```
Your design:
  signal_A ──────────────────────────────────► normal logic
                │
                └─► ILA Core (uses BRAM to store samples)
                            │
                            └─► Vivado Hardware Manager (reads via JTAG)
                                (displays waveform on your computer)
```

### Adding ILA in Vivado

```tcl
# In Tcl or IP Catalog: add Debug → ILA (Integrated Logic Analyzer)
# Then mark signals in your RTL:

(* mark_debug = "true" *) wire [7:0] pixel_data;
(* mark_debug = "true" *) wire       pixel_valid;
(* mark_debug = "true" *) wire [10:0] col_cnt;
```

The synthesis tool will automatically insert ILA cores for marked signals.

### ILA Limitations

- Uses BRAM (each ILA probe depth uses BRAM)
- Captures ~1024–8192 samples (configurable)
- Trigger on any signal condition
- Cannot capture continuous data — triggered snapshot only

**For video debugging**: ILA is excellent for checking sync signals, control state, and short bursts of pixel data.

---

## 9. Project Structure and Build Automation

### Recommended Directory Layout

```
fpga-vision-project/
├── src/
│   ├── rtl/              ← SystemVerilog/Verilog RTL
│   ├── hls/              ← HLS C++ sources
│   └── ip/               ← Vendor IP configurations (.xci files)
├── sim/
│   ├── tb/               ← Testbenches
│   └── scripts/          ← Simulation automation
├── constraints/
│   ├── timing.xdc        ← Timing constraints
│   └── pins.xdc          ← Pin assignments
├── scripts/
│   ├── build.tcl         ← Vivado build automation
│   ├── program.tcl       ← JTAG programming script
│   └── hls_build.tcl     ← Vitis HLS build automation
├── sw/                   ← Software (ARM/host-side code)
├── docs/
│   └── wiki/             ← This wiki
├── Makefile              ← Top-level build automation
└── README.md
```

### Makefile targets

```makefile
.PHONY: all synth impl bitstream program sim clean

VIVADO = vivado -mode batch -nojournal -nolog

all: bitstream

synth:
    $(VIVADO) -source scripts/build.tcl -tclargs synth

impl:
    $(VIVADO) -source scripts/build.tcl -tclargs impl

bitstream:
    $(VIVADO) -source scripts/build.tcl -tclargs bitstream

program:
    $(VIVADO) -source scripts/program.tcl

sim:
    iverilog -g2012 -o sim/out sim/tb/tb_top.v src/rtl/**/*.sv
    vvp sim/out

clean:
    rm -rf vivado_proj/ vivado.jou vivado.log
```

---

## 10. Compile Time Reality Check

| Design size | Synthesis | Implementation | Total |
|-------------|-----------|----------------|-------|
| Small (< 10% utilization) | 1–3 min | 3–8 min | 5–15 min |
| Medium (10–50%) | 3–8 min | 8–20 min | 15–30 min |
| Large (50–80%) | 8–20 min | 20–60 min | 30–90 min |
| Very large (> 80%) | 15–30 min | 60–240 min | 90–300 min |

**Implications for your workflow:**
- Simulation is FREE (seconds to minutes) — use it heavily before hardware runs
- Expect 2–4 compile + reprogram cycles per bug when debugging on hardware
- Keep designs modular so you can synthesize/simulate sub-modules independently
- Use out-of-context synthesis (OOC) for reusable IP modules — synthesize them once, reuse
- **Never wait for a full compile to find a syntax error** — run synthesis first, check reports

---

**Next**: [05 — Memory and Interfaces](./05_MEMORY_AND_INTERFACES.md)
