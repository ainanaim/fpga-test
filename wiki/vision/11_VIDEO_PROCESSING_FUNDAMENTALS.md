# 11 — Video Processing on FPGA: Step-by-Step Fundamentals

> This document builds up video processing from absolute zero — what a pixel is in hardware, how a frame flows through the FPGA clock by clock, and how each stage of a pipeline actually works. Read this before diving into any RTL.

---

## Table of Contents
1. [What a Video Frame Actually Is (in hardware)](#1-what-a-video-frame-actually-is-in-hardware)
2. [How a Pixel Moves Through the FPGA](#2-how-a-pixel-moves-through-the-fpga)
3. [The Clock — What Happens Every Cycle](#3-the-clock--what-happens-every-cycle)
4. [Telling the Pipeline Where Lines and Frames Start/End](#4-telling-the-pipeline-where-lines-and-frames-startend)
5. [Handshaking — Valid and Ready](#5-handshaking--valid-and-ready)
6. [Storing One Pixel](#6-storing-one-pixel)
7. [Storing a Row of Pixels — Shift Registers](#7-storing-a-row-of-pixels--shift-registers)
8. [Storing a Full Line — Line Buffers (BRAM)](#8-storing-a-full-line--line-buffers-bram)
9. [Accessing a 3×3 Neighborhood — Sliding Window](#9-accessing-a-33-neighborhood--sliding-window)
10. [Your First Operation — Pixel-Level Brightness](#10-your-first-operation--pixel-level-brightness)
11. [Your Second Operation — 3×3 Blur](#11-your-second-operation--33-blur)
12. [Pipeline Stages — Latency and Throughput](#12-pipeline-stages--latency-and-throughput)
13. [Storing a Full Frame — When You Need DDR](#13-storing-a-full-frame--when-you-need-ddr)
14. [End-to-End Pipeline Summary](#14-end-to-end-pipeline-summary)
15. [Common Mistakes and How to Avoid Them](#15-common-mistakes-and-how-to-avoid-them)
16. [Connecting a Real Camera — The Receiver FSM](#16-connecting-a-real-camera--the-receiver-fsm)

---

## 1. What a Video Frame Actually Is (in hardware)

A video frame is not a 2D grid of pixels sitting in memory all at once. On an FPGA, it arrives as a **long stream of numbers, one number per clock cycle**, in a specific order.

### The order pixels arrive:

```
Frame starts
    │
    ├─ Pixel (0,0)   ← top-left corner
    ├─ Pixel (1,0)   ← one pixel to the right
    ├─ Pixel (2,0)
    ├─ ... (all pixels in row 0, left to right)
    ├─ Pixel (1919,0) ← end of row 0  [for 1080p]
    │
    ├─ Pixel (0,1)   ← row 1 starts
    ├─ Pixel (1,1)
    ├─ ...
    ├─ Pixel (1919,1079) ← very last pixel of the frame
    │
Frame ends → next frame starts immediately
```

This order is called **raster scan order**. It is the same order a TV draws lines from top to bottom.

### What one pixel looks like in hardware:

For an 8-bit grayscale image:
```
One pixel = one 8-bit number, e.g. 8'b10110011 = 179 (brightness, 0=black, 255=white)
```

For an RGB image:
```
One pixel = three 8-bit numbers arriving simultaneously (or packed into 24 bits)
  R = 8 bits [255 = red,  0 = no red]
  G = 8 bits [255 = green, 0 = no green]
  B = 8 bits [255 = blue,  0 = no blue]
```

**Key point**: at any given clock cycle, your design sees exactly **one pixel**. It does not see the whole image. It never will. You have to build your design around this constraint.

### Pixel formats — what the camera actually sends

Cameras do not all send the same kind of data. Three formats dominate: Bayer RAW8, RGB24, and YUV 4:2:2. Before writing any RTL you must know which one your camera produces, because the wire width, the state machine, and the first processing block all depend on it.

---

#### Format 1 — Bayer RAW8: what a real sensor produces

**The physics first.** A camera sensor chip is a grid of light-sensitive cells called **photosites**. A photosite cannot measure color — it can only measure how much total light landed on it, producing one number. To obtain color, the manufacturer places a colored optical filter over each photosite: a tiny piece of red-, green-, or blue-tinted glass. A photosite sitting under a red filter responds mainly to red light; it ignores blue and green.

The filters are not arranged in three separate rows. They follow the **Bayer pattern**, named after Bryce Bayer (Kodak, 1976):

```
Photosite grid, filter colors:
         col0  col1  col2  col3  col4  col5
 row0:    R     G     R     G     R     G     ...
 row1:    G     B     G     B     G     B     ...
 row2:    R     G     R     G     R     G     ...
 row3:    G     B     G     B     G     B     ...
```

Every 2×2 block is `R G / G B`. Green appears **twice** as often as red or blue because the human eye resolves fine detail mostly from the green part of the spectrum — doubling the green photosites preserves perceived sharpness.

**"RAW" means no processing.** The sensor ships out each photosite's raw reading, untouched — one number per photosite. "8" means 8 bits per reading (values 0–255). Some sensors use RAW10 or RAW12 (10/12 bits) for more precision.

**What this means on the wire:** one clock cycle carries one photosite reading of 8 bits:

```
Cycle:      N      N+1     N+2     N+3     N+4     N+5
TDATA:     R(0,0)  G(1,0)  R(2,0)  G(3,0)  R(4,0)  G(5,0)      ← row 0
           ...
Then row 1 arrives:
TDATA:     G(0,1)  B(1,1)  G(2,1)  B(3,1)  ...
```

Concrete example — the camera images a pure red object (R=200, G=10, B=20 true color). A *red-filtered* photosite reads ~200. But the adjacent *green-filtered* photosite reads only ~10, and the adjacent *blue-filtered* photosite reads ~20. The sensor never learns the red object's full (200, 10, 20) at any single position.

**The consequence for your FPGA:** each pixel arrives knowing only one of the three colors at its position. Before you can compute things like brightness (Y = 0.3R+0.6G+0.1B) or run a color CNN, you must **estimate the missing two colors at every position from the surrounding neighbors** — that estimation step is called **demosaicing**, and it is itself a 3×3/5×5 neighborhood operation (hence another sliding-window stage). You cannot skip it with a Bayer sensor.

**Why bother at all?** Cost andhardware simplicity: one number per photosite instead of three stacked sensors (as in the rare 3-CCD designs). Nearly every affordable camera module (Raspberry Pi IMX219, OV5640 in RAW mode) outputs Bayer.

**TDATA width**: 8 bits/cycle for RAW8. For RAW10 you pack one 10-bit sample per cycle into a 10-bit (or padded 16-bit) TDATA lane; four RAW10 samples are also commonly packed into five bytes (40 bits) by some interfaces — check your sensor datasheet.

---

#### Format 2 — RGB24: every pixel already knows all three colors

**What it is.** The camera (or an upstream chip) has already performed demosaicing internally, so every pixel arrives with its three channels fully formed: 8 bits of red, 8 bits of green, 8 bits of blue — 24 bits per pixel.

**How the three bytes travel on one wire.** AXI4-Stream packs the three bytes side by side into a single 24-bit TDATA value. The Verilog concatenation `{R, G, B}` puts R in the highest bits and B in the lowest:

```
TDATA[23:16] = R        (most significant byte)
TDATA[15:8]  = G
TDATA[7:0]   = B        (least significant byte)
```

Concrete example — a pixel whose true color is R=200, G=100, B=50:

```
R = 200 = 8'hC8
G = 100 = 8'h64
B =  50 = 8'h32

TDATA = {8'hC8, 8'h64, 8'h32} = 24'hC8_6432
```

Cycle-by-cycle, a stream of three such pixels at row 0:

```
Cycle:        N            N+1           N+2
TDATA:   24'hC8_6432  24'hC9_6433  24'hCA_6534     ← consecutive pixels on row 0
```

**Unpacking inside your RTL** is just bit-selecting — no arithmetic:

```verilog
wire [7:0] r = s_tdata[23:16];   // top byte
wire [7:0] g = s_tdata[15:8];    // middle byte
wire [7:0] b = s_tdata[7:0];     // bottom byte
```

**Why cameras sometimes send RGB24 instead of RAW8:**
- The camera module has its own internal ISP (image signal processor) doing demosaic + white balance — you get display-ready pixels with zero FPGA work.
- Downside: **3× the wire bandwidth** for the same resolution/frame rate (24 bits/pixel vs 8). A 1080p60 RGB24 stream needs ~374 MBytes/s before blanking overhead — this is exactly why parallel DVP cameras are often 8-bit RAW, and why video links like HDMI use compression-friendly formats.

---

#### Format 3 — YUV 4:2:2: sending less color because eyes don't notice

**The motivating fact:** the human visual system has far more resolution for **brightness** than for **color**. Blur the color channel of a photo 2× and it still looks sharp; blur brightness 2× and it looks out of focus. Video systems exploit this by transmitting brightness at full resolution and color at half.

**The three components.** Instead of R/G/B, each pixel is described by:
- **Y** — luma: perceived brightness (roughly `Y ≈ 0.3R + 0.6G + 0.1B`)
- **Cb** — the "blueness" difference channel
- **Cr** — the "redness" difference channel

**4:2:2 subsampling** — read it as: for every 4 pixels of width, 4 luma samples but only 2 Cb and 2 Cr samples. Horizontally, color information is sent only on **every other pixel**; each pair of neighboring pixels shares one color reading:

```
True values (conceptually per-pixel):
Pixel 0:  Y0, Cr0, Cb0
Pixel 1:  Y1, Cr0, Cb0        ← shares color with pixel 0
Pixel 2:  Y2, Cr2, Cb2
Pixel 3:  Y3, Cr2, Cb2        ← shares color with pixel 2
```

**What arrives on the wire** (16-bit TDATA, one sample pair per cycle):

```
Cycle:    N        N+1       N+2       N+3
TDATA:  {Y0,Cr0}  {Y1,Cb0}  {Y2,Cr2}  {Y3,Cb2}
         ││  ││    ││   ││
         ││  ││    ││   └┴─ Cb for the (2,3) pair
         ││  ││    └┴────── luma for pixel 1
         ││  ││
         ││  └┴──────────── Cr for the (0,1) pair
         └┴─────────────── luma for pixel 0
```

Average wire cost: **16 bits per pixel** (8+8 alternating), down from 24 for RGB — a 33% bandwidth saving with almost no visible loss.

**The wiring rule for your FPGA:** luma `Y` is present every cycle, but the chroma byte **alternates** — even columns carry Cr, odd columns carry Cb. You must use the **column counter's least significant bit** (`col_cnt[0]`) to know which one is on the wire right now:

```verilog
wire chroma_is_cr = (col_cnt[0] == 1'b0);   // even columns send Cr
wire chroma_is_cb = (col_cnt[0] == 1'b1);   // odd  columns send Cb

// To keep the shared color value, you typically register each chroma
// sample and hold it for the paired neighbor:
reg [7:0] cr_hold, cb_hold;
always @(posedge clk) begin
    if (s_tvalid) begin
        if (chroma_is_cr) cr_hold <= s_tdata[7:0];
        if (chroma_is_cb) cb_hold <= s_tdata[7:0];
    end
end
// For pixel on even col: use (cr=tdata, cb=cb_hold)
// For pixel on odd  col: use (cr=cr_hold, cb=tdata)
```

**When you meet it:** HDMI and most video interfaces transmit YCbCr 4:2:2 or 4:4:4; many camera modules can output YUV422 directly; the Ultrascale+ DisplayPort controller accepts YCbCr natively. If your processing works on brightness only (edge detection, motion), you can **process Y directly and ignore the chroma bytes entirely** — cheap and fast.

---

#### Choosing a format — module boundary summary

```
               your pipeline entry               your pipeline exit
Camera:  Bayer RAW8 ──► [Demosaic] ──► RGB24 ──► [Color convert] ──► YUV422 ──► HDMI/DP
         (8-bit TDATA)   2 line bufs    (24-bit)   3 DSPs, matrix     (16-bit)
                         + window                   multiply
```

- **Input side**: must match what your camera sends. A RAW8 camera feeds the demosaic block; an RGB module skips it.
- **Output side**: must match what your display/encoder expects. HDMI TX IP accepts RGB or YCbCr depending on configuration; the VCU prefers YCbCr 4:2:2.
- Conversions cost hardware (window logic, multipliers) and add pipeline latency — only convert when the next stage actually needs it.

---

## 2. How a Pixel Moves Through the FPGA

Imagine a pixel walking down an assembly line. At each station (each pipeline stage), something happens to it, and then it moves on. By the time it exits the last stage, it has been fully processed.

```
Clock cycle N:    pixel(x,y)   enters Stage 1 (register inputs)
Clock cycle N+1:  pixel(x,y)   is in Stage 2 (multiply by weight)
Clock cycle N+2:  pixel(x,y)   is in Stage 3 (add to accumulator)
Clock cycle N+3:  pixel(x,y)   exits as result(x,y)

Meanwhile:
Clock cycle N+1:  pixel(x+1,y) enters Stage 1 (the next pixel starts immediately!)
Clock cycle N+2:  pixel(x+1,y) is in Stage 2
...
```

This is the **pipeline**. Every clock cycle:
- A new raw pixel **enters** the pipeline at Stage 1
- Every existing pixel **advances** one stage
- A processed pixel **exits** the pipeline at the last stage

**Throughput**: 1 processed pixel per clock cycle (after the pipeline fills up).  
**Latency**: the number of stages = how many cycles before the first result appears.

You build your algorithm by designing what happens at **each stage**.

---

## 3. The Clock — What Happens Every Cycle

The clock is a signal that alternates between 0 and 1 at a fixed rate. At every **rising edge** (0→1 transition), every flip-flop in the design samples its input and stores it.

```
Clock:   ___↑___↑___↑___↑___↑___
              ^   ^   ^   ^   ^
              |   |   |   |   |
              Every one of these "^" is one clock cycle.
              Your entire pipeline advances by one stage here.
```

For a 100 MHz clock:
```
Period = 1 / 100,000,000 = 10 nanoseconds per cycle
1080p frame = 1920 × 1080 = 2,073,600 pixels
Time to process one full frame = 2,073,600 × 10 ns = 20.7 ms ≈ 48 FPS
(To achieve 60 FPS you need ~148.5 MHz — this is why pixel clocks matter)
```

**What you write in Verilog to do something "every clock cycle":**

```verilog
always @(posedge clk) begin
    // Everything here happens once per clock cycle, simultaneously
    output_pixel <= some_operation(input_pixel);
end
```

The `<=` (non-blocking assignment) means: "compute the right side now, store the result at the clock edge". All `<=` assignments in the same `always` block happen at exactly the same time.

---

## 4. Telling the Pipeline Where Lines and Frames Start/End

Your pipeline needs to know three things:
1. Is the current pixel valid (or is the stream idle)?
2. Is this the last pixel on a line?
3. Is this the first pixel of a new frame?

Without this information, you cannot track column/row position and cannot reset state between frames.

### The three control signals

```
TVALID  — 1 = this clock cycle carries a real pixel, 0 = ignore this cycle
TLAST   — 1 = this is the last pixel on the current row (end of line)
TUSER   — 1 = this is the very first pixel of a new frame (start of frame)
```

These are part of the AXI4-Stream standard (see wiki/05). They travel alongside your pixel data through every stage of the pipeline.

### What a 4×3 frame looks like in the stream:

```
Cycle:   1    2    3    4    5    6    7    8    9    10   11   12
TDATA: [0,0][1,0][2,0][3,0][0,1][1,1][2,1][3,1][0,2][1,2][2,2][3,2]
TVALID:  1    1    1    1    1    1    1    1    1    1    1    1
TLAST:   0    0    0    1    0    0    0    1    0    0    0    1
TUSER:   1    0    0    0    0    0    0    0    0    0    0    0
                   ^end of row 0^         ^end of row 1^         ^end of row 2 (also end of frame)^
         ^SOF (start of frame)^
```

**Rule**: Every stage must pass TLAST and TUSER through with the **same number of pipeline register stages** as the data. If your data is delayed by 3 cycles, your TLAST must also be delayed by 3 cycles. Otherwise your pipeline loses track of where rows and frames are.

```verilog
// Delaying control signals by 3 pipeline stages (match your data pipeline):
reg [2:0] tlast_sr, tuser_sr, tvalid_sr;

always @(posedge clk) begin
    tlast_sr  <= {tlast_sr[1:0],  s_tlast};
    tuser_sr  <= {tuser_sr[1:0],  s_tuser};
    tvalid_sr <= {tvalid_sr[1:0], s_tvalid};
end

assign m_tlast  = tlast_sr[2];   // delayed by 3 cycles
assign m_tuser  = tuser_sr[2];
assign m_tvalid = tvalid_sr[2];
```

### Blanking intervals — TVALID goes to 0 during a real stream

A physical camera does not output one pixel per clock continuously. Between each row, and between frames, there are gaps called **blanking intervals** where no pixel is transmitted:

```
←── H-blank ──→ ←─── active row (TVALID=1) ───→ ←── H-blank ──→ ┐
                                                                  ├ vertical blank (V-blank)
←── H-blank ──→ ←─── active row (TVALID=1) ───→ ←── H-blank ──→ │  between frames
         ...                                                      │
←─ whole V-blank (many rows missing, TVALID=0 for a long time) ──┘
```

- **H-bandwidth (row) gap**: the sensor settles between rows, often hundreds of idle clock cycles.
- **V-blank (frame) gap**: the sensor re-arms between frames, often thousands of idle clocks.

**What this means for your design:**
- Your pixel clock must be faster than the active-pixel rate, not exactly equal to it.
  Example: to send 148.5 MPsixels/s of active pixels you need ≥150 MHz, because blanking time reduces usable throughput.
- During blanking the pipeline sits idle — this is normal, not a bug.
- The line buffers and sliding window state should NOT be reset in H-blank; they wrap to the next row automatically at TLAST.
- You *can* use V-blank to do per-frame housekeeping (resetting accumulator, reloading weights) since no pixels are arriving.

### Row and column counters — tracking position in the frame

Many filters need to know "which pixel am I on?" You track position with two counters:

- **Column counter** (`col_cnt`) — counts from 0 up to `WIDTH-1` on each `TVALID=1`, resets to 0 when `TLAST=1`
- **Row counter** (`row_cnt`) — increments each time `TLAST=1` fires, resets to 0 when `TUSER=1` fires (new frame)

```verilog
reg [11:0] col_cnt;   // supports widths up to 4095
reg [11:0] row_cnt;   // supports heights up to 4095

always @(posedge clk) begin
    if (!rst_n) begin
        col_cnt <= 0;
        row_cnt <= 0;
    end else if (s_tvalid && s_tready) begin
        if (s_tuser) begin
            // First pixel of a new frame — reset both
            col_cnt <= 12'd1;
            row_cnt <= 12'd0;
        end else if (s_tlast) begin
            // End of row: reset column, advance row
            col_cnt <= 12'd0;
            row_cnt <= row_cnt + 1'b1;
        end else begin
            col_cnt <= col_cnt + 1'b1;
        end
    end
end
```

These counters feed:
- The sliding window logic (knows when to fetch next-row pixels from BRAM)
- The Bayer phase register (toggles between RGGB / BGGR pattern per row)
- Any logic that needs "line N of 1080" (e.g. BG thresholds that vary per row)

---

## 5. Handshaking — Valid and Ready

A problem: what if your downstream module cannot accept a pixel this cycle? For example, the DMA that writes to DDR is momentarily busy.

The AXI4-Stream handshake adds a **TREADY** signal going backwards from consumer to producer:
- **TVALID** = producer says "I have data"
- **TREADY** = consumer says "I can accept data"
- A transfer happens **only when both TVALID and TREADY are 1 at the same clock edge**

```
Producer:  TVALID: 1  1  1  1  1  1
Consumer:  TREADY: 1  1  0  0  1  1
                   ^  ^        ^  ^
                   |  |        |  |
Transfer:    YES  YES  NO  NO  YES YES
```

When TREADY=0 (consumer busy), the producer must **hold** its data stable and keep TVALID=1 until TREADY goes back to 1.

**For simple pixel pipelines**: if your pipeline is purely combinational/registered and always running, TREADY is usually tied to 1 (always ready). You only need full TREADY backpressure when connecting to variable-latency things like DDR or FIFOs.

---

## 6. Storing One Pixel

A single pixel is stored in a **flip-flop** (register):

```verilog
reg [7:0] pixel_reg;

always @(posedge clk) begin
    if (tvalid)
        pixel_reg <= pixel_in;   // latch the pixel on each valid clock
end
```

One 8-bit register = 8 flip-flops. This is essentially free in terms of FPGA resources.

**Use case**: buffering a pixel for one cycle while you compute something that takes one cycle.

---

## 7. Storing a Row of Pixels — Shift Registers

To access pixel (x-1, y) while processing pixel (x, y) — the previous pixel on the same row — use a shift register:

```
Cycle N:   pixel(x,  y) → [reg_A] → [reg_B] → [reg_C]
Cycle N+1: pixel(x+1,y) → [reg_A] → [reg_B] → [reg_C]
                                                   ^
                                            reg_C holds pixel(x-2,y)
                                            reg_B holds pixel(x-1,y)
                                            reg_A holds pixel(x,  y)   ← current
```

```verilog
reg [7:0] pixel_d1, pixel_d2;   // "d1" = delayed 1 cycle, "d2" = delayed 2 cycles

always @(posedge clk) begin
    pixel_d1 <= pixel_in;        // 1 cycle ago
    pixel_d2 <= pixel_d1;        // 2 cycles ago
end

// Now you have simultaneous access to 3 horizontal neighbors:
// pixel_in  = current pixel  (x,   y)
// pixel_d1  = left neighbor  (x-1, y)
// pixel_d2  = two left       (x-2, y)
```

**Limitation**: this only gives you pixels on the **current row**. To access pixels from previous rows, you need line buffers.

---

## 8. Storing a Full Line — Line Buffers (BRAM)

To access pixel (x, y-1) — the pixel **directly above** in the previous row — you need to remember an entire row worth of pixels. For 1080p grayscale:

```
1920 pixels × 8 bits = 15,360 bits = ~15 KB
```

This is too much for flip-flops (each FF is 1 bit), but it fits in one 18 Kb BRAM block.

### What a line buffer does:

```
Row 0 arrives → pixels written into BRAM, one by one
Row 1 arrives → simultaneously:
                  - Row 1 pixels written into BRAM (overwriting row 0's storage)
                  - Row 0 pixels read back out of BRAM
                  → you now have row 0 (from BRAM) and row 1 (current) at the same time
```

```verilog
// Circular BRAM-based line buffer for 1920-pixel rows, 8-bit grayscale
reg  [7:0] line_buf [0:1919];       // synthesis infers BRAM from this array
reg  [10:0] col_cnt;                 // counts 0..1919
wire [7:0]  current_pixel = pixel_in;
wire [7:0]  previous_row_pixel;

// Write current pixel into BRAM:
always @(posedge clk) begin
    if (tvalid) begin
        line_buf[col_cnt] <= current_pixel;    // write this row
        col_cnt <= (tlast) ? 11'd0 : col_cnt + 1;
    end
end

// Read previous row from BRAM (registered output = 1-cycle latency):
assign previous_row_pixel = line_buf[col_cnt];  // reads row N while writing row N+1
```

**Result**: at the same clock cycle you have:
- `current_pixel` = pixel at (x, y)      ← row N
- `previous_row_pixel` = pixel at (x, y-1) ← row N-1, read from BRAM

---

## 9. Accessing a 3×3 Neighborhood — Sliding Window

A 3×3 neighborhood requires:
- 3 pixels on the **current** row: (x-1,y), (x,y), (x+1,y) → use 2-element shift register
- 3 pixels on the **row above**: (x-1,y-1), (x,y-1), (x+1,y-1) → shift register on top of line buffer 1
- 3 pixels on the **row two above**: (x-1,y-2), (x,y-2), (x+1,y-2) → shift register on top of line buffer 2

### The complete structure:

```
Pixel stream (left to right, row by row)
         │
         ▼
   ┌─────────────────────────────────────────────────────┐
   │  Current row shift register (2 FFs)                  │
   │  [x+1,y]   [x,y]   [x-1,y]                          │
   └─────────────┬───────────────────────────────────────┘
                 │  writes to BRAM every cycle
                 ▼
   ┌─────────────────────────────────────────────────────┐
   │  Line Buffer 0 (BRAM, 1920 pixels)                   │
   │  Outputs pixel (x, y-1)                              │
   └─────────────┬───────────────────────────────────────┘
                 │  feeds shift register
                 ▼
   ┌─────────────────────────────────────────────────────┐
   │  Row y-1 shift register (2 FFs)                      │
   │  [x+1,y-1] [x,y-1] [x-1,y-1]                        │
   └─────────────┬───────────────────────────────────────┘
                 │  writes to BRAM every cycle
                 ▼
   ┌─────────────────────────────────────────────────────┐
   │  Line Buffer 1 (BRAM, 1920 pixels)                   │
   │  Outputs pixel (x, y-2)                              │
   └─────────────────────────────────────────────────────┘
                 │  feeds shift register
                 ▼
   ┌─────────────────────────────────────────────────────┐
   │  Row y-2 shift register (2 FFs)                      │
   │  [x+1,y-2] [x,y-2] [x-1,y-2]                        │
   └─────────────────────────────────────────────────────┘
```

After the structure fills (which takes 2 full rows + 1 pixel), every clock cycle you have all 9 pixels simultaneously available:

```
p[0][0]  p[1][0]  p[2][0]     ← row y-2, columns x-1, x, x+1
p[0][1]  p[1][1]  p[2][1]     ← row y-1
p[0][2]  p[1][2]  p[2][2]     ← row y   (current)
```

```verilog
// All 9 wires available simultaneously, every clock cycle:
wire [7:0] p00, p01, p02;   // top row    (y-2)
wire [7:0] p10, p11, p12;   // middle row (y-1)
wire [7:0] p20, p21, p22;   // bottom row (y, current)

// Feed these directly into mac_array_3x3 (the module from earlier)
```

**Cost**: 2 BRAM blocks (one per line buffer) + 6 flip-flops (3 shift registers × 2 FFs each).

### Warm-up — when the first valid output appears

The sliding window structure must fill before any output is correct. Until then, the BRAM holds either residual data from the previous frame or uninitialized junk. Three rules govern valid output:

1. **Row 0 of the frame** — no previous rows exist yet, so there are no "row y−1" or "row y−2" pixels. Output for row 0 is **invalid** (or must be generated with edge handling — see the next section).
2. **Row 1** — same story; the second line buffer has not been filled. Output for row 1 is **invalid**.
3. **From row 2 onward** — both line buffers have real data from rows y−1 and y−2. The sliding window is valid.

```
Video frame (rows 0..1079):
Row 0    → invalid output (no prior rows)
Row 1    → invalid output (only one prior row)
Row 2+   → VALID output (full 3-row window available)
```

Implement by gating the output with `row_cnt >= 2`:

```verilog
assign output_tvalid = input_tvalid & (row_cnt >= 12'd2);
```

The upstream pipeline (camera → demosaic → color convert) delays the start of the frame by some constant; the 3×3 stage must account for its own additional warm-up on top of that.

### Edge handling — pixels beyond the image border

What does the 3×3 window show when x = 0 (leftmost column)? Or y = 0 (top row)?

```
Pixel (0,0) of frame — window is mostly invalid:

Window for pixel(0,0):
  p00 p01 p02   ← row -1: does not exist
  p10 p11 p12   ← row 0, p10 = x-1 = -1: does not exist
  p20 p21 p22   ← row 1: p20 = x-1 = -1: does not exist
```

Four common strategies:

| Strategy | Logic | Difficulty | AWB/junk artifact visible |
|----------|-------|-----------|--------------------------|
| **Zero pad** | Set missing pixels to 0 | Trivial | Dark border on bright edges |
| **Clamp to edge** | Replicate the nearest valid pixel (p00→p01, p10→p11, p20→p21) | Easy | Small smearing on borders |
| **Skip output** | Set TVALID=0 on the first/last pixel of each row and first/last row of each frame | Easy | Frame is 1920→1918×1080→1078 (dimensions shrink) |
| **None (allowed)** | Just let the window wrap and produce garbage at the borders | Trivial | Corrupted border pixels |

Example: clamp to edge, implemented with a priority index:

```verilog
wire [7:0] p10 = (x_pos == 12'd0) ? p11 : p10_raw;  // clamp left edge
wire [7:0] p20 = (x_pos == 12'd0) ? p21 : p20_raw;  // clamp left edge
```

---

## 10. Your First Operation — Pixel-Level Brightness

This is the simplest possible operation. It touches only the current pixel — no neighbors needed.

**Goal**: increase brightness by adding a constant offset.

```verilog
module brightness_adjust (
    input  wire        clk,
    input  wire        tvalid,
    input  wire [7:0]  pixel_in,
    input  wire [7:0]  offset,      // from AXI-Lite register (ARM sets this)
    output reg         tvalid_out,
    output reg  [7:0]  pixel_out
);
    wire [8:0] sum = {1'b0, pixel_in} + {1'b0, offset};  // 9-bit to catch overflow

    always @(posedge clk) begin
        tvalid_out <= tvalid;
        pixel_out  <= sum[8] ? 8'hFF : sum[7:0];   // saturate at 255
    end
endmodule
```

**What this does, cycle by cycle:**

| Clock | pixel_in | offset | sum (9-bit) | pixel_out |
|-------|----------|--------|------------|-----------|
| 1     | 200      | 100    | 300 → overflow | 255 (clamped) |
| 2     | 50       | 100    | 150            | 150       |
| 3     | 0        | 100    | 100            | 100       |

**Pipeline latency**: 1 cycle (one register stage).  
**Throughput**: 1 pixel per clock.  
**Resources**: 1 adder (uses carry chain, not DSP), 8 FFs for output register.

---

## 11. Your Second Operation — 3×3 Blur

A box blur replaces each pixel with the average of its 3×3 neighborhood:

```
result(x,y) = (p00 + p01 + p02 + p10 + p11 + p12 + p20 + p21 + p22) / 9
```

Division by 9 is expensive. The standard approximation: divide by 8 (right-shift by 3) — close enough for a blur and completely free in hardware.

### Step-by-step pipeline for 3×3 box blur:

```
Stage 1 — Register the 9 inputs (break long routing paths):
    s1_p00..s1_p22 <= p00..p22   (9 × 8-bit registers)

Stage 2 — Add pairs (reduces 9 values to 5):
    s2_a <= s1_p00 + s1_p01    (9-bit result, 1 carry bit to prevent overflow)
    s2_b <= s1_p02 + s1_p10
    s2_c <= s1_p11 + s1_p12
    s2_d <= s1_p20 + s1_p21
    s2_e <= s1_p22              (no pair — odd one out)

Stage 3 — Add pairs again (reduces 5 to 3):
    s3_f <= s2_a + s2_b          (10-bit)
    s3_g <= s2_c + s2_d          (10-bit)
    s3_h <= s2_e                 (carry forward)

Stage 4 — Final sum:
    s4_sum <= s3_f + s3_g + s3_h   (12-bit total)

Stage 5 — Divide by 8 and saturate:
    result <= s4_sum[10:3]          // >> 3 = divide by 8, take 8 bits
```

**Why add in this tree pattern** (not `a+b+c+d+...` left to right)?
- Left-to-right chain: 8 additions deep → long critical path → low Fmax
- Tree: only 3 addition levels deep → short critical path → high Fmax

```
Left-to-right (slow):    Tree (fast):
((((((((p00+p01)+p02)+p10)+p11)+p12)+p20)+p21)+p22)
         8 adders in series          vs          3 levels of adders in parallel
```

**Latency**: 5 clock cycles.  
**Throughput**: 1 pixel per clock (after the 5-cycle fill time).  
**Resources**: ~20 LUTs, 2 BRAM blocks (line buffers), 0 DSPs.

---

## 12. Pipeline Stages — Latency and Throughput

These two concepts are always confused. They are independent.

### Latency = how long until the first result

The number of pipeline register stages a pixel passes through before it exits.

```
  Input  → [Stage 1] → [Stage 2] → [Stage 3] → Output
  cycle 1:  pixel_A enters
  cycle 2:  pixel_A in stage 2,  pixel_B enters stage 1
  cycle 3:  pixel_A in stage 3,  pixel_B in stage 2,  pixel_C in stage 1
  cycle 4:  pixel_A EXITS,       pixel_B in stage 3,  pixel_C in stage 2, pixel_D in stage 1
                 ↑
         Latency = 3 cycles for a 3-stage pipeline
```

**Latency matters for**:
- Aligning control signals (TLAST must be delayed by exactly 3 cycles too)
- Knowing how many frames the system takes to "warm up"
- Round-trip time for closed-loop control

### Throughput = how many results per clock, once running

For a purely pipelined design: **1 pixel per clock**, regardless of how many stages.

```
1920 × 1080 = 2,073,600 pixels
At 100 MHz: 2,073,600 / 100,000,000 = 20.7 ms per frame = ~48 FPS
At 148.5 MHz: 1920×1080 / 148,500,000 = 13.9 ms = 72 FPS (above the 60 FPS target)
```

**The rule**: as long as your pipeline never stalls (backpressure), throughput = 1 pixel/clock, and you need clock_frequency ≥ pixels_per_frame × target_fps.

### Pushing past 1 pixel/clock — multilane pixels

When the target exceeds 400 MPixels/s (4K@60 or 8K), a single-pixel pipeline hits timing limits. The standard solution is to process **two or four pixels per clock cycle** in parallel lanes.

```
Single-pixel pipeline (1x):
  Clock cycle N: process pixel(x, y)     → 1 pixel/cycle

Dual-pixel pipeline (2x):
  Clock cycle N: process pixel(2x, y)   and  pixel(2x+1, y)   → 2 pixels/cycle

Quad-pixel pipeline (4x):
  Clock cycle N: process pixels(4x..4x+3, y)    → 4 pixels/cycle
```

**What changes:**
- **TDATA width doubles or quadruples**: 8-bit grayscale becomes 16 or 32 bits; RGB24 becomes 48 or 96 bits.
- **Sliding window**: you keep the same 3×3 window but pack 2 or 4 independent windows into one wide register (the Xilinx Video Processing Subsystem does this automatically).
- **Line buffers**: BRAM banks are wider; you write two adjacent pixels at once.
- **DSP count** roughly doubles or quadruples, but you can use fewer distinct blocks because each DSP48E2 can be split into two independent multipliers in many modes.
- **Frame time halves** (or quarters): 4K@60 (predominantly unachievable at 1x ~600 MHz) becomes achievable at 150 MHz in 4x mode.

The Xilinx `Video Processing Subsystem` (formerly VPSS) IP supports 1x/2x/4x pixel modes and reconfigures itself dynamically — this is the recommended approach for high-throughput video.

---

## 13. Storing a Full Frame — When You Need DDR

Some algorithms cannot work in a streaming (line-buffer) fashion. They need the entire frame to be available at once:

| Algorithm | Why it needs the full frame | Can stream? |
|-----------|-----------------------------|------------|
| Gaussian blur 3×3 | Needs only 3 rows | YES (2 line buffers) |
| Sobel edge detect | Needs only 3 rows | YES (2 line buffers) |
| Histogram equalization | Needs CDF of full frame | NO |
| Optical flow | Needs previous full frame | NO (needs 2 frames) |
| JPEG compression | DCT on 8×8 blocks | PARTIAL (8-row buffer) |
| Background subtraction | Needs background model frame | NO |

For algorithms that need the full frame, the workflow is:

```
Frame N arrives as pixel stream
         │
         ▼
[AXI VDMA — write channel]
  Writes each pixel to DDR as it arrives
  Uses HP AXI port on Zynq PS
         │
         ▼
[DDR — frame buffer A]  ← holds frame N
         │
  (when frame N is fully written, signal to ARM or start read)
         ▼
[AXI VDMA — read channel]
  Reads pixels from DDR back out as a stream
         │
         ▼
[Your algorithm module]
  Receives the frame again as a stream, but can now also
  make random-access reads to DDR for the frame data
```

### DDR bandwidth check (1080p, 8-bit grayscale):

```
Frame size    = 1920 × 1080 × 1 byte = 2.07 MB
At 60 FPS     = 2.07 MB × 60 = 124 MB/s write + 124 MB/s read = 248 MB/s total
DDR4 bandwidth ≈ 10,000 MB/s typical
→ 248 / 10,000 = 2.5% of DDR bandwidth — very comfortable
```

For RGB (3 bytes per pixel): multiply by 3 → still under 10%.  
DDR bandwidth only becomes a concern for 4K, multi-camera, or ML workloads.

---

## 14. End-to-End Pipeline Summary

Putting everything together: a camera pixel entering the FPGA until a processed pixel exits.

```
CAMERA SENSOR
     │  raw pixel data (Bayer pattern, 8 or 10 bits per clock)
     │  + PCLK (pixel clock), HSYNC, VSYNC  ← separate clock domain!
     ▼

CLOCK DOMAIN CROSSING
     [Async FIFO]  ← mandatory: camera PCLK ≠ FPGA fabric clock
     │  converts (PCLK domain) → (FPGA 100 MHz domain)
     │  output: pixel_data + TVALID + TLAST + TUSER
     ▼

STAGE 1 — DEMOSAIC
     [2 line buffers + 3×3 window]
     Bayer (1 channel) → RGB (3 channels)
     Latency: 2 rows + 1 pixel
     Cost: 2 BRAMs, ~50 LUTs
     ▼

STAGE 2 — COLOR CONVERT (optional)
     RGB → Grayscale (or YCbCr)
     3 multiplies + 2 adds + right-shift
     Latency: 2 cycles
     Cost: 3 DSPs
     ▼

STAGE 3 — YOUR PROCESSING
     [2 line buffers + 3×3 sliding window] → [mac_array_3x3]
     Applies filter/CNN/Sobel/blur etc.
     Latency: 2 rows + 5 cycles
     Cost: 2 BRAMs, 9 DSPs
     ▼

STAGE 4 — OUTPUT
     ├─ To HDMI display: [AXI4-Stream → Video Out IP] → HDMI TX
     └─ To ARM CPU:      [AXI DMA] → DDR → Linux → Python
     ▼

DISPLAY / HOST
```

### Checklist before you write any RTL

- [ ] I know the camera's output pixel format (Bayer RAW8? RGB565? YUV422?)
- [ ] I know the camera's clock (PCLK frequency) and that it is **not** the same as my fabric clock
- [ ] I will put an async FIFO between the camera clock domain and my fabric
- [ ] Every stage passes TLAST and TUSER through with matching delay
- [ ] Every BRAM line buffer size matches the actual image width (not hardcoded to 1920 if the camera is 640×480)
- [ ] I have checked the accumulator bit width is wide enough (Section 11, blur example: 12 bits)
- [ ] I am not using floating point anywhere in the pixel path
- [ ] The pixel clock frequency ≥ pixels_per_frame × fps

---

## 15. Common Mistakes and How to Avoid Them

These are the errors that take the most time to debug because simulation often does not reveal them. Check this list before bringing code to the debugger.

### 1. TUSER fires more than once per frame
TUSER must pulse **exactly on the first pixel of a frame**, then stay 0 for the remaining ~2 million cycles. If it fires on 2 pixels, your row counter resets twice, and every row after that is off by one row in the phase of the Bayer filter — output looks like a staircase colour pattern.

**Debug**: Use ILA, trigger on `tuser == 1`, verify it fires exactly once per frame period.

### 2. TLAST fires on the wrong pixel
TLAST must assert on the **last** pixel of each row (index 1919 for 1080p), not the first or a random one. A row counter that advances at the wrong moment makes every subsequent row's sliding window misaligned — output appears as a horizontal shift or a ghost echo shifted by one pixel.

**Debug**: On ILA, count `TVALID` events between consecutive `TLAST` pulses; it must equal exactly 1920.

### 3. Pipeline control signals not latency-matched
If the data path is 5-stage pipelined but TVALID/TLAST/TUSER are only 3-stage, the control metadata unlocks from the data — the frame starts/stops at different points than the pixels, which corrupts downstream counters.

**Debug**: Run `report_timing` on each control net; add extra `reg` stages to match data.

### 4. Edge pixels not handled — border artifacts
If you apply a 3×3 box filter at column 0 with a neighbour at column −1 (which wraps to column 1919 of the previous row's end), you get bright smearing along the left border and dark smearing along the right border of the output.

**Debug**: Look at the first and last column of your output; if they look shifted or clipped, enable edge clamping (copy the nearest valid pixel instead). See Section 9 for strategies.

### 5. The pipeline runs at 1× but the clock is not fast enough
For example, 4K `3840×2160×60 = 497 MHz` at 1 pixel/clock cannot be achieved in 7-series architecture. The design synthesises, the constraint check passes, but on the hardware the pixel counter jumps because the signal pulse width narrows below the fabric's setup time.

**Debug**: Check if the pixel clock exceed ~250 MHz for 7-series / ~350 MHz for UltraScale+ (non-SLR). If yes, switch to 2× or 4× pixel mode (Section 12).

### 6. Using `tvalid` to enable the clock
Never use `tvalid` (or any data signal) as a clock enable for pixel registers. It is a data signal, not a clock enable. This triggers timing violations and removes the tool's ability to optimise the path properly.

**Correct**: always use `if (tvalid && tready)` inside `always @(posedge clk)`.

### 7. YUV 4:2:2 chroma halves not tracked
YUV 422 streams deliver `Y` every pixel but `Cr` and `Cb` only on alternating pixels. If you assume every pixel has both, a colour-shifted gradient appears.

**Fix**: Use the column counter parity to select whether the current pixel's chroma is `Cr` or `Cb`.

---

## 16. Connecting a Real Camera — The Receiver FSM

A parallel (DVP) camera delivers data on 8 or 10 parallel wires plus three control signals (PCLK, HREF, VSYNC). The receiver module samples these and hands the stream onward in AXI4-Stream format.

### The DVP signals

| Camera output | Direction | Meaning |
|---------------|-----------|---------|
| `PCLK` | camera → FPGA | Pixel clock (rises once per pixel) |
| `DATA[7:0]` or `DATA[9:0]` | camera → FPGA | Raw pixel value, stable when HREF=1 |
| `HREF` | camera → FPGA | 1 = this pixel is on an active row (horizontal blank when 0) |
| `VSYNC` | camera → FPGA | 1 = a full frame is in progress |

### Minimum receiver states

```
state: IDLE
  condition: VSYNC rises → start of frame
  action: TUSER=1, transition to ACTIVE

state: ACTIVE
  condition: HREF=1 → this cycle has a valid pixel
  action: sample DATA, assert TVALID and TLAST at end of row
  condition: VSYNC falls → end of frame
  action: return to IDLE
```

### Where the CDC happens

All receiver output must cross into the FPGA fabric clock domain before any processing:

```
PCLK domain (camera clock)      FPGA fabric clock domain
[Receiver FSM] ──▶ [Async FIFO] ──▶ [Your pipeline]
   (sample HREF,        (width: 18 bits
    VSYNC, data          10 data + TVALID + TLAST + TUSER + row/col)
    at PCLK edge)
```

The async FIFO handles the rate difference (camera PCLK often ≠ system clock) safely. On the consumer side, the XC7 or UltraScale+ `FIFO18E1` / `FIFO36E1` primitive or Xilinx `xpm_fifo_async` macros both work; `xpm_fifo_async` is recommended.

For MIPI CSI-2 cameras, use the Vivado MIPI CSI-2 Receiver Subsystem IP instead — it handles the D-PHY lanes and outputs AXI4-Stream direct to your pipeline.

---

**Previous**: [10 — Zynq UltraScale+ Reference](../hardware/10_ZYNQ_ULTRASCALE_REFERENCE.md)  
**Next**: [12 — OV5647 MIPI Camera Path on the AXU2CGB](./12_OV5647_MIPI_CAMERA_PATH.md)  
**Back to index**: [00 — Wiki Index](../00_INDEX.md)
