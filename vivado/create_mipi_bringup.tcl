# =============================================================================
#  create_mipi_bringup.tcl
#
#  Creates the MIPI1/J23 OV5647 bring-up project for ALINX AXU2CGB-E.
#  Target part : xczu2cg-sfvc784-1-e
#  I2C control : Zynq PS I2C0 via EMIO (use xiicps.h in Vitis)
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

# Use a short root path to avoid Windows 260-char OOC synthesis errors ([Common 17-1257])
set proj_dir   "C:/fpga/mipi_bringup"
set part       xczu2cg-sfvc784-1-e

# ---------------------------------------------------------------------------
# Helper: find latest version of an IP in the catalog
# ---------------------------------------------------------------------------
proc find_ip {name} {
    set hits [get_ipdefs -filter "NAME == $name" -all]
    if {[llength $hits] == 0} {
        error "IP '$name' not found — check IP repositories and Vivado version."
    }
    return [lindex $hits end]
}

# ===========================================================================
# 1.  Project
# ===========================================================================
puts "INFO: Creating project at $proj_dir ..."
create_project mipi_bringup $proj_dir -part $part -force
set_property default_lib xil_defaultlib [current_project]

# ===========================================================================
# 2.  Constraints  (mipi1.xdc — J23 confirmed pins: AH13/AE13/AG13/AH14)
# ===========================================================================
set xdc_path [file normalize [file join $repo_root src constraints mipi1.xdc]]
add_files -fileset constrs_1 -norecurse $xdc_path
set_property USED_IN_SYNTHESIS      true [get_files [file tail $xdc_path]]
set_property USED_IN_IMPLEMENTATION true [get_files [file tail $xdc_path]]
puts "INFO: Added $xdc_path"

# ===========================================================================
# 3.  Block design
# ===========================================================================
create_bd_design "mipi_bd"

# ---------------------------------------------------------------------------
# 3a.  Zynq UltraScale+ MPSoC
#       PL0   = 100 MHz      (drives all 100 MHz PL logic & clk_wiz_0)
#       UART0 = Disabled
#       UART1 = MIO 24..25   (PuTTY serial console)
#       I2C0  = EMIO         (routed to cam1_i2c_scl_io AH13 / cam1_i2c_sda_io AE13)
#       M_AXI_HPM0_FPD       (PS -> PL AXI master for MIPI CSI-2 Rx registers)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip zynq_ultra_ps_e] zynq_ultra_ps_e_0
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE                   {1}            \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ    {100}          \
    CONFIG.PSU__USE__M_AXI_GP0                    {1}            \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH               {32}           \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE         {1}            \
    CONFIG.PSU__UART1__PERIPHERAL__IO             {MIO 24 .. 25} \
    CONFIG.PSU__I2C0__PERIPHERAL__ENABLE          {1}            \
    CONFIG.PSU__SD1__PERIPHERAL__IO               {MIO 46 .. 51} \
    CONFIG.PSU__SD1__GRP_CD__ENABLE               {1}            \
    CONFIG.PSU__SD1__GRP_CD__IO                   {MIO 45}       \
] [get_bd_cells zynq_ultra_ps_e_0]

# ---------------------------------------------------------------------------
# 3b.  Processor System Reset
#       Synchronised to pl_clk0 (100 MHz); held in reset until clk_wiz locks.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip proc_sys_reset] proc_sys_reset_0

connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ---------------------------------------------------------------------------
# 3c.  Clocking Wizard  (100 MHz PS pl_clk0 -> 200 MHz D-PHY ref + 24 MHz clk_out2)
#       clk_out1 = 200 MHz  -> MIPI CSI-2 Rx dphy_clk_200M
#       clk_out2 =  24 MHz  -> cam1_clk (J23 pin 12, AG13)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip clk_wiz] clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_SOURCE                       {Global_buffer} \
    CONFIG.PRIM_IN_FREQ                      {99.999001}     \
    CONFIG.NUM_OUT_CLKS                      {2}             \
    CONFIG.CLKOUT1_USED                      {true}          \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ        {200.000}       \
    CONFIG.CLKOUT2_USED                      {true}          \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ        {24.000}        \
    CONFIG.RESET_TYPE                        {ACTIVE_LOW}    \
    CONFIG.RESET_PORT                        {resetn}        \
] [get_bd_cells clk_wiz_0]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]    [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins clk_wiz_0/locked]             [get_bd_pins proc_sys_reset_0/dcm_locked]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins clk_wiz_0/resetn]

