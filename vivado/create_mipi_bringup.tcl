# =============================================================================
#  vivado/create_mipi_bringup.tcl
#
#  Creates the MIPI1/J23 OV5647 bring-up project for ALINX AXU2CGB-E.
#  Target part : xczu2cg-sfvc784-1-e
#
#  Usage — from Vivado Tcl console (repo root as working directory):
#    source vivado/create_mipi_bringup.tcl
#
#  Or from terminal:
#    vivado -mode batch -source vivado/create_mipi_bringup.tcl
#
#  After completion, open:
#    vivado/mipi_bringup/mipi_bringup.xpr
#
#  One manual step remaining after opening in Vivado (see note at end):
#    Connect ILA probe ports to the AXI-Stream FIFO output signals.
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set proj_dir   [file join $script_dir mipi_bringup]
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
# 2.  Constraints  (mipi1.xdc — J23 confirmed pins)
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
# 3a.  External port: 25 MHz PL reference clock (board pin AB11)
# ---------------------------------------------------------------------------
create_bd_port -dir I -type clk -freq_hz 25000000 pl_ref_clk
set_property CONFIG.CLK_DOMAIN {pl_ref_clk} [get_bd_ports pl_ref_clk]

# ---------------------------------------------------------------------------
# 3b.  Zynq UltraScale+ MPSoC
#       FCLK0 = 100 MHz  (drives all 100 MHz PL logic)
#       UART0 = MIO 2..3 (PuTTY output)
#       M_AXI_HPM0_FPD   (PS→PL AXI master for register access)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip zynq_ultra_ps_e] zynq_ultra_ps_e_0
set_property -dict [list \
    CONFIG.PSU__FCLK0__PERIPHERAL__ENABLE         {1}          \
    CONFIG.PSU__FCLK0__PERIPHERAL__FREQMHZ        {100}        \
    CONFIG.PSU__USE__M_AXI_GP0                    {1}          \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH               {32}         \
    CONFIG.PSU__UART0__PERIPHERAL__ENABLE         {1}          \
    CONFIG.PSU__UART0__PERIPHERAL__IO             {MIO 42 .. 43} \
    CONFIG.PSU__SD1__PERIPHERAL__ENABLE           {1}          \
    CONFIG.PSU__SD1__PERIPHERAL__IO               {MIO 46 .. 51} \
    CONFIG.PSU__SD1__GRP_CD__ENABLE               {1}          \
    CONFIG.PSU__SD1__GRP_CD__IO                   {MIO 45}     \
] [get_bd_cells zynq_ultra_ps_e_0]

# ---------------------------------------------------------------------------
# 3c.  Processor System Reset
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
# 3d.  Clocking Wizard  (25 MHz PL ref → 200 MHz D-PHY ref + 24 MHz XCLK)
#       clk_out1 = 200 MHz  → MIPI CSI-2 Rx dphy_clk_200M
#       clk_out2 =  24 MHz  → cam1_clk XCLK output to OV5647 (pin AG13)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip clk_wiz] clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_SOURCE                       {Single_ended_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ                      {25.000}  \
    CONFIG.NUM_OUT_CLKS                      {2}       \
    CONFIG.CLKOUT1_USED                      {true}    \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ        {200.000} \
    CONFIG.CLKOUT2_USED                      {true}    \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ        {24.000}  \
    CONFIG.RESET_TYPE                        {ACTIVE_LOW} \
    CONFIG.RESET_PORT                        {resetn}  \
] [get_bd_cells clk_wiz_0]

connect_bd_net [get_bd_ports pl_ref_clk]            [get_bd_pins clk_wiz_0/clk_in1]

# Lock signal from clock wizard → proc_sys_reset dcm_locked
connect_bd_net [get_bd_pins clk_wiz_0/locked]       [get_bd_pins proc_sys_reset_0/dcm_locked]

# Clocking wizard reset: tied to pl_resetn0 (active-low)
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins clk_wiz_0/resetn]

