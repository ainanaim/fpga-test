# =============================================================================
#  create_mipi_bringup.tcl
#
#  Creates the MIPI1/J23 OV5647 bring-up project for ALINX AXU2CGB-E.
#  Target part : xczu2cg-sfvc784-1-e
#  I2C control : Zynq PS I2C0 via EMIO (use xiicps.h in Vitis)
#  ILA         : Removed
#  Capture     : Stage A (raw-first) — CSI-2 Rx -> raw10_to_raw8 -> AXIS FIFO
#                -> v_frmbuf_wr (Y8) -> S_AXI_HP0_FPD -> DDR.
#                Demosaic is added in Stage B once the raw image is verified.
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

# Short path to avoid Windows 260-char OOC synthesis errors ([Common 17-1257])
set proj_dir   "C:/fpga/mipi_bringup"
set part       xczu2cg-sfvc784-1-e

# ---------------------------------------------------------------------------
# Helper: find IP definition in catalog
# ---------------------------------------------------------------------------
proc find_ip {name} {
    set hits [get_ipdefs -filter "NAME == $name"]
    if {[llength $hits] == 0} {
        set hits [get_ipdefs -filter "NAME == $name" -all]
    }
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
# 2.  Constraints  (mipi1.xdc — J23 MIPI1 pins)
# ===========================================================================
set xdc_path [file normalize [file join $repo_root src constraints mipi1.xdc]]
if {[file exists $xdc_path]} {
    add_files -fileset constrs_1 -norecurse $xdc_path
    set_property USED_IN_SYNTHESIS      true [get_files [file tail $xdc_path]]
    set_property USED_IN_IMPLEMENTATION true [get_files [file tail $xdc_path]]
    puts "INFO: Added $xdc_path"
} else {
    puts "WARNING: Constraints file not found at $xdc_path — add mipi1.xdc manually if needed."
}

# Capture-path RTL (module reference in the block design)
set rtl_path [file normalize [file join $repo_root src rtl pipeline raw10_to_raw8.v]]
if {[file exists $rtl_path]} {
    add_files -norecurse $rtl_path
    puts "INFO: Added $rtl_path"
} else {
    error "Capture RTL not found at $rtl_path — cannot build Stage A capture path."
}

# ===========================================================================
# 3.  Block Design
# ===========================================================================
create_bd_design "mipi_bd"

# ---------------------------------------------------------------------------
# 3a.  Zynq UltraScale+ MPSoC
#       PL0   = 100 MHz
#       UART1 = MIO 24..25 (CP2102 USB-UART)
#       I2C0  = EMIO       (cam1_i2c -> AH13 SCL / AE13 SDA)
#       SD1   = MIO 46..51, CD = MIO 45
#       HP0   = S_AXI_HP0_FPD, 128-bit (frmbuf_wr video writes to DDR)
#       IRQ0  = pl_ps_irq0 (frmbuf_wr frame-done)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip zynq_ultra_ps_e] zynq_ultra_ps_e_0
set_property -dict [list \
    CONFIG.PSU_BANK_0_IO_STANDARD {LVCMOS18} \
    CONFIG.PSU_BANK_1_IO_STANDARD {LVCMOS18} \
    CONFIG.PSU_BANK_2_IO_STANDARD {LVCMOS18} \
    CONFIG.PSU_BANK_3_IO_STANDARD {LVCMOS18} \
    CONFIG.PSU__SD0__PERIPHERAL__ENABLE {0} \
    CONFIG.PSU__SD1__GRP_CD__ENABLE {1} \
    CONFIG.PSU__SD1__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__SD1__PERIPHERAL__IO {MIO 46 .. 51} \
    CONFIG.PSU__SD1__SLOT_TYPE {SD 2.0} \
    CONFIG.PSU__FPGA_PL0_ENABLE                   {1}            \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ    {100}          \
    CONFIG.PSU__USE__M_AXI_GP0                    {1}            \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH               {32}           \
    CONFIG.PSU__USE__S_AXI_GP2                    {1}            \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH               {128}          \
    CONFIG.PSU__USE__IRQ0                         {1}            \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE         {1}            \
    CONFIG.PSU__UART1__PERIPHERAL__IO             {MIO 24 .. 25} \
    CONFIG.PSU__I2C0__PERIPHERAL__ENABLE          {1}            \
    CONFIG.PSU__I2C0__PERIPHERAL__IO              {EMIO}         \
    CONFIG.SUBPRESET1 {DDR4_MICRON_MT40A256M16GE_083E} \
] [get_bd_cells zynq_ultra_ps_e_0]

# ---------------------------------------------------------------------------
# 3b.  Processor System Reset
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip proc_sys_reset] proc_sys_reset_0
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ---------------------------------------------------------------------------
# 3c.  Clocking Wizard  (100 MHz pl_clk0 -> 200 MHz clk_out1, 24 MHz clk_out2)
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
# 3d.  MIPI CSI-2 Receiver Subsystem (2-lane, RAW10, 4 px/clk, 400 Mbps)
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip mipi_csi2_rx_subsystem] mipi_csi2_rx_subsystem_0
set_property -dict [list \
    CONFIG.CMN_NUM_LANES            {2}      \
    CONFIG.CMN_PXL_FORMAT           {RAW10}   \
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
# 3e.  AXI Interconnect (PS -> CSI-2 Rx csirxss_s_axi + frmbuf_wr s_axi_CTRL)
#      M01_AXI is connected in 3g once v_frmbuf_wr_0 exists.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv [find_ip axi_interconnect] axi_interconnect_0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_interconnect_0]

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
# ---------------------------------------------------------------------------
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 cam1_i2c
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/IIC_0] \
    [get_bd_intf_ports cam1_i2c]

