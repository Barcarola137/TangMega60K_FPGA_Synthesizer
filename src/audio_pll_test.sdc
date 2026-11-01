# 1. 系统主时钟约束 (50MHz)
create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]

# 2. 声明 PLL 生成的音频时钟
create_generated_clock -name clk_12m288 -source [get_ports {sys_clk}] -divide_by 1 [get_pins {u_pll/u_pll_0/PLLA_inst/CLKOUT0}]

# 3. 跨时钟域异步约束 (False Path) - 直接使用定义好的时钟名
# 从系统时钟到音频时钟
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {clk_12m288}]

# 从音频时钟到系统时钟
set_false_path -from [get_clocks {clk_12m288}] -to [get_clocks {sys_clk}]

# 4. 针对跨时钟域复位信号（rst_n）的特定忽略
set_false_path -from [get_clocks {sys_clk}] -to [get_pins {*rst_cnt_12m*/RESET}]