# ---------------------------------------------------------------------------
# 3e.  MIPI CSI-2 Receiver Subsystem  (PG232)
#       2 lanes, RAW8, D-PHY mode, 400 Mbps
#       Pin locations confirmed from AXU2CGB-E BANK64 schematic.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip mipi_csi2_rx_subsystem] mipi_csi2_rx_subsystem_0
set_property -dict [list \
    CONFIG.CMN_NUM_LANES            {2}      \
    CONFIG.CMN_PXL_FORMAT           {RAW8}   \
    CONFIG.DPY_LINE_RATE            {400}    \
    CONFIG.SupportLevel             {0}      \
    CONFIG.CLK_LANE_IO_LOC          {AC9}    \
    CONFIG.CLK_LANE_IO_LOC_NAME     {IO_L1P_T0L_N0_DBC_64}   \
    CONFIG.DATA_LANE0_IO_LOC        {AE9}    \
    CONFIG.DATA_LANE0_IO_LOC_NAME   {IO_L2P_T0L_N2_64}       \
    CONFIG.DATA_LANE1_IO_LOC        {AB8}    \
    CONFIG.DATA_LANE1_IO_LOC_NAME   {IO_L3P_T0L_N4_AD15P_64} \
] [get_bd_cells mipi_csi2_rx_subsystem_0]

# MIPI PHY interface → external port (XDC constrains individual pins)
create_bd_intf_port -mode Slave \
    -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if
connect_bd_intf_net \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/mipi_phy_if] \
    [get_bd_intf_ports mipi_phy_if]

# Clock connections for MIPI IP
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
# 3f.  AXI Interconnect  (PS → MIPI Rx AXI-Lite + AXI IIC)
#       M00 → MIPI CSI-2 Rx  s_axi_lite  (control registers)
#       M01 → AXI IIC        s_axi        (I2C register access)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axi_interconnect] axi_interconnect_0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_interconnect_0]

# PS → AXI interconnect slave
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]
# AXI interconnect → MIPI Rx AXI-Lite
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/s_axi_lite]

# Clocks & resets for AXI interconnect (all 100 MHz from pl_clk0)
foreach port {ACLK S00_ACLK M00_ACLK M01_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
        [get_bd_pins axi_interconnect_0/$port]
}
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN]
foreach port {S00_ARESETN M00_ARESETN M01_ARESETN} {
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins axi_interconnect_0/$port]
}
# HPM0 clock (PS master always driven by pl_clk0)
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]

# ---------------------------------------------------------------------------
# 3g.  AXI IIC  (I2C master for OV5647 SCCB on J23 pins AH13/AE13)
#       Using AXI IIC instead of PS EMIO so the bidirectional SDA/SCL are
#       handled cleanly as cam1_i2c_scl_io / cam1_i2c_sda_io IO ports.
#       In Vitis, use XIic_Send() (xiic_l.h) with XPAR_AXI_IIC_0_BASEADDR.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axi_iic] axi_iic_0

# AXI IIC → AXI interconnect M01
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
    [get_bd_intf_pins axi_iic_0/S_AXI]

# AXI IIC clocks & resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axi_iic_0/s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_iic_0/s_axi_aresetn]

# IIC interface → external IO port
# Generates top-level ports: cam1_i2c_scl_io, cam1_i2c_sda_io  (bidirectional)
# XDC constrains cam1_i2c_scl_io → AH13, cam1_i2c_sda_io → AE13
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 cam1_i2c
connect_bd_intf_net \
    [get_bd_intf_pins axi_iic_0/IIC] \
    [get_bd_intf_ports cam1_i2c]

# ---------------------------------------------------------------------------
# 3h.  AXI4-Stream Data FIFO  (buffers MIPI Rx output for ILA capture)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axis_data_fifo] axis_data_fifo_0
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES  {4}    \
    CONFIG.FIFO_DEPTH       {4096} \
    CONFIG.HAS_TUSER        {1}    \
    CONFIG.TUSER_WIDTH      {1}    \
    CONFIG.HAS_TLAST        {1}    \
] [get_bd_cells axis_data_fifo_0]

# MIPI Rx → FIFO input
connect_bd_intf_net \
    [get_bd_intf_pins mipi_csi2_rx_subsystem_0/m00_axis] \
    [get_bd_intf_pins axis_data_fifo_0/S_AXIS]

