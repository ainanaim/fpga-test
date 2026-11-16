################################################################################
#  mipi2.xdc — J24 MIPI Interface Pin Constraints
#  Board:  ALINX AXU2CGB-E
#  Camera: OV5647 on MIPI2 connector J24
#
#  Sources:
#    - ALINX AXU2CGB-E User Manual Figure 15 (MIPI Interface J24 Pin Assignment)
#    - Official ALINX mipi.xdc (cam1_* entries):
#      https://github.com/alinxalinx/AXU2CGA_AXU2CGB/blob/master/vivado/
#      auto_create_project/src/constraints/mipi.xdc
#
#  NAMING NOTE
#  -----------
#  The official ALINX mipi.xdc uses cam1_gpio[0], cam1_i2c_scl_io,
#  cam1_i2c_sda_io (bidirectional _io suffix from AXI IIC IP) for J24.
#  This file uses cam2_gpio, cam2_scl, cam2_sda to match our block design.
#  Adjust port names here if you switch to the AXI IIC IP style.
#
#  USAGE
#  -----
#  Add this file to your Vivado project as a constraint source.
#  Port names below match the MIPI CSI-2 Rx Subsystem IP (PG232) top-level
#  ports and the top-level wrapper for CAM2 control signals.
#
#  NOTE ON IOSTANDARD FOR DIFFERENTIAL PAIRS
#  ------------------------------------------
#  The MIPI CSI-2 Rx Subsystem IP (PG232) auto-generates its own IOSTANDARD
#  constraints for the differential D-PHY pairs (LVDS on HP bank BANK65).
#  Do NOT set IOSTANDARD for mipi_phy_if_* ports here — the IP manages them.
#  Only PACKAGE_PIN is needed for those ports.
#
#  For the CAM2 control signals (BANK24, 3.3 V), LVCMOS33 is set here.
################################################################################

################################################################################
#  PL Reference Clock (25 MHz, BANK44)
#  Used by the Clocking Wizard to generate all derived clocks.
################################################################################
set_property PACKAGE_PIN AB11 [get_ports pl_ref_clk]
set_property IOSTANDARD  LVCMOS33 [get_ports pl_ref_clk]
create_clock -period 40.000 -name pl_ref_clk -waveform {0.000 20.000} \
    [get_ports pl_ref_clk]

################################################################################
#  MIPI2 D-PHY Differential Pairs — BANK65 (HP, 1.2 V)
#
#  J24 connector pinout (confirmed from AXU2CGB-E user manual):
#    J24 pin 2  MIPI2_LAN0_N  IO_L2N_65  V9   Data lane 0 −
#    J24 pin 3  MIPI2_LAN0_P  IO_L2P_65  U9   Data lane 0 +
#    J24 pin 5  MIPI2_LAN1_N  IO_L3N_65  V8   Data lane 1 −
#    J24 pin 6  MIPI2_LAN1_P  IO_L3P_65  U8   Data lane 1 +
#    J24 pin 8  MIPI2_CLK_N   IO_L1N_65  Y8   D-PHY clock lane −
#    J24 pin 9  MIPI2_CLK_P   IO_L1P_65  W8   D-PHY clock lane +
#
#  Port names match PG232 MIPI CSI-2 Rx Subsystem top-level interface:
#    mipi_phy_if_clk_p / mipi_phy_if_clk_n
#    mipi_phy_if_data_p[0] / mipi_phy_if_data_n[0]
#    mipi_phy_if_data_p[1] / mipi_phy_if_data_n[1]
#
#  IOSTANDARD is NOT set here — the IP sets it automatically (LVDS).
################################################################################

# D-PHY clock lane
set_property PACKAGE_PIN W8 [get_ports mipi_phy_if_clk_p]
set_property PACKAGE_PIN Y8 [get_ports mipi_phy_if_clk_n]

# D-PHY data lane 0
set_property PACKAGE_PIN U9 [get_ports {mipi_phy_if_data_p[0]}]
set_property PACKAGE_PIN V9 [get_ports {mipi_phy_if_data_n[0]}]

# D-PHY data lane 1
set_property PACKAGE_PIN U8 [get_ports {mipi_phy_if_data_p[1]}]
set_property PACKAGE_PIN V8 [get_ports {mipi_phy_if_data_n[1]}]

################################################################################
#  CAM2 Control Signals — BANK24 (3.3 V)
#  Confirmed from J24 pin table (pins 11-14).
#
#    J24 pin 11  CAM2_GPIO  IO_L5P_24  AD15  Camera enable / GPIO
#    J24 pin 12  CAM2_CLK   IO_L6P_24  AC14  XCLK output to OV5647 (24 MHz)
#    J24 pin 13  CAM2_SCL   IO_L5N_24  AD14  SCCB / I2C clock (from PS EMIO)
#    J24 pin 14  CAM2_SDA   IO_L6N_24  AC13  SCCB / I2C data  (from PS EMIO)
#
#  cam2_clk (XCLK) must be driven at 24 MHz from a Clocking Wizard output.
#  OV5647 requires XCLK before it will respond on SCCB.
################################################################################

set_property PACKAGE_PIN AD15 [get_ports cam2_gpio]
set_property PACKAGE_PIN AC14 [get_ports cam2_clk]
set_property PACKAGE_PIN AD14 [get_ports cam2_scl]
set_property PACKAGE_PIN AC13 [get_ports cam2_sda]
set_property IOSTANDARD LVCMOS33 [get_ports {cam2_gpio cam2_clk cam2_scl cam2_sda}]

# Pull-ups confirmed in official ALINX mipi.xdc — required for open-drain
# SCCB/I2C lines. Pi V1 camera module has on-board 1.5 kΩ pull-ups but
# enabling the FPGA's weak pull-up adds no harm and helps if they are absent.
set_property PULLUP true [get_ports cam2_gpio]
set_property PULLUP true [get_ports cam2_scl]
set_property PULLUP true [get_ports cam2_sda]

# cam2_clk is a clock output driven by the Clocking Wizard — mark it as a
# generated clock so the timing engine tracks it correctly.
# Replace clk_wiz_inst/clk_out_24m with the actual Clocking Wizard output net
# name from your block design.
# create_generated_clock -name cam2_xclk -source [get_pins clk_wiz_inst/clk_out_24m] \
#     -divide_by 1 [get_ports cam2_clk]
