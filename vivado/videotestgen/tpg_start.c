/* Bare-metal app: PL Test Pattern Generator -> PS DisplayPort (miniDP), live video.
 * Order matters: the PL video clock (dp_video_ref_clk) only runs once the PS
 * pixel clock is programmed, so DP is brought up first, then VTC and TPG start. */
#include <stdio.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "sleep.h"
#include "xv_tpg.h"
#include "xvtc.h"
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"

#define VMODE   XVIDC_VM_1920x1080_60_P
#define W       1920
#define H       1080

static XV_tpg tpg;
static XVtc vtc;
static XDpPsu dp;
static XAVBuf avbuf;

static void dump_status(const char *tag)
{
    u32 base = dp.Config.BaseAddr;
    xil_printf("[%s] HPD/sig=0x%08x link_rate=0x%02x lanes=%d mainlink=%d\r\n", tag,
        XDpPsu_ReadReg(base, XDPPSU_INTERRUPT_SIG_STATE),
        dp.LinkConfig.LinkRate, dp.LinkConfig.LaneCount,
        (int)XDpPsu_ReadReg(base, XDPPSU_ENABLE_MAIN_STREAM));
    xil_printf("[%s] TPG ctrl=0x%08x idle=%d  VTC ctl=0x%08x  AVBUF vidsel=0x%08x clksrc=0x%08x\r\n", tag,
        XV_tpg_ReadReg(tpg.Config.BaseAddress, XV_TPG_CTRL_ADDR_AP_CTRL),
        (int)XV_tpg_IsIdle(&tpg),
        XVtc_ReadReg(vtc.Config.BaseAddress, XVTC_CTL_OFFSET),
        XAVBuf_ReadReg(avbuf.Config.BaseAddr, XAVBUF_BUF_OUTPUT_AUD_VID_SELECT),
        XAVBuf_ReadReg(avbuf.Config.BaseAddr, XAVBUF_BUF_AUD_VID_CLK_SOURCE));
}

