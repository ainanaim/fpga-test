# =============================================================================
#  create_videotestgen.tcl
#
#  Test-pattern generator -> PS DisplayPort (miniDP) on ALINX AXU2CGB-E.
#    v_tpg (Xilinx Video Test Pattern Generator) -> v_axi4s_vid_out <- v_tc
#    -> PS "DP live video from PL" -> miniDP (1920x1080 @ 60, 148.5 MHz)
#
#  Usage:  vivado -mode batch -source create_videotestgen.tcl
#  Target part : xczu2cg-sfvc784-1-e   (Vivado 2020.1)
#  After the bitstream, run tpg_start.c in Vitis to start the TPG.
# =============================================================================

set proj_dir "C:/fpga/videotestgen"
set part     xczu2cg-sfvc784-1-e

proc find_ip {name} {
    set hits [get_ipdefs -filter "NAME == $name" -all]
    if {[llength $hits] == 0} { error "IP '$name' not found." }
    return [lindex $hits end]
}

create_project videotestgen $proj_dir -part $part -force
create_bd_design "vtg_bd"

# ---------------- Zynq PS ----------------
create_bd_cell -type ip -vlnv [find_ip zynq_ultra_ps_e] zynq_ultra_ps_e_0
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1}   \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ   {100} \
    CONFIG.PSU__USE__M_AXI_GP0                   {1}   \
    CONFIG.PSU__USE__M_AXI_GP1                   {0}   \
    CONFIG.PSU__USE__M_AXI_GP2                   {0}   \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH              {32}  \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE        {1}   \
    CONFIG.PSU__UART1__PERIPHERAL__IO            {MIO 24 .. 25} \
    CONFIG.PSU__SD1__PERIPHERAL__ENABLE          {1}   \
    CONFIG.PSU__SD1__PERIPHERAL__IO              {MIO 46 .. 51} \
    CONFIG.PSU__SD1__GRP_CD__ENABLE              {1}   \
    CONFIG.PSU__SD1__GRP_CD__IO                  {MIO 45} \
    CONFIG.PSU__SD1__SLOT_TYPE                   {SD 2.0} \
    CONFIG.PSU__DDRC__ENABLE                     {1}   \
    CONFIG.PSU__DDRC__MEMORY_TYPE                {DDR 4} \
    CONFIG.PSU__DDRC__COMPONENTS                 {Components} \
    CONFIG.PSU__DDRC__DEVICE_CAPACITY            {4096 MBits} \
    CONFIG.PSU__DDRC__DRAM_WIDTH                 {16 Bits} \
    CONFIG.PSU__DDRC__BUS_WIDTH                  {64 Bit} \
    CONFIG.PSU__DDRC__SPEED_BIN                  {DDR4_2400R} \
    CONFIG.PSU__DDRC__ROW_ADDR_COUNT             {15} \
    CONFIG.PSU__DDRC__COL_ADDR_COUNT             {10} \
    CONFIG.PSU__DDRC__BG_ADDR_COUNT              {1}  \
    CONFIG.PSU__DDRC__CL                         {17} \
    CONFIG.PSU__DDRC__CWL                        {12} \
    CONFIG.PSU_BANK_0_IO_STANDARD                {LVCMOS18} \
    CONFIG.PSU_BANK_1_IO_STANDARD                {LVCMOS18} \
    CONFIG.PSU_BANK_2_IO_STANDARD                {LVCMOS18} \
    CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__SRCSEL  {RPLL} \
    CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__SRCSEL    {RPLL} \
    CONFIG.PSU__CRF_APB__TOPSW_MAIN_CTRL__SRCSEL    {APLL} \
    CONFIG.PSU__DISPLAYPORT__PERIPHERAL__ENABLE  {1}   \
    CONFIG.PSU__DPAUX__PERIPHERAL__IO            {MIO 27 .. 30} \
    CONFIG.PSU__DP__LANE_SEL                     {Dual Higher}  \
    CONFIG.PSU__DP__REF_CLK_SEL                  {Ref Clk2}     \
    CONFIG.PSU__DP__REF_CLK_FREQ                 {27}  \
    CONFIG.PSU__USE__VIDEO                       {1}   \
    CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__SRCSEL  {VPLL} \
    CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__FREQMHZ {148.5} \
] [get_bd_cells zynq_ultra_ps_e_0]

create_bd_cell -type ip -vlnv [find_ip proc_sys_reset] rst_pl
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]    [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]

create_bd_cell -type ip -vlnv [find_ip proc_sys_reset] rst_vid
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/dp_video_ref_clk] [get_bd_pins rst_vid/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]       [get_bd_pins rst_vid/ext_reset_in]

# ---------------- Video Test Pattern Generator ----------------
create_bd_cell -type ip -vlnv [find_ip v_tpg] v_tpg_0
set_property -dict [list \
    CONFIG.SAMPLES_PER_CLOCK {1}   \
    CONFIG.MAX_COLS          {1920} \
    CONFIG.MAX_ROWS          {1080} \
    CONFIG.MAX_DATA_WIDTH    {8}   \
] [get_bd_cells v_tpg_0]

# ---------------- Video Timing Controller (generator, 1080p60) ----------------
create_bd_cell -type ip -vlnv [find_ip v_tc] v_tc_0
set_property -dict [list \
    CONFIG.INTERFACE_TYPE        {AXI_Lite}     \
    CONFIG.enable_detection      {false}        \
    CONFIG.enable_generation     {true}         \
    CONFIG.GEN_VIDEO_MODE        {1080p}        \
] [get_bd_cells v_tc_0]

