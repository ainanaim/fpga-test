# 09 — Timing Constraints (XDC) Deep Dive

> Timing constraints are not optional. They are the contract between you and the tool that defines what "correct" means. Without them, Vivado has no target to optimize toward and your design may silently compute wrong answers.

---

## Table of Contents
1. [How Static Timing Analysis Works](#1-how-static-timing-analysis-works)
2. [The Setup and Hold Model](#2-the-setup-and-hold-model)
3. [Clock Constraints — The Most Critical Part](#3-clock-constraints--the-most-critical-part)
4. [Generated Clock Constraints (MMCM / PLL)](#4-generated-clock-constraints-mmcm--pll)
5. [Input and Output Delay Constraints](#5-input-and-output-delay-constraints)
6. [Clock Domain Crossing Constraints](#6-clock-domain-crossing-constraints)
7. [Multi-Cycle Path Constraints](#7-multi-cycle-path-constraints)
8. [Reading Timing Reports](#8-reading-timing-reports)
9. [Timing Closure Workflow — When It Fails](#9-timing-closure-workflow--when-it-fails)
10. [Complete XDC Template for a Vision Project](#10-complete-xdc-template-for-a-vision-project)
11. [Common Mistakes](#11-common-mistakes)

---

## 1. How Static Timing Analysis Works

Vivado's timing engine (**STA — Static Timing Analysis**) checks every possible combinational path in your design between every pair of flip-flops and reports whether data can travel that path in one clock period.

### The Launch–Capture Model

Every timing path has two flip-flops:

```
         Launch FF                              Capture FF
         (source)                               (destination)

CLK ─────┬──────────────────────────────────────┬──────
         │                                      │
         ▼                                      ▼
    ┌────────┐    combinational logic       ┌────────┐
    │  FF_A  │──► [LUT] ──► [LUT] ──► ... ─►│  FF_B  │
    └────────┘                               └────────┘
         │←─────────────── 1 clock period ──────────────►│

Data must arrive at FF_B's D input before the clock edge — with enough
margin for FF_B's setup time.
```

The tool models:
- **Clock propagation delay** from the oscillator pin to each FF's clock input
- **Logic delay** through every LUT, carry chain, and routing segment
- **Setup and hold requirements** of every FF

It does this for **every path** in the design — potentially millions of paths — without running the circuit. This is what makes it *static*.

---

## 2. The Setup and Hold Model

These are the two fundamental timing constraints every FF enforces.

### Setup Time (Tsu) — the "arrive early enough" rule

Data must be **stable before the clock edge** by at least Tsu.

```
                         ┌──── Tsu ────┐
Data: ════════════════XXXXXXXXXXXXXXXXXXXX══════
                                       ↑
Clock:  ───────────────────────────────┘ rising edge

If data changes inside the Tsu window → metastability → wrong output
```

**Setup slack** = (time data arrives) - (time data must arrive by)
- Positive slack → timing met ✓
- Negative slack → timing VIOLATED — design is incorrect

### Hold Time (Th) — the "stay stable long enough" rule

Data must remain **stable after the clock edge** by at least Th.

```
                         ┌── Th ──┐
Data: ════XXXXXXXXXXXXXXXXXXXXXXXX══════════════
                         ↑
Clock: ──────────────────┘ rising edge

If data changes too soon after the edge → FF may not latch correctly
```

Hold violations are **not fixable by lowering clock frequency** — they depend only on routing delay, not period. Vivado fixes hold violations automatically by inserting delay buffers during routing.

### The timing budget equation

```
Tperiod ≥ Tco + Tlogic + Trouting + Tsu - Tskew

Where:
  Tco      = FF clock-to-output delay (~0.1–0.4 ns on 7-series)
  Tlogic   = sum of logic delays through LUTs (~0.3 ns per LUT level)
  Trouting = wire delay between cells (0.1–3+ ns depending on distance)
  Tsu      = FF setup time (~0.04 ns on 7-series with FDRE)
  Tskew    = clock skew between launch and capture FF clocks (can help or hurt)

Fmax = 1 / Tperiod_min
```

---

## 3. Clock Constraints — The Most Critical Part

**Every clock in your design must have a `create_clock` constraint.** This is the single most important line in your XDC file. Without it, the tool does not know the period, cannot compute slack, and will not optimize timing for that domain.

### create_clock syntax

```tcl
create_clock -period <period_ns> -name <name> [get_ports <pin>]
```

### Common clocks in a Zynq vision project

```tcl
# ─────────────────────────────────────────────────────────────────
# Primary oscillator on the board
# (check your board schematic — PYNQ-Z1 has 125 MHz on PS, 
#  and you typically use MMCM to derive PL clocks)
# ─────────────────────────────────────────────────────────────────
create_clock -period 8.000 -name clk_125 [get_ports clk_125mhz]
# 8 ns period = 125 MHz

# ─────────────────────────────────────────────────────────────────
# HDMI pixel clock input (from HDMI source / camera)
# 720p @ 60 fps = 74.25 MHz → period = 13.468 ns
# 1080p @ 60 fps = 148.5 MHz → period = 6.734 ns
# ─────────────────────────────────────────────────────────────────
create_clock -period 13.468 -name clk_pixel [get_ports hdmi_rx_clk_p]

# ─────────────────────────────────────────────────────────────────
# MIPI CSI-2 D-PHY byte clock
# Depends on sensor data rate. Example: 2-lane 800 Mbps sensor
# Byte clock = data rate / (8 bits * lanes) = 800M / (8*2) = 50 MHz
# ─────────────────────────────────────────────────────────────────
create_clock -period 20.000 -name clk_dphy [get_ports mipi_csi_clk_p]
```

### Critical rule: one constraint per physical clock pin

If you have two clocks both entering on the same pin at different times (impossible in real hardware), that is a modeling error. Each physical oscillator or external clock source gets exactly one `create_clock`.

### Clock uncertainty (optional but useful)

Accounts for jitter and manufacturing variation:

```tcl
# Add 200 ps of clock uncertainty to all clocks
# This tightens the effective timing budget by 0.2 ns — a safety margin
set_clock_uncertainty 0.200 [all_clocks]

# Or specify setup/hold separately:
set_clock_uncertainty -setup 0.150 [all_clocks]
set_clock_uncertainty -hold  0.050 [all_clocks]
```

---

## 4. Generated Clock Constraints (MMCM / PLL)

Your FPGA fabric clock almost never comes directly from an external pin — it goes through an **MMCM (Mixed-Mode Clock Manager)** or **PLL** that multiplies, divides, and phase-shifts it to generate the frequencies you need.

```
External 125 MHz pin
        │
        ▼
    ┌────────┐
    │  MMCM  │──► 100 MHz (processing clock for your RTL)
    │        │──► 148.5 MHz (1080p pixel clock output)
    │        │──► 200 MHz (DDR reference clock)
    └────────┘
```

Vivado **automatically creates generated clock constraints** when you use the Clocking Wizard IP or instantiate MMCME2_ADV directly — you do not need to write `create_clock` for MMCM outputs. But if you route a clock through custom logic or use a clock buffer manually, you must declare it:

```tcl
# Manual generated clock declaration
# (usually NOT needed if you use Clocking Wizard IP — Vivado handles it)
create_generated_clock \
    -name clk_100 \
    -source [get_pins mmcm_inst/CLKIN1] \
    -multiply_by 4 \
    -divide_by 5 \
    [get_pins mmcm_inst/CLKOUT0]
# 125 MHz × (4/5) = 100 MHz
```

### Verifying MMCM clocks were recognised

After synthesis, run:
```tcl
report_clocks
```
Every clock you expect should appear. If a clock is missing, add the constraint. If an unexpected clock appears, investigate — it may be an asynchronous signal being used as a clock (a design error).

---

## 5. Input and Output Delay Constraints

These tell Vivado when external data arrives relative to the clock, and when your outputs must be valid.

### set_input_delay

```tcl
# Data from an external device arrives 2 ns after the clock edge
# Vivado uses this to check that the first FF receiving this data
# has enough setup margin.
set_input_delay -clock clk_sys -max 2.0 [get_ports data_in[*]]
set_input_delay -clock clk_sys -min 0.5 [get_ports data_in[*]]
# -max: worst-case arrival (for setup analysis)
# -min: best-case arrival (for hold analysis)
```

### set_output_delay

```tcl
# Downstream device requires data 2 ns before the next clock edge
set_output_delay -clock clk_sys -max 2.0 [get_ports data_out[*]]
set_output_delay -clock clk_sys -min 0.5 [get_ports data_out[*]]
```

### For vision projects: what actually needs I/O constraints

| Signal | Needs constraint? | Why |
|--------|------------------|-----|
| Camera parallel data (DVP) | Yes | External timing from camera PCLK |
| HDMI differential pairs | Handled by HDMI IP | IP sets constraints internally |
| MIPI CSI-2 lanes | Handled by MIPI IP | IP sets constraints internally |
| AXI ports on Zynq PS boundary | Auto-constrained | Vivado generates these |
| Debug/status LEDs | Optional | Non-timing-critical |
| Button inputs | Optional (use false_path) | Async human input |

**Practical advice**: for buttons, switches, and LEDs that have no timing requirement, suppress the analysis:

```tcl
# Buttons and LEDs are not timing-critical — suppress warnings
set_false_path -from [get_ports btn[*]]
set_false_path -to   [get_ports led[*]]
```

---

## 6. Clock Domain Crossing Constraints

This is the most common source of **silent bugs** in FPGA vision designs. When a signal crosses from one clock domain to another, you must tell Vivado how to handle the analysis.

### The three CDC scenarios

#### Scenario A: Completely asynchronous clocks (different sources)

Example: 100 MHz processing clock vs 74.25 MHz pixel clock.

```tcl
# Tell Vivado these two clocks have no phase relationship.
# No timing analysis between them — you are responsible for
# using proper CDC (async FIFO or 2-FF synchronizer).
set_clock_groups -asynchronous \
    -group [get_clocks clk_proc] \
    -group [get_clocks clk_pixel]
```

**Use when**: clocks come from different sources (different MMCMs, external sources) with no guaranteed phase relationship.

#### Scenario B: Related clocks, specific crossing excluded

```tcl
# This path intentionally crosses clock domains via an async FIFO.
# Tell Vivado not to analyse it as a single-cycle path.
set_false_path -from [get_clocks clk_a] -to [get_clocks clk_b]
```

**Use when**: you have implemented proper CDC (the FIFO handles it), but only for specific paths. Blanket `set_false_path` between all clocks hides real problems — be specific.

#### Scenario C: Slow control signals crossing domains

```tcl
# A single-bit enable signal crosses from clk_slow to clk_fast.
# It is synchronised by a 2-FF synchroniser, so give it 2 cycles budget.
set_max_delay -datapath_only 2 \
    -from [get_cells slow_enable_reg] \
    -to   [get_cells sync_stage1_reg]
```

**Use when**: a single-bit signal is explicitly synchronised with a 2-FF synchroniser. The `-datapath_only` flag disables clock skew analysis, which is correct for CDC paths.

### How to check CDC in Vivado

```tcl
# After implementation:
report_cdc -file cdc_report.txt

# In the GUI: Timing → Report CDC
# Red entries = unsafe crossings that need attention
# Green = Vivado believes they are safe (verify that your design actually is)
```

The CDC report lists every cross-domain path and classifies it:
- **Safe**: recognised safe structure (2-FF sync, async FIFO grey-code pointers)
- **Unsafe**: raw signal crossing without synchronisation — fix immediately

---

## 7. Multi-Cycle Path Constraints

By default Vivado assumes every path must complete in **one clock cycle**. Sometimes you intentionally need more than one cycle (e.g., a slow configuration register read that only changes every 1000 cycles).

```tcl
# Example: a division result that takes 8 cycles to compute.
# The downstream register only samples it on cycle 8.
# Tell the tool it has 8 cycles, not 1.
set_multicycle_path 8 -setup \
    -from [get_cells divider_result_reg[*]] \
    -to   [get_cells output_latch_reg[*]]

# Always pair with hold constraint:
set_multicycle_path 7 -hold \
    -from [get_cells divider_result_reg[*]] \
    -to   [get_cells output_latch_reg[*]]
# Hold = setup_cycles - 1
```

**Warning**: multi-cycle paths are easy to get wrong. If the data actually arrives on cycle 1 but you told Vivado it has 8 cycles, the tool will not optimise it and you will get functional errors. Only use this when you have explicit enable/valid logic ensuring the destination only samples on the correct cycle.

---

## 8. Reading Timing Reports

After implementation, the most important report is the **Timing Summary**.

### The numbers that matter

```
--------------------------------
Timing Summary
--------------------------------
WNS (Worst Negative Slack)  =  -0.312 ns  ← NEGATIVE = FAIL
TNS (Total Negative Slack)  = -15.420 ns  ← sum of all failing slacks
WHS (Worst Hold Slack)      =   0.082 ns  ← positive = hold OK
THS (Total Hold Slack)      =   0.000 ns
WPWS (Worst Pulse Width)    =   4.500 ns  ← clock pulse width check
```

- **WNS < 0**: at least one path fails setup. Circuit will malfunction.
- **TNS**: how bad the overall situation is. -0.1 ns (one path barely failing) vs -100 ns (catastrophic) need very different interventions.
- **WHS < 0**: hold violation. Vivado usually fixes these automatically during routing.

### Reading a critical path report

```
Report Timing (worst path):

Slack:              -0.312 ns  (required - arrival)

Source:             pixel_pipeline/filter/sum_reg[7]/C
                    (rising edge-triggered FF, clk_proc)
Destination:        pixel_pipeline/output/data_reg[7]/D
                    (rising edge-triggered FF, clk_proc)

Data Path Delay:    9.871 ns   ← this is the problem: too long
  Logic:            4.230 ns   (5 LUT levels)
  Routing:          5.641 ns   ← routing is 57% of the delay

Path Groups:        {clk_proc}

Data arrival time:  10.371 ns
Data required time: 10.059 ns  ← (period - setup - uncertainty)
Slack:              -0.312 ns  VIOLATED
```

**How to interpret**:

| Routing % of path | What it means | Fix |
|-------------------|--------------|-----|
| > 60% | Logic is spread far across the chip | Add pipeline registers to break the path; use Pblock to constrain placement |
| 40–60% | Balanced; tool may fix with better strategy | Try `Performance_ExplorePostRoutePhysOpt` strategy |
| < 40% | Logic depth is the bottleneck | Restructure logic (fewer LUT levels), rebalance adder tree |

### Finding and fixing the critical path — step by step

```
1. Run implementation → check Timing Summary
2. If WNS < 0:
   a. Open Timing → Report Timing Summary → click on the failing path
   b. Identify: is the delay dominated by logic or routing?
   c. Routing-dominated → try placement constraints or different strategy
   d. Logic-dominated → add a pipeline register in the middle of the path
3. Re-run implementation → check WNS again
4. Repeat until WNS ≥ 0 (positive slack everywhere)
```

---

## 9. Timing Closure Workflow — When It Fails

Failing timing is normal, especially the first time. Here is the systematic approach:

### Level 1: Easy fixes (try first)

```tcl
# 1. Make sure all clocks are constrained
report_clocks        # every domain must appear

# 2. Check for missing constraints causing false positives
report_timing_summary -warn_on_violation

# 3. Try a more aggressive implementation strategy
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream
```

### Level 2: RTL changes

Add a pipeline register at the midpoint of the failing path. This is the most reliable fix:

```verilog
// BEFORE (too long for one cycle):
always @(posedge clk)
    result <= (a * b) + (c * d) + (e * f) + accumulator;

// AFTER (split into two pipeline stages):
reg [31:0] partial;
always @(posedge clk)
    partial <= (a * b) + (c * d);    // stage N

always @(posedge clk)
    result  <= partial + (e * f) + accumulator;  // stage N+1
// (increases latency by 1 cycle; throughput unchanged)
```

Remember to also pipeline `valid` and any sideband signals (TLAST, TUSER) through the same number of extra register stages.

### Level 3: Floorplanning

If two modules communicate heavily and the tool places them far apart, force them close together:

```tcl
# In Vivado: Floorplanning → Draw Pblock
# Or in XDC:
create_pblock pblock_filter
add_cells_to_pblock [get_pblocks pblock_filter] \
    [get_cells pixel_pipeline/filter/*]
resize_pblock [get_pblocks pblock_filter] \
    -add {SLICE_X0Y0:SLICE_X49Y99}   # restrict to bottom-left quarter
```

### Level 4: Lower the clock frequency

If none of the above works in the available project time, reduce the clock target. Find the actual Fmax from the timing report:

```
If WNS = -0.5 ns at 100 MHz (10 ns period):
  Actual achievable period = 10.5 ns
  Achievable Fmax = 1 / 10.5 ns ≈ 95 MHz

Change your create_clock to 10.5 ns and re-run.
```

For a vision pipeline at 1080p 60fps, the minimum fabric clock is set by your pixel rate:
- 1080p 60fps = 148.5 MHz pixel clock
- If you process 1 pixel/cycle, you need ≥ 148.5 MHz
- If you process 2 pixels/cycle (dual-pixel mode), you can run at 74.25 MHz

---

## 10. Complete XDC Template for a Vision Project

This template covers a typical Zynq-based 1080p vision pipeline. Adapt pin names from your board's schematic.

```tcl
# =============================================================================
# timing.xdc — Timing Constraints for FPGA Vision Project
# Target: Zynq-7020 (PYNQ-Z1 / Arty Z7)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. PRIMARY CLOCKS
# -----------------------------------------------------------------------------

# On-board 125 MHz oscillator connected to PS (Zynq handles this internally).
# The PL clocks are driven by the PS FCLK outputs via MMCM — Vivado
# auto-constrains those when you configure the Zynq PS in Block Design.

# External pixel clock from HDMI source (if using HDMI RX):
create_clock -period 6.734 -name clk_pixel_rx [get_ports hdmi_rx_clk_p]
# 6.734 ns = 148.5 MHz = 1080p @ 60 fps pixel clock

# If you are generating the pixel clock internally from MMCM,
# Vivado auto-creates the generated clock — no entry needed here.

# -----------------------------------------------------------------------------
# 2. CLOCK DOMAIN CROSSING — declare all async pairs
# -----------------------------------------------------------------------------

# Processing clock (from PS FCLK, e.g. 100 MHz) vs pixel clock (148.5 MHz)
# These are unrelated — no phase guarantee.
set_clock_groups -asynchronous \
    -group [get_clocks clk_proc] \
    -group [get_clocks clk_pixel_rx]

# Processing clock vs DDR controller reference clock (200 MHz internal)
set_clock_groups -asynchronous \
    -group [get_clocks clk_proc] \
    -group [get_clocks clk_ddr_ref]

# -----------------------------------------------------------------------------
# 3. FALSE PATHS — signals with no timing requirement
# -----------------------------------------------------------------------------

# Human-operated inputs: buttons, DIP switches
set_false_path -from [get_ports btn[*]]
set_false_path -from [get_ports sw[*]]

# Status outputs: LEDs (no setup time requirement)
set_false_path -to [get_ports led[*]]

# Asynchronous reset input (held for many cycles — not a timing path)
set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------------------
# 4. I/O TIMING — parallel camera (DVP interface example)
# -----------------------------------------------------------------------------

# OV7670 parallel camera: data valid tsu=5ns, th=2ns after PCLK rising edge
# PCLK comes FROM the camera (it is the clock source for this domain)
create_clock -period 41.667 -name pclk [get_ports cam_pclk]  # 24 MHz

set_input_delay -clock pclk -max 5.0 [get_ports cam_data[*]]
set_input_delay -clock pclk -min 2.0 [get_ports cam_data[*]]
set_input_delay -clock pclk -max 5.0 [get_ports cam_href]
set_input_delay -clock pclk -max 5.0 [get_ports cam_vsync]

# cam_pclk domain → clk_proc domain: declare asynchronous
set_clock_groups -asynchronous \
    -group [get_clocks pclk] \
    -group [get_clocks clk_proc]

# -----------------------------------------------------------------------------
# 5. PIN LOCATION AND VOLTAGE STANDARD
# (copy from your board's master XDC file — board-specific)
# -----------------------------------------------------------------------------

# Example for PYNQ-Z1 system clock (from board master XDC):
# set_property PACKAGE_PIN H16 [get_ports sysclk]
# set_property IOSTANDARD LVCMOS33 [get_ports sysclk]

# HDMI differential clock pair (LVDS — do NOT set IOSTANDARD manually
# when using HDMI IP; the IP manages this):
# set_property PACKAGE_PIN N18 [get_ports hdmi_rx_clk_p]

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
```

---

## 11. Common Mistakes

### Mistake 1: Unconstrained clock
```tcl
# WRONG — clock has no create_clock
# Vivado picks an arbitrary period or skips the domain entirely.

# RIGHT
create_clock -period 10.000 -name clk [get_ports clk]
```
Symptom: timing report shows "No timing constraints found" or the domain is missing from `report_clocks`.

---

### Mistake 2: set_false_path on a real data path
```tcl
# WRONG — you use false_path to "fix" failing timing on a real data bus
set_false_path -from [get_clocks clk_a] -to [get_clocks clk_b]
# This tells Vivado to ignore the path entirely.
# If data actually crosses without synchronisation, it is a real bug —
# now hidden from the tool and from you.

# RIGHT — fix the CDC properly (async FIFO) and constrain it correctly
set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
```

---

### Mistake 3: Forgetting the hold companion to set_multicycle_path
```tcl
# WRONG — setup only
set_multicycle_path 4 -setup -from [get_cells a_reg] -to [get_cells b_reg]

# RIGHT — always pair setup with hold = setup - 1
set_multicycle_path 4 -setup -from [get_cells a_reg] -to [get_cells b_reg]
set_multicycle_path 3 -hold  -from [get_cells a_reg] -to [get_cells b_reg]
```
Without the hold constraint, Vivado may still check hold with the default single-cycle rule, causing hold violations on paths you think are constrained.

---

### Mistake 4: Using a signal as a clock
```verilog
// WRONG — routing a data signal into a clock input of an FF
always @(posedge pixel_valid)   // pixel_valid is a DATA signal, not a clock
    data_reg <= data_in;

// RIGHT — always use a real clock with clock routing resources
always @(posedge clk)
    if (pixel_valid) data_reg <= data_in;
```
Vivado warns about this but may still allow synthesis. The result has unpredictable skew and no clock constraint can be properly applied.

---

### Mistake 5: Applying create_clock to an internal net instead of a port
```tcl
# WRONG — the port is the entry point of the clock, not an internal wire
create_clock -period 10.0 [get_nets clk_internal]

# RIGHT — always constrain at the physical package pin
create_clock -period 10.0 [get_ports clk]
```

---

### Mistake 6: Ignoring hold violations
Hold violations in the timing summary (WHS < 0) cannot be fixed by reducing clock frequency. They mean data arrives too early at the capture FF — routing is too fast. Vivado normally inserts delay buffers automatically to fix these during routing. If they persist after routing:
- Check if `set_false_path` or `set_multicycle_path` constraints accidentally exempted the path from hold analysis
- Recheck that your synthesis/implementation strategy is not set to `Area` (which may limit buffer insertion)

---

---

## Local Reference: UG1085 Chapter Guide

The Zynq UltraScale+ TRM ([`ug1085-zynq-ultrascale-trm.pdf`](../../resources/ug1085-zynq-ultrascale-trm.pdf)) covers the following timing-relevant chapters:

| Chapter | Title | Relevant to |
|---------|-------|-------------|
| Ch. 37 | Clock Generation and Distribution | MMCM/PLL configuration, generated clocks, clock gating |
| Ch. 38 | Low Power Domains | Clock domain isolation, power-aware clocking |
| Ch. 19 | PS-PL AXI Interfaces | AXI clock domains, HP/HPC/LPD port timing |
| Ch. 11 | Boot and Configuration | Boot clock requirements, configuration timing |

---

**Previous**: [04 — Toolchain and Design Flow](../fundamentals/04_TOOLCHAIN_AND_FLOW.md)
**Next**: [15 — Learning Path](../vision/15_LEARNING_PATH.md)