# ---------------------------------------------------------------------------
# 3g.  Stage A capture path:
#      CSI video_out (RAW10, 4 px/clk, per-pixel 10-bit fields, 5 B/beat)
#        -> raw10_to_raw8 (drop 2 LSBs -> RAW8, 4 B/beat)
#        -> AXI4-Stream FIFO (elasticity against frmbuf/DDR back-pressure)
#        -> v_frmbuf_wr (Y8, 640x480) -> S_AXI_HP0_FPD -> DDR
#      video_out is NOT MIPI wire packing: pixels arrive as zero-padded 10-bit
#      fields (same convention as PG286 demosaic inputs), so Stage B at 10-bit
#      can connect demosaic directly; this module is the 8-bit down-converter.
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference raw10_to_raw8 raw10_to_raw8_0

connect_bd_net [get_bd_pins mipi_csi2_rx_subsystem_0/video_out_tdata] \
    [get_bd_pins raw10_to_raw8_0/s_axis_tdata]
connect_bd_net [get_bd_pins mipi_csi2_rx_subsystem_0/video_out_tvalid] \
    [get_bd_pins raw10_to_raw8_0/s_axis_tvalid]
connect_bd_net [get_bd_pins raw10_to_raw8_0/s_axis_tready] \
    [get_bd_pins mipi_csi2_rx_subsystem_0/video_out_tready]
connect_bd_net [get_bd_pins mipi_csi2_rx_subsystem_0/video_out_tlast] \
    [get_bd_pins raw10_to_raw8_0/s_axis_tlast]
connect_bd_net [get_bd_pins mipi_csi2_rx_subsystem_0/video_out_tuser] \
    [get_bd_pins raw10_to_raw8_0/s_axis_tuser]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins raw10_to_raw8_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins raw10_to_raw8_0/rst_n]

create_bd_cell -type ip -vlnv [find_ip axis_data_fifo] axis_data_fifo_0
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES  {12}   \
    CONFIG.FIFO_DEPTH       {4096} \
    CONFIG.TUSER_WIDTH      {1}    \
    CONFIG.HAS_TLAST        {1}    \
] [get_bd_cells axis_data_fifo_0]

connect_bd_net [get_bd_pins raw10_to_raw8_0/m_axis_tdata] \
    [get_bd_pins axis_data_fifo_0/s_axis_tdata]
connect_bd_net [get_bd_pins raw10_to_raw8_0/m_axis_tvalid] \
    [get_bd_pins axis_data_fifo_0/s_axis_tvalid]
connect_bd_net [get_bd_pins axis_data_fifo_0/s_axis_tready] \
    [get_bd_pins raw10_to_raw8_0/m_axis_tready]
connect_bd_net [get_bd_pins raw10_to_raw8_0/m_axis_tlast] \
    [get_bd_pins axis_data_fifo_0/s_axis_tlast]
connect_bd_net [get_bd_pins raw10_to_raw8_0/m_axis_tuser] \
    [get_bd_pins axis_data_fifo_0/s_axis_tuser]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axis_data_fifo_0/s_axis_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axis_data_fifo_0/s_axis_aresetn]

