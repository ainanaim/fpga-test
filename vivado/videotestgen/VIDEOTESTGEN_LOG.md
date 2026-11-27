# videotestgen log: Test pattern generator to miniDP (ALINX AXU2CGB-E)

Goal: a simple Xilinx-IP video generator in PL, shown on a monitor through the PS DisplayPort (miniDP) connector.
Part: `xczu2cg-sfvc784-1-e`. Tools: Vivado 2020.1-style script, Vitis 2026.1 (SDT flow).

## Architecture

`v_tpg` -> `v_axi4s_vid_out` (timed by `v_tc`, 1080p60) -> PS "DP live video from PL" -> miniDP.
- Video clock: PS `dp_video_ref_clk` = 148.5 MHz (VPLL), also fed back to `dp_video_in_clk`.
- Control: PS `M_AXI_HPM0_FPD` -> AXI interconnect -> `v_tpg` (s_axi_CTRL) and `v_tc` (ctrl).
- DP pins are fixed PS pins (GT lanes, 27 MHz ref clock on Ref Clk2, AUX/HPD on MIO 27-30). No PL XDC pin assignments needed.

## Files

| File | Purpose |
|---|---|
| `create_videotestgen.tcl` | Creates project `C:/fpga/videotestgen` and block design `vtg_bd` |
| `videotestgen.xdc` | `create_clock` on PS `DPVIDEOREFCLK` |
| `tpg_start.c` | Vitis bare-metal app: DP bring-up, TPG start, status prints |

## Incremental changes

1. **Initial script and app.** TPG/VTC/vid_out/PS DP design, PS config (UART1 MIO 24-25, DP Dual Higher, Ref Clk2 27 MHz, AUX MIO 27-30), `tpg_start.c` starting TPG only.
2. **BD error: `maxihpm0_lpd_aclk` not connected.** Cause: the LPD AXI master was enabled by default. Fix: `PSU__USE__M_AXI_GP1=0` and `PSU__USE__M_AXI_GP2=0`.
3. **Q: XDC needed?** No. DP pins are PS-fixed, no PL external ports.
4. **Methodology TIMING-17 (1000 critical warnings).** Video-domain logic had no timing clock. Fix: `videotestgen.xdc` with `create_clock` (6.734 ns) on `DPVIDEOREFCLK`, added in the script. Vivado later gave an advisory about an inefficient `get_pins` query; harmless. Do not add the XDC twice.
5. **RGB packing fix.** Plain concat put the 24 bits in `[23:0]` with no channel mapping. New mapping (from an AMD forum report, not verified against UG1085): R `vid_data[23:16]` -> `pixel1[23:16]`, G `[7:0]` -> `[11:4]`, B `[15:8]` -> `[35:28]`, 4-bit gaps = 0. Built with 3 xlslice + xlconstant(4) + 6-port xlconcat. A review claim that xlconcat puts In0 at the MSB was wrong (In0 is the LSB).
6. **"Discontinued" labels** on concat/constant/interconnect in the diagram are only catalog tags; the blocks work. SmartConnect is an optional replacement for the interconnect.
7. **DSP DPIP-2/DPOP-3 warnings.** Pipelining advisories from `v_tpg`; ignored.
8. **Safety check.** No PL pins driven, DP pins fixed on the PS. Verify MIO usage against the schematic before programming; use JTAG boot mode.
9. **PS config additions.** SD1 (MIO 46-51, CD MIO 45, SD 2.0) and DDR4 (MT40A256M16, 64-bit, 2400R, CL17/CWL12). UART1 was already set. DDR timing is not the full GUI preset; re-select the preset in the GUI if needed.
10. **Applying changes to an existing project.** Via Tcl Console: `set_property` on `zynq_ultra_ps_e_0`, and delete `pix_cat`/`pix_zero` then create the slice/concat block. The RGB rewrite was not yet applied in the user's diagram at the time of the last check.
11. **Vitis project setup.** New platform `vidtest_platform` from the new XSA, new app `vidtest_app`; `dppsu` driver is in the BSP. Do not reuse `mipi_platform`/`mipi_app`.
12. **SDT API fix in `tpg_start.c`.** `XPAR_V_TPG_0_DEVICE_ID` undeclared; use `XPAR_XV_TPG_0_BASEADDR` and `XPAR_XVTC_0_BASEADDR`. Use `XTPG_BKGND_COLOR_BARS` (value 9; 1 is the horizontal ramp).
13. **Nothing on the monitor.** The first app never brought up DisplayPort. Rewrote `tpg_start.c`: DP init -> HPD wait -> RX caps -> link training -> AV buffer live video RGB 8bpc -> pixel clock -> VTC -> TPG -> enable main link, with periodic status prints. The video clock only runs after the pixel clock is programmed, so DP comes first.
14. **Current status.** On hardware: `DP InitializeTx` OK, monitor detected (HPD), but `GetRxCapabilities` returned 22 (`XST_ERROR_COUNT_MAX`, AUX timeout), max rate 0, lanes 0. Added: sink power-up write (DPCD 0x600), up to 10 retries, AUX register prints, stop on failure.

