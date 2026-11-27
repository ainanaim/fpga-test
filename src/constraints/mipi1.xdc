################################################################################
#  mipi1.xdc — J23 MIPI Interface Pin Constraints
#  Board:  ALINX AXU2CGB
#  Camera: OV5647 on MIPI1 connector J23
#
#  Sources:
#    - ALINX AXU2CGA/B User Manual Part 14 (MIPI Interface J23 Pin Assignment)
#    - Official ALINX mipi.xdc (cam0_* entries):
#      https://github.com/alinxalinx/AXU2CGA_AXU2CGB/blob/master/vivado/
#      auto_create_project/src/constraints/mipi.xdc
#
#  NAMING NOTE
#  -----------
#  The official ALINX mipi.xdc uses cam0_gpio[0], cam0_i2c_scl_io,
#  cam0_i2c_sda_io (bidirectional _io suffix from AXI IIC IP) for J23.
#  This file uses cam1_gpio, cam1_scl, cam1_sda to match our block design.
#  Adjust port names here if you switch to the AXI IIC IP style.
#
#  USAGE
#  -----
#  Add this file to your Vivado project as a constraint source.
#  Port names below match the MIPI CSI-2 Rx Subsystem IP (PG232) top-level
#  ports and the top-level wrapper for CAM1 control signals.
#
#  NOTE ON IOSTANDARD FOR DIFFERENTIAL PAIRS
#  ------------------------------------------
#  The MIPI CSI-2 Rx Subsystem IP (PG232) auto-generates its own IOSTANDARD
#  constraints for the differential D-PHY pairs (LVDS on HP bank BANK64).
#  Do NOT set IOSTANDARD for mipi_phy_if_* ports here — the IP manages them.
#  Only PACKAGE_PIN is needed for those ports.
#
#  For the CAM1 control signals (BANK24, 3.3 V), LVCMOS33 is set here.
################################################################################

################################################################################
#  PS Fabric Clock (100 MHz)
#  PS pl_clk0 drives the Clocking Wizard; no external clock port is used.
################################################################################

################################################################################
#  MIPI1 D-PHY Differential Pairs — BANK64 (HP, 1.2 V)
#
#  J23 connector pinout (confirmed from AXU2CGA/B user manual Part 14):
#    J23 pin 2  MIPI1_LAN0_N  IO_L2N_64  AE8  Data lane 0 −
#    J23 pin 3  MIPI1_LAN0_P  IO_L2P_64  AE9  Data lane 0 +
#    J23 pin 5  MIPI1_LAN1_N  IO_L3N_64  AC8  Data lane 1 −
#    J23 pin 6  MIPI1_LAN1_P  IO_L3P_64  AB8  Data lane 1 +
#    J23 pin 8  MIPI1_CLK_N   IO_L1N_64  AD9  D-PHY clock lane −
#    J23 pin 9  MIPI1_CLK_P   IO_L1P_64  AC9  D-PHY clock lane +
#
#  Port names match PG232 MIPI CSI-2 Rx Subsystem top-level interface:
#    mipi_phy_if_clk_p / mipi_phy_if_clk_n
#    mipi_phy_if_data_p[0] / mipi_phy_if_data_n[0]
#    mipi_phy_if_data_p[1] / mipi_phy_if_data_n[1]
#
#  IOSTANDARD is NOT set here — the IP sets it automatically (LVDS).
################################################################################
#  CAM1 Control Signals - BANK24 (3.3 V)
#  Confirmed from J23 pin table and official ALINX mipi.xdc (cam0_* entries).
#
#    J23 pin 11  CAM1_GPIO  IO_L2N_24  AH14  Camera enable / GPIO
#    J23 pin 12  CAM1_CLK   IO_L3P_24  AG13  XCLK output to OV5647 (24 MHz)
#    J23 pin 13  CAM1_SCL   IO_L3N_24  AH13  SCCB / I2C clock
#    J23 pin 14  CAM1_SDA   IO_L4P_24  AE13  SCCB / I2C data
#
#  cam1_clk (XCLK) driven at 25 MHz from Clocking Wizard clk_out2.
#  OV5647 requires XCLK before it will respond on SCCB.
################################################################################

# D-PHY clock lane
set_property PACKAGE_PIN AC9 [get_ports mipi_phy_if_clk_p]
set_property PACKAGE_PIN AD9 [get_ports mipi_phy_if_clk_n]

# D-PHY data lane 0
set_property PACKAGE_PIN AE9 [get_ports {mipi_phy_if_data_p[0]}]
set_property PACKAGE_PIN AE8 [get_ports {mipi_phy_if_data_n[0]}]

# D-PHY data lane 1
set_property PACKAGE_PIN AB8 [get_ports {mipi_phy_if_data_p[1]}]
set_property PACKAGE_PIN AC8 [get_ports {mipi_phy_if_data_n[1]}]

set_property PACKAGE_PIN AH14 [get_ports {cam1_gpio[0]}]
set_property PACKAGE_PIN AH13 [get_ports cam1_i2c_scl_io]
set_property PACKAGE_PIN AE13 [get_ports cam1_i2c_sda_io]
set_property PACKAGE_PIN AG13 [get_ports cam1_clk]
set_property IOSTANDARD LVCMOS33 [get_ports {cam1_gpio[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports cam1_i2c_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports cam1_i2c_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports cam1_clk]
# Pull-ups confirmed in official ALINX mipi.xdc — required for open-drain
# SCCB/I2C lines. Pi V1 camera module has on-board 1.5 kΩ pull-ups but
# enabling the FPGA's weak pull-up adds no harm and helps if they are absent.
set_property PULLTYPE PULLUP [get_ports {cam1_gpio[0]}]
set_property PULLTYPE PULLUP [get_ports cam1_i2c_scl_io]
set_property PULLTYPE PULLUP [get_ports cam1_i2c_sda_io]