# --- Video Frame Buffer Write (Y8 mono: RAW8 Bayer bytes, stride 640) ---
create_bd_cell -type ip -vlnv [find_ip v_frmbuf_wr] v_frmbuf_wr_0
set_property -dict [list \
    CONFIG.SAMPLES_PER_CLOCK             {4}   \
    CONFIG.MAX_DATA_WIDTH                {8}   \
    CONFIG.MAX_COLS                      {640} \
    CONFIG.MAX_ROWS                      {480} \
    CONFIG.AXIMM_DATA_WIDTH              {128} \
    CONFIG.C_M_AXI_MM_VIDEO_DATA_WIDTH   {128} \
    CONFIG.HAS_Y8                        {1}   \
    CONFIG.HAS_RGB8                      {0}   \
    CONFIG.HAS_YUYV8                     {0}   \
    CONFIG.HAS_UYVY8                     {0}   \
] [get_bd_cells v_frmbuf_wr_0]

connect_bd_intf_net \
    [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
    [get_bd_intf_pins v_frmbuf_wr_0/s_axis_video]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins v_frmbuf_wr_0/ap_clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins v_frmbuf_wr_0/ap_rst_n]

# AXI-Lite control (M01 of the control interconnect)
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
    [get_bd_intf_pins v_frmbuf_wr_0/s_axi_CTRL]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axi_interconnect_0/M01_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/M01_ARESETN]

# --- Video memory path: frmbuf MM master -> HP0 -> DDR ---
create_bd_cell -type ip -vlnv [find_ip axi_interconnect] axi_interconnect_1
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells axi_interconnect_1]
connect_bd_intf_net \
    [get_bd_intf_pins v_frmbuf_wr_0/m_axi_mm_video] \
    [get_bd_intf_pins axi_interconnect_1/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_1/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
foreach port {ACLK S00_ACLK M00_ACLK} {
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
        [get_bd_pins axi_interconnect_1/$port]
}
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_interconnect_1/ARESETN]
foreach port {S00_ARESETN M00_ARESETN} {
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins axi_interconnect_1/$port]
}
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

# --- Frame-done interrupt -> PS (for fb= frame counting / FPS measurement) ---
create_bd_cell -type ip -vlnv [find_ip xlconcat] xlconcat_0
set_property CONFIG.NUM_PORTS {1} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins v_frmbuf_wr_0/interrupt] \
    [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins xlconcat_0/dout] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# ---------------------------------------------------------------------------
# 3h.  CAM1 CLK output (24 MHz -> AG13)
# ---------------------------------------------------------------------------
create_bd_port -dir O cam1_clk
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_ports cam1_clk]

# ---------------------------------------------------------------------------
# 3i.  CAM1 GPIO [0:0] (HIGH -> AH14)
# ---------------------------------------------------------------------------
create_bd_port -dir O -from 0 -to 0 cam1_gpio
create_bd_cell -type ip -vlnv [find_ip xlconstant] xlconstant_gpio
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    [get_bd_cells xlconstant_gpio]
connect_bd_net [get_bd_pins xlconstant_gpio/dout] [get_bd_ports cam1_gpio]

# ---------------------------------------------------------------------------
# 3j.  AXI Address Map
# ---------------------------------------------------------------------------
assign_bd_address -offset 0xA0000000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs mipi_csi2_rx_subsystem_0/csirxss_s_axi/Reg] -force

assign_bd_address -offset 0xA0010000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs v_frmbuf_wr_0/s_axi_CTRL/Reg] -force

# frmbuf video writes -> PS DDR via HP0 (frame buffers live in low DDR)
set ddr_seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]
if {[llength $ddr_seg] == 0} {
    set ddr_seg [get_bd_addr_segs -quiet -filter {NAME =~ "*HP0_DDR_LOW"}]
}
assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces v_frmbuf_wr_0/Data_m_axi_mm_video] \
    $ddr_seg -force

# ===========================================================================
# 4.  Validate, generate products, create wrapper, set top
# ===========================================================================
validate_bd_design
regenerate_bd_layout
save_bd_design
generate_target all [get_files mipi_bd.bd]

set wrapper [make_wrapper -files [get_files mipi_bd.bd] -top]
add_files -norecurse $wrapper
set_property top mipi_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
save_bd_design

puts "============================================================"
puts " Project created cleanly at: $proj_dir/mipi_bringup.xpr"
puts " PS I2C0 (EMIO) -> cam1_i2c, CAM1_CLK -> clk_out2, no ILA"
puts " Stage A capture: CSI -> raw10_to_raw8 -> FIFO -> frmbuf(Y8)"
puts "   -> HP0 -> DDR; frmbuf IRQ -> pl_ps_irq0; CTRL @ 0xA0010000"
puts "============================================================"
