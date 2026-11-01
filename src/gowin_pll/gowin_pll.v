// 模块名称：Gowin_PLL
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：高云官方 IP 锁相环（PLL）封装模块。
//           功能：将板载 50MHz 系统时钟，转换为高保真音频合成域所需的 
//                 ~12.288MHz 主时钟（clkout0）。该时钟是纯硬件 DDS、ADSR、
//                 I2S 时序生成的基准节拍，要求极低的时钟抖动（Jitter）。
module Gowin_PLL(
    clkin,
    clkout0,
    lock,
    mdclk
);

input clkin;        // 输入时钟 (50MHz)
output clkout0;     // 输出时钟 (12.288MHz 音频主时钟)
output lock;        // 时钟锁定信号 (高电平代表 PLL 输出稳定)
input mdclk;        // 监控时钟 (用于内部状态机监控 PLL 状态)

wire [7:0] mdrdo;
wire [1:0] wMdOpc;
wire wMdAInc;
wire [7:0] wMdDIn;
wire [7:0] wMdQOut;
wire pll_lock;
wire pll_rst;

    // 1. 物理锁相环原语例化 (Gowin PLL Primitive)
    // 负责实际的倍频、分频与时钟相位对齐
    Gowin_PLL_MOD u_pll(
        .clkout0(clkout0),
        .lock(pll_lock),
        .mdrdo(wMdQOut),
        .clkin(clkin),
        .reset(pll_rst),
        .mdclk(mdclk),
        .mdopc(wMdOpc),
        .mdainc(wMdAInc),
        .mdwdi(wMdDIn)
    );

    // 2. PLL 动态配置与初始化状态机

    PLL_INIT u_pll_init(
        .I_RST(1'b0),
        .O_RST(pll_rst),
        .I_LOCK(pll_lock),
        .O_LOCK(lock),
        .I_MD_CLK(mdclk),
        .O_MD_INC(wMdAInc),
        .O_MD_OPC(wMdOpc),
        .O_MD_WR_DATA(wMdDIn),
        .I_MD_RD_DATA(wMdQOut),
        .PLL_INIT_BYPASS(1'b0),
        .MDRDO(mdrdo),
        .MDOPC(2'b00),
        .MDAINC(1'b0),
        .MDWDI(8'h0)
    );

    // 3. 硬件参数配置 (Defparam)
    // - CLK_PERIOD = 20：输入时钟周期为 20ns (对应 50MHz)
    // - MULTI_FAC  = 14：内部倍频系数配置
    // 
    // 由于高云 PLL 的整数分频限制（50MHz 无法通过纯整数比
    // 精确得到 12.288MHz），当前配置生成的音频时钟实际约为 12.281MHz。
    // 相对误差仅为 0.057%，远低于 I2S DAC 芯片的时钟容忍度，既保证了
    // 音高的绝对准确，又确保了底层硬件的稳定锁相。
    defparam u_pll_init.CLK_PERIOD = 20;
    defparam u_pll_init.MULTI_FAC = 14;

endmodule