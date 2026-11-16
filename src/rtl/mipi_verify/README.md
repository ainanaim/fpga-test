# MIPI Camera Data-Path Verification (PL side)

Layered bring-up modules that prove the OV5647 MIPI camera stream is being
received and moved correctly through the Zynq UltraScale+ PL fabric on the
AXU2CGB-E board.

Each module isolates one failure domain. Run them in order — when a layer
fails, the bug is in that layer's logic, not in the MIPI link itself.

## Background

These modules apply the techniques from two translated ALINX tutorials:

- `wiki/14_ALINX_FPGA_COURSE1.md` — Verilog building blocks, ILA debug,
  on-chip RAM, the recurring Vivado PL flow.
- `wiki/13_VITIS_GETTING_STARTED.md` — Vitis app project, AXI DMA driver,
  DDR buffer access from the ARM.
- `wiki/12_OV5647_MIPI_CAMERA_PATH.md` — the MIPI CSI-2 Rx IP output
  interface (AXI4-Stream: `tvalid`/`tlast`/`tuser[0]`/`tdata`).

## Files

| File | Layer | Purpose |
|------|-------|---------|
| `ila_mipi_wrapper.v` | 0 | ILA-only — probe the MIPI Rx IP output, no logic. |
| `mipi_stats.v` | 1 | Count pixels / lines / frames received. The single most useful bring-up module. |
| `line_buffer_passthrough.v` | 2 | Capture one row into BRAM, re-emit it on a second AXI-Stream. Proves the PL can process, not just receive. |

Layers 3 (DMA → PS DDR → ARM dump) and 4 (display) are block-design +
Vitis work, not standalone RTL — see `wiki/13_VITIS_GETTING_STARTED.md`
for the Vitis side and the conversation notes for the connection list.

## The four AXI-Stream signals you are verifying

| Signal | Meaning | "Working" looks like |
|--------|---------|---------------------|
| `tvalid` | Pixel present this cycle | Pulses high during active pixels, low in blanking |
| `tuser[0]` | Start of Frame | 1 cycle per frame |
| `tlast` | End of Line | 1 pulse per row (1080 for 1080p) |
| `tdata` | The pixel(s) | Non-zero, varying, follows the Bayer pattern |

## Bring-up order

1. **Layer 0** — instantiate `ila_mipi_wrapper` on the MIPI Rx IP output.
   Trigger on `tvalid` rising, then `tuser=1`, then count `tlast`. ~30 min.
2. **Layer 1** — replace the wrapper with `mipi_stats`. Attach ILA to the
   counters. Confirm `frame_cnt` ticks at the frame rate, `line_cnt`
   reaches the row count per frame, `pixel_cnt` never stalls. ~1 h.
3. **Layer 2** — insert `line_buffer_passthrough` between the MIPI Rx IP
   and a downstream sink. Put ILA on both sides and compare. ~2 h.
4. **Layer 3** — add AXI DMA (S2MM) in the block design, write to PS DDR,
   dump the buffer from Vitis. ~half a day.
5. **Layer 4** — feed the stream to the HDMI/LCD path (Course 1 Ch.14/16)
   or the PS DisplayPort. The "it works" moment.

## Conventions

- All modules use `rst_n` (active-low, asynchronous) to match the ALINX
  board's PL key wiring (Course 1 Ch.4).
- All modules are parameterised on data width and (where relevant) line
  length so they work for RAW8, RAW10, 720p, 1080p, etc.
- AXI-Stream handshaking: `tvalid`/`tready` both high → transfer. For
  bring-up, `tready` is tied to 1 so the source never stalls.
