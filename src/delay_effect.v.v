// 模块名称：delay_effect
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：数字音频延迟效果器（Delay / Echo）。
//           对应赛题拓展要求：“在FPGA硬件内部实现混响、延迟等数字音频效果器”。
//           本模块完全基于 FPGA 内部的 Block RAM 与硬件逻辑实现。
//           利用 16K 深度的环形缓冲区（Ring Buffer）存储历史音频，通过
//           读取滞后地址的数据，并与当前输入混合，产生真实的空间回声效果。
module delay_effect (
    input  wire        clk,        
    input  wire        rst_n,      // 12.288MHz 同步复位
    input  wire        effect_en,  // 效果器开关 (由按键 A / * 控制)
    input  wire signed [15:0] audio_in,  // 干声输入
    output reg  signed [15:0] audio_out  // 混合了回声的最终输出
);

    // 1. 延迟缓存与地址计算 (环形缓冲区设计)
    // 使用 16K * 16bit 的 RAM 作为延迟线 (Delay Line)
    reg [15:0] ram [0:16383]; 
    
    // 读地址永远滞后于写地址 14000 个样本
    // 在 48kHz 等效采样率下，14000 个样本的延迟时间约为 291ms，听感极佳
    reg [13:0] wr_addr = 14'd14000; 
    wire [13:0] rd_addr = wr_addr - 14'd14000; 

    // 分频器：产生约 48kHz 的音频采样率 (12.288MHz / 256)
    // 降低数据吞吐率，节省 BRAM 资源，并符合人耳对回声的听觉分辨能力
    reg [7:0] sample_div = 8'd0;
    wire sample_tick = (sample_div == 8'd255); 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_div <= 8'd0;
            wr_addr <= 14'd14000;
        end else begin
            sample_div <= sample_div + 1'b1;
            if (sample_tick) wr_addr <= wr_addr + 1'b1; // 环形指针递增
        end
    end

    // 2. 历史数据读取与反馈混合 (Feedback & Dry/Wet Mix)
    reg [15:0] ram_dout;
    always @(posedge clk) begin
        ram_dout <= ram[rd_addr];
    end

    wire signed [15:0] delayed_sound = ram_dout;
    
    // 回声衰减系数：
    // echo_mix (输出混音衰减)：右移 1 位，相当于乘以 0.5
    // echo_fb  (再写入衰减)：右移 3 位，相当于乘以 0.125，实现多次回声逐渐变弱
    wire signed [15:0] echo_mix = delayed_sound >>> 1; 
    wire signed [15:0] echo_fb  = delayed_sound >>> 3; 
    
    // 反馈路径：将当前的干声与衰减后的回声叠加，重新写回 RAM
    wire signed [16:0] din_sum = audio_in + echo_fb; 
    
    // 防破音限幅器：防止反馈叠加溢出导致 16-bit 翻转破音
    wire signed [15:0] din_data = (din_sum > 17'sd28000)  ? 16'sd28000 :
                                  (din_sum < -17'sd28000) ? -16'sd28000 :
                                  din_sum[15:0];

    // 3. 缓存写入控制
    always @(posedge clk) begin
        if (sample_tick) begin
            if (effect_en) ram[wr_addr] <= din_data; // 开启效果：写入包含反馈的数据
            else           ram[wr_addr] <= 16'd0;    // 关闭效果：写入 0 以快速清空回声尾巴
        end
    end

    // 4. 最终干湿混合与旁路控制 (Bypass)
    // 将干声与衰减后的延迟声混合
    wire signed [16:0] mix_sum = audio_in + echo_mix;
    
    // 最终输出限幅保护
    wire signed [15:0] clipped = (mix_sum > 17'sd28000)  ? 16'sd28000 :
                                 (mix_sum < -17'sd28000) ? -16'sd28000 :
                                 mix_sum[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) audio_out <= 16'sd0;
        else if (effect_en) audio_out <= clipped;  // 开启效果：输出混合信号
        else audio_out <= audio_in;                // 旁路模式 (Bypass)：直接输出原声
    end
endmodule