# ---------------------------------------------------------------------------
# 3d.  MIPI CSI-2 Receiver Subsystem  (PG232)
#       2 lanes, RAW8, 4 pixels/clock, D-PHY 400 Mbps, Shared Logic in Core
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip mipi_csi2_rx_subsystem] mipi_csi2_rx_subsystem_0
set_property -dict [list \
    CONFIG.CMN_NUM_LANES            {2}      \
    CONFIG.CMN_PXL_FORMAT           {RAW8}   \
    CONFIG.CMN_NUM_PIXELS           {4}      \
    CONFIG.DPY_LINE_RATE            {400}    \
    CONFIG.SupportLevel             {1}      \
] [get_bd_cells mipi_csi2_rx_subsystem_0]

create_bd_intf_port -mode Slave \
    -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if
connect_bd_intf_net \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/mipi_phy_if] \
    [get_bd_intf_ports mipi_phy_if]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/dphy_clk_200M]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/lite_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/video_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/lite_aresetn]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/video_aresetn]

# ---------------------------------------------------------------------------
# 3e.  AXI Interconnect  (1 Master: PS -> MIPI CSI-2 Rx csirxss_s_axi)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axi_interconnect] axi_interconnect_0
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_interconnect_0]

connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/csirxss_s_axi]

foreach port {ACLK S00_ACLK M00_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
        [get_bd_pins axi_interconnect_0/$port]
}
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN]
foreach port {S00_ARESETN M00_ARESETN} {
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins axi_interconnect_0/$port]
}
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]

# ---------------------------------------------------------------------------
# 3f.  PS I2C0 (EMIO) -> External cam1_i2c Interface
#       Generates top-level IOBUFs: cam1_i2c_scl_io (AH13), cam1_i2c_sda_io (AE13)
# ---------------------------------------------------------------------------
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 cam1_i2c
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/IIC_0] \
    [get_bd_intf_ports cam1_i2c]

# ---------------------------------------------------------------------------
# 3g.  AXI4-Stream Data FIFO  (buffers MIPI Rx video_out for ILA capture)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axis_data_fifo] axis_data_fifo_0
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES  {4}    \
    CONFIG.FIFO_DEPTH       {4096} \
    CONFIG.TUSER_WIDTH      {1}    \
    CONFIG.HAS_TLAST        {1}    \
] [get_bd_cells axis_data_fifo_0]

connect_bd_intf_net \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/video_out] \
    [get_bd_intf_pins axis_data_fifo_0/S_AXIS]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axis_data_fifo_0/s_axis_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axis_data_fifo_0/s_axis_aresetn]

create_bd_cell -type ip -vlnv [find_ip xlconstant] xlconstant_tready
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    [get_bd_cells xlconstant_tready]
connect_bd_net [get_bd_pins xlconstant_tready/dout] \
    [get_bd_pins axis_data_fifo_0/m_axis_tready]

# ---------------------------------------------------------------------------
# 3i.  CAM1 CLK output  (J23 pin 12 -> AG13, LVCMOS33)
# ---------------------------------------------------------------------------
create_bd_port -dir O cam1_clk
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_ports cam1_clk]

# ---------------------------------------------------------------------------
# 3j.  CAM1 GPIO [0:0]  (J23 pin 11 -> AH14, LVCMOS33 — Power Enable HIGH)
# ---------------------------------------------------------------------------
create_bd_port -dir O -from 0 -to 0 cam1_gpio
create_bd_cell -type ip -vlnv [find_ip xlconstant] xlconstant_gpio
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    [get_bd_cells xlconstant_gpio]
connect_bd_net [get_bd_pins xlconstant_gpio/dout] [get_bd_ports cam1_gpio]

# ---------------------------------------------------------------------------
# 3k.  AXI Address Map
# ---------------------------------------------------------------------------
assign_bd_address -offset 0xA0000000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs mipi_csi2_rx_subsystem_0/csirxss_s_axi/Reg] -force

# ===========================================================================
# 4.  Regenerate layout, generate wrapper, set top
# ===========================================================================
save_bd_design
regenerate_bd_layout

set wrapper [make_wrapper -files [get_files mipi_bd.bd] -top]
add_files -norecurse $wrapper
set_property top mipi_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
save_bd_design

puts "============================================================"
puts " Project created cleanly at: $proj_dir/mipi_bringup.xpr"
puts " PS I2C0 (EMIO) -> cam1_i2c (AH13/AE13), CAM1_GPIO -> AH14"
puts "============================================================"