## Open items

- Rebuild and read the "RX caps try N" output.
- If AUX still times out: check MIO bank voltage and AUX level shifter, `AUX_CLK_DIVIDER` value, and MIO 27-30 mapping against the schematic.
- Apply the RGB slice/concat change in the block design and regenerate.
- Verify the RGB channel mapping on the monitor (colour bars).
- Check timing summary: WNS >= 0 and `dp_video_ref_clk` listed in `report_clocks`.

## `tpg_start.c` reference

The file has two functions, `dump_status()` and `main()`, plus these driver calls.

### Functions in the file

| Function | What it does |
|---|---|
| `dump_status(tag)` | Prints the DP HPD/signal state, link rate, lane count and main-link enable, then the TPG control register and idle flag, the VTC control register, and the AV buffer video-select and clock-source registers. Used for debugging; `main()` calls it on failure and every 2 s at the end. |
| `main()` | Runs the whole bring-up in the order below. Returns -1 at the first failing step. |

### `main()` steps and the driver calls used

| Step | Calls | Purpose |
|---|---|---|
| 1. Init TPG | `XV_tpg_Initialize(&tpg, XPAR_XV_TPG_0_BASEADDR)` | Binds the TPG driver to its AXI-Lite base address. |
| 2. Init VTC | `XVtc_LookupConfig`, `XVtc_CfgInitialize` | Binds the video timing controller driver. |
| 3. Init DP and AV buffer | `XDpPsu_LookupConfig`, `XDpPsu_CfgInitialize`, `XAVBuf_CfgInitialize` | Binds the PS DisplayPort controller and the AV buffer manager (same base address). |
| 4. DP controller init | `XDpPsu_InitializeTx` | Resets the DP core, sets the AUX clock divider, brings the PHY out of reset, enables the core and the HPD interrupts. |
| 5. Wait for monitor | `XDpPsu_IsConnected` | Polls the HPD pin for up to 10 s. |
| 6. Read sink capabilities | `XDpPsu_AuxWrite` (DPCD 0x600 = 1), `XDpPsu_GetRxCapabilities` | Wakes the sink, then reads its DPCD to get max link rate and lane count. Retries up to 10 times. |
| 7. Link setup and training | `XDpPsu_CfgMainLinkMax`, `XDpPsu_EstablishLink` | Picks the highest rate and lanes both ends support, then runs link training. |
| 8. Video pipeline | `XAVBuf_InputVideoSelect` (live), `XAVBuf_SetInputLiveVideoFormat` / `XAVBuf_SetOutputVideoFormat` (RGB 8 bpc), `XAVBuf_SetAudioVideoClkSrc` (PL clock), `XAVBuf_ConfigureVideoPipeline`, `XAVBuf_ConfigureOutputVideo`, `XAVBuf_SoftReset` | Selects live video from the PL and sets its format and clock source. |
| 9. Timing and pixel clock | `XDpPsu_CfgMsaUseStandardVideoMode` (1080p60), `XDpPsu_CfgMsaSetBpc(8)`, `XDpPsu_CfgMsaEnSynchClkMode(0)`, `XAVBuf_SetPixelClock`, `XDpPsu_SetVideoMode` | Fills in the main-stream attributes, programs the video PLL to the pixel clock (this starts `dp_video_ref_clk`), and writes the mode to the DP core. |
| 10. Start the PL video | `XVtc_EnableGenerator`, `XVtc_RegUpdateEnable`, then `XV_tpg_Set_*`, `XV_tpg_EnableAutoRestart`, `XV_tpg_Start` | Starts the timing generator, then sets the TPG to 1920x1080 RGB colour bars and starts it free-running. |
| 11. Enable output | `XDpPsu_EnableMainLink(&dp, 1)` | Starts sending video on the main link. |
| 12. Monitor loop | `dump_status("run")`, `sleep(2)` | Prints status forever. |

## Why the order matters

The PL video clock (`dp_video_ref_clk`) is generated by the PS and only runs after step 9, so the VTC and TPG are started after it.
