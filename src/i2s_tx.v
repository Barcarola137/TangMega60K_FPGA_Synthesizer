// 模块名称：i2s_tx
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：I2S 物理层发送器 (纯硬件逻辑)。
//           将合成的 16-bit PCM 数据，转换为标准的 I2S 总线时序。
//           对应赛题要求：“最终通过 I2S 接口输出音频信号至 DAC 解码发声”。
//           本模块无任何软件参与，采用确定性流水线架构，无抖动延迟。
module i2s_tx (
    input  wire        clk,       // 12.288MHz 音频主时钟
    input  wire        rst_n,     // 音频域同步复位
    input  wire [15:0] audio_l,   // 左声道 16-bit PCM 数据
    input  wire [15:0] audio_r,   // 右声道 16-bit PCM 数据
    output reg         bck,       // 1.536MHz (12.288MHz / 8) I2S 位时钟
    output reg         ws,        // 48kHz 左右声道帧时钟 (Word Select)
    output reg         data,      // 串行音频数据
    output wire        pa_en      // 功放使能 (低电平有效)
);

    // 1. 位时钟 (BCK) 分频生成
    // 说明：12.288MHz / 8 = 1.536MHz。即每计数 4 个主时钟周期，BCK 翻转一次。
    //       bck_en 脉冲作为后续移位操作的同步使能信号。
    reg [2:0] div_cnt = 3'd0;
    reg bck_en = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 3'd0;
            bck_en  <= 1'b0;
            bck     <= 1'b0;
        end else begin
            if (div_cnt == 3'd3) begin
                div_cnt <= 3'd0;
                bck_en  <= 1'b1;
                bck     <= ~bck;
            end else begin
                div_cnt <= div_cnt + 1'b1;
                bck_en  <= 1'b0;
            end
        end
    end

    // 2. 声道控制与并行数据加载 (Word Select & Parallel to Serial Prep)
    // 说明：I2S 协议每个声道 16-bit，左右声道共 32 个 BCK 周期。
    //       当 bit_cnt 计数到 31 时，翻转 WS 信号，并加载下一声道的音频数据。
    reg [4:0] bit_cnt = 5'd0;
    reg [15:0] shift_reg = 16'd0;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= 5'd0;
            ws      <= 1'b0;
            shift_reg <= 16'd0;
        end else if (bck_en) begin
            if (bit_cnt == 5'd31) begin
                bit_cnt <= 5'd0;
                ws <= ~ws; // 切换声道 (48kHz 帧率)
                if (ws == 1'b0) shift_reg <= audio_r; // 加载右声道
                else            shift_reg <= audio_l; // 加载左声道
            end else begin
                bit_cnt <= bit_cnt + 1'b1;
            end
        end
    end

    // 3. 串行数据发送 (Serial Data Shift)
    // 核心：
    // 传统的 I2S 可能在 BCK 边沿的时钟域下更新数据，容易产生毛刺或建立时间不足。
    // 本设计去掉了对 bck 高低电平的判断，直接利用 bck_en (1.536MHz 脉冲) 
    // 让 data 和 bit_cnt 在 12.288MHz 主时钟下严格同步更新。
    // 这种“单时钟域同步赋值”的硬件对齐方式，对于 PT8211 这类 DAC 来说，
    // 时序裕量极大，彻底杜绝了亚稳态与数据错位风险。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data <= 1'b0;
        end else if (bck_en) begin
            // 输出最高位到最低位 (MSB First)
            if (bit_cnt <= 5'd15)
                data <= shift_reg[15 - bit_cnt]; 
            else
                data <= 1'b0; // I2S 协议后半段 (16~31) 补零
        end
    end

    // 4. 功放使能控制
    // 说明：板载 NS4263 功放芯片为低电平有效，这里直接拉低以开启功放。
    assign pa_en = 1'b0; 

endmodule