# FIFO clock & reset
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axis_data_fifo_0/s_axis_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axis_data_fifo_0/s_axis_aresetn]

# Tie FIFO M_AXIS_TREADY high — consume all data during bring-up
create_bd_cell -type ip -vlnv [find_ip xlconstant] xlconstant_tready
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    [get_bd_cells xlconstant_tready]
connect_bd_net [get_bd_pins xlconstant_tready/dout] \
    [get_bd_pins axis_data_fifo_0/m_axis_tready]

# ---------------------------------------------------------------------------
# 3i.  ILA  (Integrated Logic Analyzer — 5 probes, 4096 depth)
#       probe0[31:0] ← m_axis_tdata
#       probe1[0]    ← m_axis_tvalid
#       probe2[0]    ← m_axis_tlast
#       probe3[0]    ← m_axis_tuser[0]  (frame start)
#       probe4[0]    ← m_axis_tready    (= 1, constant)
#
#       *** MANUAL STEP: connect these probes in the block design GUI ***
#       The ILA is added and clocked here; probe wires must be connected
#       manually by dragging from axis_data_fifo_0 M_AXIS signals to the
#       ILA probe ports.  Takes ~5 minutes in the GUI.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip ila] ila_0
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES  {5}     \
    CONFIG.C_PROBE0_WIDTH   {32}    \
    CONFIG.C_PROBE1_WIDTH   {1}     \
    CONFIG.C_PROBE2_WIDTH   {1}     \
    CONFIG.C_PROBE3_WIDTH   {1}     \
    CONFIG.C_PROBE4_WIDTH   {1}     \
    CONFIG.C_DATA_DEPTH     {4096}  \
    CONFIG.C_ADV_TRIGGER    {true}  \
    CONFIG.C_EN_STRG_QUAL   {1}     \
] [get_bd_cells ila_0]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins ila_0/clk]

# ---------------------------------------------------------------------------
# 3j.  CAM1 XCLK output  (24 MHz → J23 pin 12 → OV5647 XCLK input)
#       XDC:  PACKAGE_PIN AG13, LVCMOS33
# ---------------------------------------------------------------------------
create_bd_port -dir O cam1_clk
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_ports cam1_clk]

# ---------------------------------------------------------------------------
# 3k.  CAM1 GPIO  (J23 pin 11 → AH14, LVCMOS33)
#       Tie high — holds OV5647 out of hardware reset.
# ---------------------------------------------------------------------------
create_bd_port -dir O cam1_gpio
create_bd_cell -type ip -vlnv [find_ip xlconstant] xlconstant_gpio
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    [get_bd_cells xlconstant_gpio]
connect_bd_net [get_bd_pins xlconstant_gpio/dout] [get_bd_ports cam1_gpio]

# ===========================================================================
# 4.  Regenerate layout, generate wrapper, set top
# ===========================================================================
save_bd_design
regenerate_bd_layout

# Skip validate_bd_design — ILA probes are intentionally unconnected here.
# Run Validate from the GUI after connecting the ILA probes.

set wrapper [make_wrapper -files [get_files mipi_bd.bd] -top]
add_files -norecurse $wrapper
set_property top mipi_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
save_bd_design

# ===========================================================================
puts ""
puts "============================================================"
puts " Project ready: open vivado/mipi_bringup/mipi_bringup.xpr"
puts ""
puts " ONE MANUAL STEP — connect ILA probes (5 min in GUI):"
puts "   Open Diagram (mipi_bd) → double-click ila_0"
puts "   probe0[31:0] ← axis_data_fifo_0 m_axis_tdata"
puts "   probe1[0]    ← axis_data_fifo_0 m_axis_tvalid"
puts "   probe2[0]    ← axis_data_fifo_0 m_axis_tlast"
puts "   probe3[0]    ← axis_data_fifo_0 m_axis_tuser[0]"
puts "   probe4[0]    ← xlconstant_tready dout (= TREADY)"
puts ""
puts " Then: Validate BD → Run Synthesis → Implementation"
puts "        → Generate Bitstream → Export Hardware (.xsa)"
puts " See wiki/vision/12_OV5647_MIPI_CAMERA_PATH.md §10 steps I-K"
puts "============================================================"