int main(void)
{
    u32 st;
    XDpPsu_Config *dcfg;
    XVtc_Config *vcfg;

    xil_printf("\r\n=== videotestgen: TPG -> PS DP live video ===\r\n");

    if (XV_tpg_Initialize(&tpg, XPAR_XV_TPG_0_BASEADDR) != XST_SUCCESS) {
        xil_printf("TPG init FAILED\r\n");
        return -1;
    }
    vcfg = XVtc_LookupConfig(XPAR_XVTC_0_BASEADDR);
    if (!vcfg) { xil_printf("VTC lookup FAILED\r\n"); return -1; }
    XVtc_CfgInitialize(&vtc, vcfg, vcfg->BaseAddress);

    dcfg = XDpPsu_LookupConfig(XPAR_XDPPSU_0_BASEADDR);
    if (!dcfg) { xil_printf("DP lookup FAILED\r\n"); return -1; }
    XDpPsu_CfgInitialize(&dp, dcfg, dcfg->BaseAddr);
    XAVBuf_CfgInitialize(&avbuf, dcfg->BaseAddr);

    st = XDpPsu_InitializeTx(&dp);
    xil_printf("DP InitializeTx: %s (%d)\r\n", st == XST_SUCCESS ? "OK" : "FAIL", (int)st);
    if (st != XST_SUCCESS) { dump_status("init"); return -1; }

    xil_printf("Waiting for monitor (HPD)...\r\n");
    for (int i = 0; i < 100 && !XDpPsu_IsConnected(&dp); i++) usleep(100000);
    if (!XDpPsu_IsConnected(&dp)) { xil_printf("NO monitor detected on HPD\r\n"); dump_status("hpd"); return -1; }
    xil_printf("Monitor connected\r\n");

    xil_printf("DP regs: AUX_CLK_DIV=0x%08x PHY_CFG=0x%08x PHY_STATUS=0x%08x SAxiClk=%u\r\n",
        XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_AUX_CLK_DIVIDER),
        XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_PHY_CONFIG),
        XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_PHY_STATUS),
        (unsigned)dp.SAxiClkHz);
    {
        u8 b[16] = {0};
        u32 r0 = XDpPsu_AuxRead(&dp, 0x000, 1, b);
        xil_printf("AUX 1-byte DPCD[0]: st=%d val=0x%02x\r\n", (int)r0, b[0]);
        u8 edid[128] = {0};
        u32 re = XDpPsu_GetEdidBlock(&dp, edid, 0);
        xil_printf("EDID block0 read: st=%d hdr=%02x%02x%02x%02x\r\n", (int)re, edid[0], edid[1], edid[2], edid[3]);
    }
    for (int i = 0; i < 10; i++) {
        u8 pwr = 1;
        XDpPsu_AuxWrite(&dp, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &pwr);
        usleep(200000);
        st = XDpPsu_GetRxCapabilities(&dp);
        xil_printf("RX caps try %d: st=%d (max rate 0x%02x, max lanes %d) AUXsig=0x%x reply=0x%x\r\n", i, (int)st,
            dp.LinkConfig.MaxLinkRate, dp.LinkConfig.MaxLaneCount,
            XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_INTERRUPT_SIG_STATE),
            XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_AUX_REPLY_CODE));
        if (st == XST_SUCCESS) break;
    }
    if (st != XST_SUCCESS || !dp.LinkConfig.MaxLaneCount) {
        xil_printf("AUX read of sink DPCD failed\r\n");
        xil_printf("AUX_CLK_DIVIDER=0x%08x SAxiClkHz=%u\r\n",
            XDpPsu_ReadReg(dp.Config.BaseAddr, XDPPSU_AUX_CLK_DIVIDER), (unsigned)dp.SAxiClkHz);
        return -1;
    }
    XDpPsu_CfgMainLinkMax(&dp);
    st = XDpPsu_EstablishLink(&dp);
    xil_printf("Link training: %s (%d), rate 0x%02x lanes %d\r\n",
        st == XST_SUCCESS ? "OK" : "FAIL", (int)st,
        dp.LinkConfig.LinkRate, dp.LinkConfig.LaneCount);
    if (st != XST_SUCCESS) { dump_status("train"); return -1; }

    XAVBuf_InputVideoSelect(&avbuf, XAVBUF_VIDSTREAM1_LIVE, XAVBUF_VIDSTREAM2_NONE);
    XAVBuf_SetInputLiveVideoFormat(&avbuf, RGB_8BPC);
    XAVBuf_SetOutputVideoFormat(&avbuf, RGB_8BPC);
    XAVBuf_SetAudioVideoClkSrc(&avbuf, XAVBUF_PL_CLK, XAVBUF_PS_CLK);
    XAVBuf_ConfigureVideoPipeline(&avbuf);
    XAVBuf_ConfigureOutputVideo(&avbuf);
    XAVBuf_SoftReset(&avbuf);

    XDpPsu_CfgMsaUseStandardVideoMode(&dp, VMODE);
    XDpPsu_CfgMsaSetBpc(&dp, 8);
    XDpPsu_CfgMsaEnSynchClkMode(&dp, 0);
    st = XAVBuf_SetPixelClock(dp.MsaConfig.PixelClockHz);
    xil_printf("Pixel clock %u Hz: %d\r\n", (unsigned)dp.MsaConfig.PixelClockHz, (int)st);
    XDpPsu_SetVideoMode(&dp);

    XVtc_EnableGenerator(&vtc);
    XVtc_RegUpdateEnable(&vtc);

    XV_tpg_Set_height(&tpg, H);
    XV_tpg_Set_width(&tpg, W);
    XV_tpg_Set_colorFormat(&tpg, 0);
    XV_tpg_Set_bckgndId(&tpg, XTPG_BKGND_COLOR_BARS);
    XV_tpg_Set_ovrlayId(&tpg, 0);
    XV_tpg_EnableAutoRestart(&tpg);
    XV_tpg_Start(&tpg);

    XDpPsu_EnableMainLink(&dp, 1);
    xil_printf("TPG started: %dx%d color bars, main link enabled\r\n", W, H);

    for (int n = 0;; n++) {
        dump_status("run");
        sleep(2);
    }
}
