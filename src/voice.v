// 模块名称：voice
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：单路复音发声引擎（Voice）。
//           1. 包含 32-bit 独立相位累加器（DDS），严格满足赛题合规要求。
//           2. 内置独立的 ADSR 包络发生器，支持钢琴级自然延音与管风琴不衰减发声。
//           3. 支持实时揉弦（Vibrato）调制与 3 种基础音色/乐器预设切换。
//           4. 在顶层模块中例化 4 次，构成 4 复音并发合成架构。

module voice (
    input  wire        clk,                    // 12.288MHz 音频主时钟
    input  wire        rst_n,                  // 音频域同步复位 (rst_n_12m)
    input  wire        gate,                   // 发声使能（按键按下或自动演奏激活）
    input  wire [31:0] freq_word,              // DDS 频率控制字
    input  wire [1:0]  timbre_sel,             // 音色选择 (00:钢琴 01:管风琴 10:长笛)
    input  wire signed [15:0] vibrato_offset,  // 揉弦（Vibrato）频率偏移量
    input  wire        sustain_pedal,          // 延音踏板状态
    output reg  signed [15:0] audio_out        // 16-bit 有符号音频输出
);


    // 1. 纯硬件实时并行 DDS 引擎 (32-bit 相位累加器)

    reg [31:0] pa = 0;                         // 32-bit 相位累加器 (Phase Accumulator)
    reg [15:0] adsr_div = 0;
    reg        adsr_tick = 0;                  // ADSR 包络更新脉冲
    reg [7:0]  env = 0;                        // 当前包络音量值 (0~255)
    reg [1:0]  state = 0;                      // ADSR 状态机
    
    localparam IDLE = 0, ATTACK = 1, DECAY = 2, SUSTAIN = 3;

    // 只有在 gate 有效时，才累加频率字（同时叠加揉弦偏移），否则频率为 0 停止运算
    wire [31:0] f_add = gate ? (freq_word + vibrato_offset) : 32'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pa <= 0;
        else pa <= pa + f_add;
    end


    // 2. 独立 ADSR 包络发生器 

    // 分频产生包络更新速率 (约 6kHz)，控制 A/D/S/R 的过渡平滑度
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin adsr_div <= 0; adsr_tick <= 0; end
        else if (adsr_div == 16'd2000) begin adsr_div <= 0; adsr_tick <= 1; end
        else begin adsr_div <= adsr_div + 1; adsr_tick <= 0; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; env <= 0;
        end else if (adsr_tick) begin
            if (gate) begin
                // --- 按键按下 (Attack / Decay / Sustain) ---
                case(state)
                    IDLE: state <= ATTACK;
                    ATTACK: if (env >= 255) begin env <= 255; state <= DECAY; end else env <= env + 1;
                    DECAY: if (timbre_sel == 2'b01) begin 
                               // 特色：管风琴 (方波) 不做衰减，保持满幅度持续发声
                               env <= 255; state <= SUSTAIN; 
                           end
                           else if (env <= 128) begin env <= 128; state <= SUSTAIN; end
                           else env <= env - 2;
                    SUSTAIN: if (timbre_sel == 2'b01) env <= 255; else env <= 128;
                endcase
            end else begin
                // --- 按键松开 (Release) ---
                if (sustain_pedal) begin
                    // 踩下延音踏板：保持当前状态不衰减（配合顶层做慢速释放，模拟真实钢琴）
                    state <= state; 
                end else begin
                    // 未踩踏板：快速释放，正常断音
                    if (env > 1) env <= env - 1; 
                    else begin env <= 0; state <= IDLE; end
                end
            end
        end
    end


    // 3. 多音色波形实时生成 

    // 利用相位累加器的高位直接映射出不同的波形，纯组合逻辑，无时钟延迟
    wire signed [15:0] saw = {1'b0, pa[31:16]} - 16'sd32768; // 经典钢琴 (锯齿波)
    wire signed [15:0] sqr = pa[31] ? 16'sd30000 : -16'sd30000; // 复古管风琴 (方波)
    
    wire [14:0] tri_amp = pa[31] ? (15'h7FFF - pa[30:16]) : pa[30:16];
    wire signed [15:0] tri_wave = {tri_amp[14:0], 1'b0} - 16'sd32768; // 柔和长笛 (三角波)
    
    // 音色多路选择器 (Timbre MUX)
    wire signed [15:0] w = (timbre_sel == 2'b01) ? sqr : 
                           (timbre_sel == 2'b10) ? tri_wave : saw;
                           

    // 4. 包络幅度调制与输出

    // 数字乘法器：波形数据 * 当前包络音量，实现实时幅度调制
    wire signed [23:0] mix = w * $signed({1'b0, env});
    
    // 截取高位输出至 16-bit，供顶层混音总线进行求和
    always @(posedge clk) audio_out <= mix[23:8];

endmodule