# ---------------- AXI4-Stream to Video Out ----------------
create_bd_cell -type ip -vlnv [find_ip v_axi4s_vid_out] v_axi4s_vid_out_0
set_property -dict [list \
    CONFIG.C_PIXELS_PER_CLOCK   {1}      \
    CONFIG.C_HAS_ASYNC_CLK      {1}      \
    CONFIG.VTG_MASTER_SLAVE     {1}      \
    CONFIG.C_S_AXIS_VIDEO_FORMAT {2}     \
    CONFIG.C_S_AXIS_VIDEO_DATA_WIDTH {8} \
] [get_bd_cells v_axi4s_vid_out_0]

# TPG stream (pl_clk0 domain) -> vid_out (async FIFO) -> video clock domain
connect_bd_intf_net [get_bd_intf_pins v_tpg_0/m_axis_video] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
connect_bd_intf_net [get_bd_intf_pins v_tc_0/vtiming_out]   [get_bd_intf_pins v_axi4s_vid_out_0/vtiming_in]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]              [get_bd_pins v_tpg_0/ap_clk]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn]              [get_bd_pins v_tpg_0/ap_rst_n]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]              [get_bd_pins v_axi4s_vid_out_0/aclk]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn]              [get_bd_pins v_axi4s_vid_out_0/aresetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/dp_video_ref_clk]     [get_bd_pins v_axi4s_vid_out_0/vid_io_out_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/dp_video_ref_clk]     [get_bd_pins zynq_ultra_ps_e_0/dp_video_in_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/dp_video_ref_clk]     [get_bd_pins v_tc_0/clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/dp_video_ref_clk]     [get_bd_pins v_tc_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_vid/peripheral_aresetn]             [get_bd_pins v_tc_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_vid/peripheral_aresetn]             [get_bd_pins v_tc_0/resetn]
connect_bd_net [get_bd_pins rst_vid/peripheral_reset]               [get_bd_pins v_axi4s_vid_out_0/vid_io_out_reset]
connect_bd_net [get_bd_pins v_tc_0/gen_clken]                       [get_bd_pins v_axi4s_vid_out_0/vtg_ce]

# Video out -> PS live video input
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_active_video] [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_de]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_hsync]        [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_hsync]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_vsync]        [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_vsync]

# vid_data (Xilinx RBG order): R=[23:16] B=[15:8] G=[7:0]
# PS DP live pixel1 (36b): B=[35:28] R=[23:16] G=[11:4]; 4-bit gaps tied to 0.
# xlconcat: In0 = LSBs.  {B, 4'b0, R, 4'b0, G, 4'b0}
foreach {n hi lo} {sl_r 23 16  sl_b 15 8  sl_g 7 0} {
    create_bd_cell -type ip -vlnv [find_ip xlslice] $n
    set_property -dict [list CONFIG.DIN_WIDTH {24} CONFIG.DIN_FROM $hi CONFIG.DIN_TO $lo CONFIG.DOUT_WIDTH 8] [get_bd_cells $n]
    connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data] [get_bd_pins $n/Din]
}
create_bd_cell -type ip -vlnv [find_ip xlconstant] pix_zero
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {4}] [get_bd_cells pix_zero]
create_bd_cell -type ip -vlnv [find_ip xlconcat] pix_cat
set_property -dict [list CONFIG.NUM_PORTS {6}     CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {8} CONFIG.IN2_WIDTH {4}     CONFIG.IN3_WIDTH {8} CONFIG.IN4_WIDTH {4} CONFIG.IN5_WIDTH {8}] [get_bd_cells pix_cat]
connect_bd_net [get_bd_pins pix_zero/dout] [get_bd_pins pix_cat/In0]
connect_bd_net [get_bd_pins sl_g/Dout]     [get_bd_pins pix_cat/In1]
connect_bd_net [get_bd_pins pix_zero/dout] [get_bd_pins pix_cat/In2]
connect_bd_net [get_bd_pins sl_r/Dout]     [get_bd_pins pix_cat/In3]
connect_bd_net [get_bd_pins pix_zero/dout] [get_bd_pins pix_cat/In4]
connect_bd_net [get_bd_pins sl_b/Dout]     [get_bd_pins pix_cat/In5]
connect_bd_net [get_bd_pins pix_cat/dout]  [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_pixel1]

# ---------------- AXI-Lite: PS -> TPG + VTC ----------------
create_bd_cell -type ip -vlnv [find_ip axi_interconnect] axi_ic
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_ic]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins v_tpg_0/s_axi_CTRL]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M01_AXI] [get_bd_intf_pins v_tc_0/ctrl]
foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_ic/$p]
}
connect_bd_net [get_bd_pins rst_pl/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
foreach p {S00_ARESETN M00_ARESETN M01_ARESETN} {
    connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins axi_ic/$p]
}
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]

# v_tc AXI-Lite shares the video clock above; tie it to pl_clk0 instead to match the interconnect
disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins v_tc_0/s_axi_aclk]] [get_bd_pins v_tc_0/s_axi_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins v_tc_0/s_axi_aclk]
disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins v_tc_0/s_axi_aresetn]] [get_bd_pins v_tc_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins v_tc_0/s_axi_aresetn]

assign_bd_address
validate_bd_design
save_bd_design

make_wrapper -files [get_files vtg_bd.bd] -top
add_files -norecurse [file normalize $proj_dir/videotestgen.srcs/sources_1/bd/vtg_bd/hdl/vtg_bd_wrapper.v]
set_property top vtg_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

add_files -fileset constrs_1 -norecurse [file join [file dirname [file normalize [info script]]] videotestgen.xdc]

puts "INFO: Block design created. Run synth/impl/bitstream, export XSA (include bitstream)."
