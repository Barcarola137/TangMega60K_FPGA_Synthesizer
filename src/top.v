// 模块名称：top.v 
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 队伍名称：汪汪队
// 文件描述：系统顶层模块。实现纯硬件实时音频合成、多维交互控制、自动化演奏、
//         以及软硬件协同的视觉效果输出。无任何软核/MCU参与，杜绝软件延迟。
// 硬件平台：Sipeed Tang Mega 60K (高云 GW5AT-LV60)


// 【系统核心特色功能（赛题得分点全命中）】
// 1. 纯硬件实时音频合成：全流水线 DDS 引擎，无软核/MCU参与，杜绝软件串行运算。
// 2. 高并发 4 复音引擎：内置 4 个完全独立的 32-bit 相位累加器（DDS）和独立 ADSR。
// 3. 多维音色与表情控制：支持锯齿波、方波、三角波切换；支持滑音、揉弦、音量调节。
// 4. 钢琴级自然延音踏板：踩下延音时包络极慢衰减，模拟真实钢琴，且强行阻断揉弦。
// 5. 安全音量防破音保护：针对板载 4Ω 3W 大功率功放，底层做数字限幅与衰减处理。
// 6. 视听联动可视化：8路 LED 频率指示；WS2812 幻彩灯随音名变色。


// 【4x4 矩阵键盘按键使用说明】

// | 物理按键 | 对应代码键位 | 功能说明                                                  
// |----------|--------------|
// | 1, 2, 3  | key[1][2][3] | 音符 Do, Re, Mi                                           
// | 4, 5, 6  | key[4][5][6] | 音符 Fa, Sol, La                                          
// | A        | key[10]      | 音符 Si                                                   
// | 7        | key[7]       | 节拍器开关（开/关，关闭时 BPM 重置为 40）                 
// | 8        | key[8]       | 节拍器 BPM 调速（40~180 自动往复）                        
// | 9        | key[9]       | 自动演奏 暂停/继续                                        
// | 0        | key[0]       | 延音踏板（按住0键松开琴键，触发钢琴级自然长衰减延音）    
// | *        | key[13]      | 空间效果器开关（混响/延迟开关）                           
// | #        | key[14]      | 自动演奏控制（连按：曲目1->曲目2->曲目3->关闭）        
// | B        | key[11]      | 音量调节（4 档循环切换：3->2->1->0 静音）             
// | C        | key[12]      | 八度切换（升/降八度，建议弹低音时升八度听感更好）        
// | D        | key[15]      | 音色切换（3 种音色循环：锯齿波 -> 方波 -> 三角波）      

module top (
    input  wire sys_clk,    // V22, 板载 50MHz 系统时钟
    output wire hp_bck,     // Y17, I2S BCK (位时钟)
    output wire hp_ws,      // AB17, I2S WS (左右声道时钟)
    output wire hp_din,     // AA16, I2S DIN (音频数据)
    output wire pa_en,      // AB16, 音频功放使能 (接底板 3W 功放)
    inout  wire [7:0] key_io, // 4x4 矩阵键盘接口 (多维交互输入)
    output wire [7:0] led_o,  // 8路 LED，用于实时频率/节拍指示
    output wire WS2812,       // WS2812 幻彩灯带，随音名变色
    output wire debug_pin     // 延迟测试专用引脚：用于示波器实测按键到发声的物理延迟
);

    wire clk_12m288;        
    wire pll_lock;          

    
    // 1. 时钟与复位架构 (双时钟域设计)
    
    // 1.1 内部上电复位 (50MHz 交互域)
    reg [15:0] rst_cnt = 16'd0;
    always @(posedge sys_clk) begin
        if (rst_cnt != 16'hFFFF) rst_cnt <= rst_cnt + 1'b1;
    end
    wire rst_n = (rst_cnt == 16'hFFFF);

    // 1.2 PLL 音频时钟生成 (生成 12.288MHz 专用时钟，用于精确的 I2S 时序)
    Gowin_PLL u_pll (
        .clkin(sys_clk), .clkout0(clk_12m288), .lock(pll_lock)
    );

    // 1.3 12.288MHz 域的专属同步复位信号 (跨时钟域处理，防止亚稳态)
    reg [2:0] rst_cnt_12m = 3'b000;
    always @(posedge clk_12m288) begin
        if (!rst_n) rst_cnt_12m <= 3'b000;
        else if (rst_cnt_12m != 3'b111) rst_cnt_12m <= rst_cnt_12m + 1'b1;
    end
    wire rst_n_12m = (rst_cnt_12m == 3'b111);

   
    // 2. 核心音乐函数映射表 (DDS 频率控制字计算)
    // 公式: Freq_Word = (Target_Freq * 2^32) / 12.288MHz
    // 通过查表法替代除法器，极大节省 FPGA 逻辑资源并降低延迟
    
    function [31:0] freq_of_key; input [3:0] key;
        case (key)
            4'd1: freq_of_key = 32'd91444;  4'd2: freq_of_key = 32'd102654; 4'd3: freq_of_key = 32'd115228;
            4'd10: freq_of_key = 32'd122080; 4'd4: freq_of_key = 32'd137048; 4'd5: freq_of_key = 32'd153766;
            4'd6: freq_of_key = 32'd172581; default: freq_of_key = 32'd0;
        endcase
    endfunction

    function [31:0] freq_of_melody; input [4:0] note;
        case (note)
            5'd0: freq_of_melody = 32'd43162;  5'd1: freq_of_melody = 32'd91444;  5'd2: freq_of_melody = 32'd102654;
            5'd3: freq_of_melody = 32'd115228; 5'd4: freq_of_melody = 32'd122080; 5'd5: freq_of_melody = 32'd137048;
            5'd6: freq_of_melody = 32'd153766; 5'd7: freq_of_melody = 32'd172581; 5'd8: freq_of_melody = 32'd182888;
            5'd9: freq_of_melody = 32'd205308; 5'd10: freq_of_melody = 32'd230456; 5'd11: freq_of_melody = 32'd244160;
            5'd12: freq_of_melody = 32'd274096; 5'd13: freq_of_melody = 32'd307532; 5'd14: freq_of_melody = 32'd345162;
            5'd31: freq_of_melody = 32'd0; default: freq_of_melody = 32'd0; 
        endcase
    endfunction

 
    // 3. 4x4 矩阵键盘扫描与硬件消抖 (多维交互层)
    
    reg [1:0] scan_state = 2'd0;
    reg [15:0] scan_timer = 16'd0;
    reg [3:0] row_out = 4'b1111;
    assign key_io[3:0] = row_out;
    wire [3:0] col_in;
    assign col_in[0] = key_io[7]; assign col_in[1] = key_io[6]; assign col_in[2] = key_io[5]; assign col_in[3] = key_io[4];

    // 逐行扫描状态机 (12.288MHz 下约 1ms 切换一行)
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin scan_state <= 2'd0; scan_timer <= 16'd0; row_out <= 4'b1111; end
        else if (scan_timer == 16'd12288) begin
            scan_timer <= 16'd0; scan_state <= scan_state + 1'b1;
            case (scan_state)
                2'd0: row_out <= 4'b1110; 2'd1: row_out <= 4'b1101;
                2'd2: row_out <= 4'b1011; 2'd3: row_out <= 4'b0111;
            endcase
        end else scan_timer <= scan_timer + 1'b1;
    end

    // 键值采集
    reg [15:0] key_pressed_raw = 16'd0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) key_pressed_raw <= 16'd0;
        else case (scan_state)
            2'd0: begin key_pressed_raw[13] <= (col_in[0] == 1'b0); key_pressed_raw[0] <= (col_in[1] == 1'b0); key_pressed_raw[14] <= (col_in[2] == 1'b0); key_pressed_raw[15] <= (col_in[3] == 1'b0); end
            2'd1: begin key_pressed_raw[1]  <= (col_in[0] == 1'b0); key_pressed_raw[2] <= (col_in[1] == 1'b0); key_pressed_raw[3] <= (col_in[2] == 1'b0); key_pressed_raw[10] <= (col_in[3] == 1'b0); end
            2'd2: begin key_pressed_raw[4]  <= (col_in[0] == 1'b0); key_pressed_raw[5] <= (col_in[1] == 1'b0); key_pressed_raw[6] <= (col_in[2] == 1'b0); key_pressed_raw[11] <= (col_in[3] == 1'b0); end
            2'd3: begin key_pressed_raw[7]  <= (col_in[0] == 1'b0); key_pressed_raw[8] <= (col_in[1] == 1'b0); key_pressed_raw[9] <= (col_in[2] == 1'b0); key_pressed_raw[12] <= (col_in[3] == 1'b0); end
        endcase
    end

    // 二级消抖 (连续两轮扫描结果一致才认为按键有效)
    reg [15:0] key_prev = 16'd0;
    reg [15:0] key_pressed = 16'd0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin key_prev <= 16'd0; key_pressed <= 16'd0; end
        else if (scan_state == 2'd3 && scan_timer == 16'd12288) begin
            if (key_pressed_raw == key_prev) key_pressed <= key_pressed_raw; 
            key_prev <= key_pressed_raw;
        end
    end

    // ============================================================================
    // 4. 功能按键解析 (赛题要求：≥2维演奏维度，≥2维表情维度)
    // ============================================================================
    // 维度1：音色切换 (按键 D)
    reg [1:0] timbre_sel = 2'b00; reg key15_prev = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin timbre_sel <= 2'b00; key15_prev <= 0; end
        else begin
            key15_prev <= key_pressed[15];
            if (key_pressed[15] && !key15_prev) begin
                case (timbre_sel)
                    2'b00: timbre_sel <= 2'b01; 2'b01: timbre_sel <= 2'b10;
                    2'b10: timbre_sel <= 2'b00; default: timbre_sel <= 2'b00;
                endcase
            end
        end
    end

    // 维度2：八度切换 (按键 C)
    reg octave_shift = 1'b0; reg key12_prev = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin octave_shift <= 0; key12_prev <= 0; end
        else begin
            key12_prev <= key_pressed[12];
            if (key_pressed[12] && !key12_prev) octave_shift <= ~octave_shift;
        end
    end

    // 维度3：音量档位切换 (按键 B)
    reg [1:0] volume_level = 2'd3; reg key11_prev = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin volume_level <= 2'd3; key11_prev <= 0; end
        else begin
            key11_prev <= key_pressed[11];
            if (key_pressed[11] && !key11_prev) begin
                if (volume_level == 2'd0) volume_level <= 2'd3;
                else volume_level <= volume_level - 1'b1;
            end
        end
    end

    // 维度4：空间混响/延迟开关/回声 (按键 * )
    reg delay_en = 1'b0; reg key13_prev = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin delay_en <= 1'b0; key13_prev <= 1'b0; end
        else begin
            key13_prev <= key_pressed[13];
            if (key_pressed[13] && !key13_prev) delay_en <= ~delay_en;
        end
    end

    // ============================================================================
    // 5. 自动演奏模块 (脱机曲目演绎)
    // ============================================================================
    reg auto_play = 1'b0; reg auto_paused = 1'b0; reg [1:0] song_sel = 2'd0; 
    reg key14_prev = 1'b0; reg key9_prev = 1'b0;
    reg [5:0] melody_idx = 6'd0; reg [4:0] beat_cnt = 5'd0; reg [4:0] auto_note = 5'd31;

    // 内置 3 首完整曲目 (包含音符频率索引与节拍长度)
    //《C大调前奏曲》
    wire [4:0] m1_note [0:63]; wire [4:0] m1_len [0:63];
    assign m1_note[0]=5'd1;  assign m1_len[0]=5'd2;  assign m1_note[1]=5'd3;  assign m1_len[1]=5'd2;
    assign m1_note[2]=5'd5;  assign m1_len[2]=5'd2;  assign m1_note[3]=5'd8;  assign m1_len[3]=5'd2;
    assign m1_note[4]=5'd10; assign m1_len[4]=5'd2;  assign m1_note[5]=5'd12; assign m1_len[5]=5'd2;
    assign m1_note[6]=5'd10; assign m1_len[6]=5'd2;  assign m1_note[7]=5'd8;  assign m1_len[7]=5'd2;
    assign m1_note[8]=5'd2;  assign m1_len[8]=5'd2;  assign m1_note[9]=5'd4;  assign m1_len[9]=5'd2;
    assign m1_note[10]=5'd6; assign m1_len[10]=5'd2; assign m1_note[11]=5'd8; assign m1_len[11]=5'd2;
    assign m1_note[12]=5'd11;assign m1_len[12]=5'd2; assign m1_note[13]=5'd13;assign m1_len[13]=5'd2;
    assign m1_note[14]=5'd11;assign m1_len[14]=5'd2; assign m1_note[15]=5'd8; assign m1_len[15]=5'd2;
    assign m1_note[16]=5'd5; assign m1_len[16]=5'd2; assign m1_note[17]=5'd7; assign m1_len[17]=5'd2;
    assign m1_note[18]=5'd9; assign m1_len[18]=5'd2; assign m1_note[19]=5'd11;assign m1_len[19]=5'd2;
    assign m1_note[20]=5'd9; assign m1_len[20]=5'd2; assign m1_note[21]=5'd7; assign m1_len[21]=5'd2;
    assign m1_note[22]=5'd5; assign m1_len[22]=5'd2; assign m1_note[23]=5'd7; assign m1_len[23]=5'd2;
    assign m1_note[24]=5'd1; assign m1_len[24]=5'd2; assign m1_note[25]=5'd3; assign m1_len[25]=5'd2;
    assign m1_note[26]=5'd5; assign m1_len[26]=5'd2; assign m1_note[27]=5'd8; assign m1_len[27]=5'd2;
    assign m1_note[28]=5'd10;assign m1_len[28]=5'd2; assign m1_note[29]=5'd12;assign m1_len[29]=5'd2;
    assign m1_note[30]=5'd10;assign m1_len[30]=5'd2; assign m1_note[31]=5'd8; assign m1_len[31]=5'd2;
    assign m1_note[32]=5'd6; assign m1_len[32]=5'd2; assign m1_note[33]=5'd8; assign m1_len[33]=5'd2;
    assign m1_note[34]=5'd10;assign m1_len[34]=5'd2; assign m1_note[35]=5'd13;assign m1_len[35]=5'd2;
    assign m1_note[36]=5'd10;assign m1_len[36]=5'd2; assign m1_note[37]=5'd8; assign m1_len[37]=5'd2;
    assign m1_note[38]=5'd6; assign m1_len[38]=5'd2; assign m1_note[39]=5'd8; assign m1_len[39]=5'd2;
    assign m1_note[40]=5'd2; assign m1_len[40]=5'd2; assign m1_note[41]=5'd4; assign m1_len[41]=5'd2;
    assign m1_note[42]=5'd6; assign m1_len[42]=5'd2; assign m1_note[43]=5'd8; assign m1_len[43]=5'd2;
    assign m1_note[44]=5'd6; assign m1_len[44]=5'd2; assign m1_note[45]=5'd4; assign m1_len[45]=5'd2;
    assign m1_note[46]=5'd2; assign m1_len[46]=5'd2; assign m1_note[47]=5'd4; assign m1_len[47]=5'd2;
    assign m1_note[48]=5'd5; assign m1_len[48]=5'd2; assign m1_note[49]=5'd7; assign m1_len[49]=5'd2;
    assign m1_note[50]=5'd9; assign m1_len[50]=5'd2; assign m1_note[51]=5'd12;assign m1_len[51]=5'd2;
    assign m1_note[52]=5'd9; assign m1_len[52]=5'd2; assign m1_note[53]=5'd7; assign m1_len[53]=5'd2;
    assign m1_note[54]=5'd5; assign m1_len[54]=5'd2; assign m1_note[55]=5'd7; assign m1_len[55]=5'd2;
    assign m1_note[56]=5'd1; assign m1_len[56]=5'd2; assign m1_note[57]=5'd3; assign m1_len[57]=5'd2;
    assign m1_note[58]=5'd5; assign m1_len[58]=5'd2; assign m1_note[59]=5'd8; assign m1_len[59]=5'd2;
    assign m1_note[60]=5'd10;assign m1_len[60]=5'd2; assign m1_note[61]=5'd12;assign m1_len[61]=5'd2;
    assign m1_note[62]=5'd10;assign m1_len[62]=5'd2; assign m1_note[63]=5'd8; assign m1_len[63]=5'd2;

    //《送别长亭外》
    wire [4:0] m2_note [0:63]; wire [4:0] m2_len [0:63];
    assign m2_note[0]=5'd5; assign m2_len[0]=5'd2; assign m2_note[1]=5'd3; assign m2_len[1]=5'd1;
    assign m2_note[2]=5'd5; assign m2_len[2]=5'd1; assign m2_note[3]=5'd8; assign m2_len[3]=5'd4;
    assign m2_note[4]=5'd6; assign m2_len[4]=5'd2; assign m2_note[5]=5'd8; assign m2_len[5]=5'd2;
    assign m2_note[6]=5'd5; assign m2_len[6]=5'd4;
    assign m2_note[7]=5'd5; assign m2_len[7]=5'd2; assign m2_note[8]=5'd1; assign m2_len[8]=5'd1;
    assign m2_note[9]=5'd2; assign m2_len[9]=5'd1; assign m2_note[10]=5'd3;assign m2_len[10]=5'd2;
    assign m2_note[11]=5'd2;assign m2_len[11]=5'd1; assign m2_note[12]=5'd1;assign m2_len[12]=5'd1;
    assign m2_note[13]=5'd2;assign m2_len[13]=5'd8;
    assign m2_note[14]=5'd5;assign m2_len[14]=5'd2; assign m2_note[15]=5'd3;assign m2_len[15]=5'd1;
    assign m2_note[16]=5'd5;assign m2_len[16]=5'd1; assign m2_note[17]=5'd8;assign m2_len[17]=5'd3;
    assign m2_note[18]=5'd7;assign m2_len[18]=5'd1; assign m2_note[19]=5'd6;assign m2_len[19]=5'd2;
    assign m2_note[20]=5'd8;assign m2_len[20]=5'd2; assign m2_note[21]=5'd5;assign m2_len[21]=5'd4;
    assign m2_note[22]=5'd5;assign m2_len[22]=5'd2; assign m2_note[23]=5'd2;assign m2_len[23]=5'd1;
    assign m2_note[24]=5'd3;assign m2_len[24]=5'd1; assign m2_note[25]=5'd4;assign m2_len[25]=5'd3;
    assign m2_note[26]=5'd0;assign m2_len[26]=5'd1; assign m2_note[27]=5'd1;assign m2_len[27]=5'd6;
    assign m2_note[28]=5'd6;assign m2_len[28]=5'd2; assign m2_note[29]=5'd8;assign m2_len[29]=5'd1;
    assign m2_note[30]=5'd8;assign m2_len[30]=5'd3; assign m2_note[31]=5'd7;assign m2_len[31]=5'd2;
    assign m2_note[32]=5'd6;assign m2_len[32]=5'd1; assign m2_note[33]=5'd7;assign m2_len[33]=5'd1;
    assign m2_note[34]=5'd8;assign m2_len[34]=5'd4;
    assign m2_note[35]=5'd6;assign m2_len[35]=5'd1; assign m2_note[36]=5'd7;assign m2_len[36]=5'd1;
    assign m2_note[37]=5'd8;assign m2_len[37]=5'd1; assign m2_note[38]=5'd6;assign m2_len[38]=5'd1;
    assign m2_note[39]=5'd6;assign m2_len[39]=5'd1; assign m2_note[40]=5'd5;assign m2_len[40]=5'd1;
    assign m2_note[41]=5'd3;assign m2_len[41]=5'd1; assign m2_note[42]=5'd1;assign m2_len[42]=5'd1;
    assign m2_note[43]=5'd2;assign m2_len[43]=5'd6;
    assign m2_note[44]=5'd5;assign m2_len[44]=5'd2; assign m2_note[45]=5'd3;assign m2_len[45]=5'd1;
    assign m2_note[46]=5'd5;assign m2_len[46]=5'd1; assign m2_note[47]=5'd8;assign m2_len[47]=5'd3;
    assign m2_note[48]=5'd7;assign m2_len[48]=5'd1; assign m2_note[49]=5'd6;assign m2_len[49]=5'd1;
    assign m2_note[50]=5'd8;assign m2_len[50]=5'd1; assign m2_note[51]=5'd5;assign m2_len[51]=5'd6;
    assign m2_note[52]=5'd5;assign m2_len[52]=5'd2; assign m2_note[53]=5'd2;assign m2_len[53]=5'd1;
    assign m2_note[54]=5'd3;assign m2_len[54]=5'd1; assign m2_note[55]=5'd4;assign m2_len[55]=5'd3;
    assign m2_note[56]=5'd0;assign m2_len[56]=5'd1; assign m2_note[57]=5'd1;assign m2_len[57]=5'd6;
    assign m2_note[58]=5'd31; assign m2_len[58]=5'd4; assign m2_note[59]=5'd31; assign m2_len[59]=5'd4;
    assign m2_note[60]=5'd31; assign m2_len[60]=5'd4; assign m2_note[61]=5'd31; assign m2_len[61]=5'd4;
    assign m2_note[62]=5'd31; assign m2_len[62]=5'd4; assign m2_note[63]=5'd31; assign m2_len[63]=5'd4;

    //《天空之城》
    wire [4:0] m3_note [0:63]; wire [4:0] m3_len [0:63];
    assign m3_note[0]=5'd6; assign m3_len[0]=5'd1; assign m3_note[1]=5'd7; assign m3_len[1]=5'd1;
    assign m3_note[2]=5'd8; assign m3_len[2]=5'd3; assign m3_note[3]=5'd7; assign m3_len[3]=5'd1;
    assign m3_note[4]=5'd8; assign m3_len[4]=5'd2; assign m3_note[5]=5'd10;assign m3_len[5]=5'd2;
    assign m3_note[6]=5'd7; assign m3_len[6]=5'd8;
    assign m3_note[7]=5'd3; assign m3_len[7]=5'd2; assign m3_note[8]=5'd6; assign m3_len[8]=5'd3;
    assign m3_note[9]=5'd5; assign m3_len[9]=5'd1; assign m3_note[10]=5'd6;assign m3_len[10]=5'd2;
    assign m3_note[11]=5'd8;assign m3_len[11]=5'd2; assign m3_note[12]=5'd5;assign m3_len[12]=5'd8;
    assign m3_note[13]=5'd3;assign m3_len[13]=5'd2; assign m3_note[14]=5'd4;assign m3_len[14]=5'd3;
    assign m3_note[15]=5'd3;assign m3_len[15]=5'd1; assign m3_note[16]=5'd4;assign m3_len[16]=5'd2;
    assign m3_note[17]=5'd8;assign m3_len[17]=5'd2; assign m3_note[18]=5'd10;assign m3_len[18]=5'd6;
    assign m3_note[19]=5'd8;assign m3_len[19]=5'd1; assign m3_note[20]=5'd8;assign m3_len[20]=5'd1;
    assign m3_note[21]=5'd7;assign m3_len[21]=5'd3; assign m3_note[22]=5'd4;assign m3_len[22]=5'd1;
    assign m3_note[23]=5'd4;assign m3_len[23]=5'd2; assign m3_note[24]=5'd7;assign m3_len[24]=5'd2;
    assign m3_note[25]=5'd7;assign m3_len[25]=5'd8;
    assign m3_note[26]=5'd6;assign m3_len[26]=5'd1; assign m3_note[27]=5'd7;assign m3_len[27]=5'd1;
    assign m3_note[28]=5'd8;assign m3_len[28]=5'd3; assign m3_note[29]=5'd7;assign m3_len[29]=5'd1;
    assign m3_note[30]=5'd8;assign m3_len[30]=5'd2; assign m3_note[31]=5'd10;assign m3_len[31]=5'd2;
    assign m3_note[32]=5'd7;assign m3_len[32]=5'd6;
    assign m3_note[33]=5'd3;assign m3_len[33]=5'd2; assign m3_note[34]=5'd6;assign m3_len[34]=5'd3;
    assign m3_note[35]=5'd5;assign m3_len[35]=5'd1; assign m3_note[36]=5'd6;assign m3_len[36]=5'd2;
    assign m3_note[37]=5'd8;assign m3_len[37]=5'd2; assign m3_note[38]=5'd5;assign m3_len[38]=5'd6;
    assign m3_note[39]=5'd3;assign m3_len[39]=5'd2; assign m3_note[40]=5'd4;assign m3_len[40]=5'd2;
    assign m3_note[41]=5'd8;assign m3_len[41]=5'd1; assign m3_note[42]=5'd7;assign m3_len[42]=5'd4;
    assign m3_note[43]=5'd8;assign m3_len[43]=5'd2; assign m3_note[44]=5'd9;assign m3_len[44]=5'd2;
    assign m3_note[45]=5'd10;assign m3_len[45]=5'd1; assign m3_note[46]=5'd8;assign m3_len[46]=5'd6;
    assign m3_note[47]=5'd8;assign m3_len[47]=5'd1; assign m3_note[48]=5'd7;assign m3_len[48]=5'd1;
    assign m3_note[49]=5'd6;assign m3_len[49]=5'd2; assign m3_note[50]=5'd7;assign m3_len[50]=5'd2;
    assign m3_note[51]=5'd5;assign m3_len[51]=5'd2; assign m3_note[52]=5'd6;assign m3_len[52]=5'd8;
    assign m3_note[53]=5'd8;assign m3_len[53]=5'd1; assign m3_note[54]=5'd9;assign m3_len[54]=5'd1;
    assign m3_note[55]=5'd10;assign m3_len[55]=5'd3; assign m3_note[56]=5'd9;assign m3_len[56]=5'd1;
    assign m3_note[57]=5'd10;assign m3_len[57]=5'd2; assign m3_note[58]=5'd12;assign m3_len[58]=5'd2;
    assign m3_note[59]=5'd9;assign m3_len[59]=5'd8;
    assign m3_note[60]=5'd31; assign m3_len[60]=5'd4; assign m3_note[61]=5'd31; assign m3_len[61]=5'd4;
    assign m3_note[62]=5'd31; assign m3_len[62]=5'd4; assign m3_note[63]=5'd31; assign m3_len[63]=5'd4;

    // 自动演奏节拍定时器
    reg [23:0] beat_timer_auto = 24'd0; reg beat_tick_auto = 1'b0;
    wire [23:0] auto_period = (song_sel == 2'd0) ? 24'd1_462_272 : 24'd2_193_408;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin beat_timer_auto <= 0; beat_tick_auto <= 0; end
        else if (beat_timer_auto >= auto_period - 1) begin beat_timer_auto <= 0; beat_tick_auto <= 1; end
        else begin beat_timer_auto <= beat_timer_auto + 1; beat_tick_auto <= 0; end
    end

    // 自动演奏状态机 (支持切歌、暂停、手动打断)
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            auto_play <= 1'b0; auto_paused <= 1'b0; song_sel <= 2'd0;
            melody_idx <= 6'd0; beat_cnt <= 5'd0; auto_note <= 5'd31;
            key14_prev <= 1'b0; key9_prev <= 1'b0;
        end else begin
            key14_prev <= key_pressed[14]; key9_prev <= key_pressed[9];
            // 手动弹奏强行打断自动演奏
            if (|{key_pressed[1], key_pressed[2], key_pressed[3], key_pressed[10], key_pressed[4], key_pressed[5], key_pressed[6]}) begin
                auto_play <= 1'b0; auto_paused <= 1'b0;
            end
            else if (key_pressed[14] && !key14_prev) begin
                if (!auto_play) begin
                    auto_play <= 1'b1; auto_paused <= 1'b0; song_sel <= 2'd0;
                    melody_idx <= 6'd0; beat_cnt <= 5'd0; auto_note <= m1_note[0];
                end else if (song_sel == 2'd0) begin
                    song_sel <= 2'd1; melody_idx <= 6'd0; beat_cnt <= 5'd0; auto_note <= m2_note[0];
                end else if (song_sel == 2'd1) begin
                    song_sel <= 2'd2; melody_idx <= 6'd0; beat_cnt <= 5'd0; auto_note <= m3_note[0];
                end else begin 
                    auto_play <= 1'b0; auto_paused <= 1'b0; 
                end
            end
            else if (key_pressed[9] && !key9_prev) begin
                if (auto_play) auto_paused <= ~auto_paused;
            end
            else if (auto_play && !auto_paused && beat_tick_auto) begin
                if (beat_cnt >= ( (song_sel == 2'd0) ? m1_len[melody_idx] : (song_sel == 2'd1) ? m2_len[melody_idx] : m3_len[melody_idx] ) - 1) begin
                    beat_cnt <= 5'd0;
                    if (melody_idx == 6'd63) begin
                        melody_idx <= 6'd0;
                        auto_note <= (song_sel == 2'd0) ? m1_note[0] : (song_sel == 2'd1) ? m2_note[0] : m3_note[0];
                    end else begin
                        melody_idx <= melody_idx + 1'b1;
                        auto_note <= (song_sel == 2'd0) ? m1_note[melody_idx + 1'b1] : (song_sel == 2'd1) ? m2_note[melody_idx + 1'b1] : m3_note[melody_idx + 1'b1];
                    end
                end else begin beat_cnt <= beat_cnt + 1'b1; end
            end
        end
    end

    
    // 6. 节拍器模块
    
    reg [7:0] bpm = 8'd40; reg bpm_dir = 1'b1; reg metronome_en = 1'b0;
    reg key7_prev = 1'b0; reg key8_prev = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin bpm <= 8'd40; bpm_dir <= 1'b1; metronome_en <= 1'b0; key7_prev <= 1'b0; key8_prev <= 1'b0; end
        else begin
            key7_prev <= key_pressed[7]; key8_prev <= key_pressed[8];
            // 开启/关闭节拍器
            if (key_pressed[7] && !key7_prev) begin metronome_en <= ~metronome_en; if (!metronome_en) begin bpm <= 8'd40; bpm_dir <= 1'b1; end end
            // 调速 (限制在 40 ~ 180)
            if (key_pressed[8] && !key8_prev) begin
                if (bpm_dir == 1'b1) begin if (bpm >= 8'd180) begin bpm_dir <= 1'b0; bpm <= 8'd170; end else bpm <= bpm + 8'd10; end
                else begin if (bpm <= 8'd40) begin bpm_dir <= 1'b1; bpm <= 8'd50; end else bpm <= bpm - 8'd10; end
            end
        end
    end
    
    // BPM 查表转为时钟周期数 (以 12.288MHz 为基准)
    reg [24:0] beat_period;
    always @(*) begin
        case (bpm)
            8'd40: beat_period = 25'd18432000; 8'd50: beat_period = 25'd14745600; 8'd60: beat_period = 25'd12288000; 
            8'd70: beat_period = 25'd10532571; 8'd80: beat_period = 25'd9216000;  8'd90: beat_period = 25'd8192000;
            8'd100: beat_period = 25'd7372800; 8'd110: beat_period = 25'd6702545; 8'd120: beat_period = 25'd6144000; 
            8'd130: beat_period = 25'd5671384; 8'd140: beat_period = 25'd5266285; 8'd150: beat_period = 25'd4915200;
            8'd160: beat_period = 25'd4608000; 8'd170: beat_period = 25'd4336941; 8'd180: beat_period = 25'd4096000;
            default: beat_period = 25'd18432000;
        endcase
    end
    
    // 节拍触发与音效产生
    reg [24:0] metronome_cnt; reg beat_tick; 
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin metronome_cnt <= 25'd0; beat_tick <= 1'b0; end
        else if (!metronome_en) begin metronome_cnt <= 25'd0; beat_tick <= 1'b0; end
        else if (metronome_cnt >= beat_period - 1) begin metronome_cnt <= 25'd0; beat_tick <= 1'b1; end
        else begin metronome_cnt <= metronome_cnt + 1'b1; beat_tick <= 1'b0; end
    end
    reg [20:0] click_led_timer; reg [31:0] click_phase;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin click_led_timer <= 21'd0; click_phase <= 32'd0; end
        else begin
            if (beat_tick) click_led_timer <= 21'd1228800; 
            else if (click_led_timer > 0) click_led_timer <= click_led_timer - 1;
            if (click_led_timer > 0) click_phase <= click_phase + 32'd731177;
            else click_phase <= 32'd0;
        end
    end
    wire signed [15:0] click_audio = (click_led_timer > 0) ? (click_phase[31] ? 16'sd4000 : -16'sd4000) : 16'sd0;
    wire led7_beat = (click_led_timer > 0);

    
    // 7. 4 复音并发动态分配引擎 (赛题核心指标: ≥4 复音)
    
    reg [4:0] v1_key = 5'd31, v2_key = 5'd31, v3_key = 5'd31, v4_key = 5'd31;
    reg [31:0] v1_freq = 0, v2_freq = 0, v3_freq = 0, v4_freq = 0;

    // 提取当前按键按下的音符（边缘检测，保证按下瞬间才触发）
    wire [6:0] note_now = {key_pressed[6], key_pressed[5], key_pressed[4], key_pressed[10], key_pressed[3], key_pressed[2], key_pressed[1]};
    reg [6:0] note_prev = 7'd0;
    wire [6:0] note_edge = note_now & ~note_prev;

    reg [3:0] new_note = 4'd15;
    always @(*) begin
        if (note_edge[0]) new_note = 4'd1;
        else if (note_edge[1]) new_note = 4'd2;
        else if (note_edge[2]) new_note = 4'd3;
        else if (note_edge[3]) new_note = 4'd10;
        else if (note_edge[4]) new_note = 4'd4;
        else if (note_edge[5]) new_note = 4'd5;
        else if (note_edge[6]) new_note = 4'd6;
        else new_note = 4'd15;
    end

    // 分配器逻辑 (支持自动演奏强行占用 v1 通道)
    reg [4:0] v1_key_n, v2_key_n, v3_key_n, v4_key_n;
    reg [31:0] v1_freq_n, v2_freq_n, v3_freq_n, v4_freq_n;

    always @(*) begin
        v1_key_n = v1_key; v2_key_n = v2_key; v3_key_n = v3_key; v4_key_n = v4_key;
        v1_freq_n = v1_freq; v2_freq_n = v2_freq; v3_freq_n = v3_freq; v4_freq_n = v4_freq;

        if (auto_play) begin
            if (auto_paused || auto_note == 5'd31) begin
                v1_key_n = 5'd31; v1_freq_n = 32'd0;
            end else begin
                v1_key_n = auto_note; v1_freq_n = freq_of_melody(auto_note);
            end
        end else begin
            // 检测按键是否松开，若松开则释放该声道
            if (v1_key != 5'd31 && v1_key <= 5'd14 && !key_pressed[v1_key[3:0]]) v1_key_n = 5'd31;
            if (v2_key != 5'd31 && v2_key <= 5'd14 && !key_pressed[v2_key[3:0]]) v2_key_n = 5'd31;
            if (v3_key != 5'd31 && v3_key <= 5'd14 && !key_pressed[v3_key[3:0]]) v3_key_n = 5'd31;
            if (v4_key != 5'd31 && v4_key <= 5'd14 && !key_pressed[v4_key[3:0]]) v4_key_n = 5'd31;

            // 有空闲通道则分配新音符
            if (new_note != 4'd15) begin
                if (v1_key_n == 5'd31) begin v1_key_n = {1'b0, new_note}; v1_freq_n = freq_of_key(new_note); end
                else if (v2_key_n == 5'd31) begin v2_key_n = {1'b0, new_note}; v2_freq_n = freq_of_key(new_note); end
                else if (v3_key_n == 5'd31) begin v3_key_n = {1'b0, new_note}; v3_freq_n = freq_of_key(new_note); end
                else if (v4_key_n == 5'd31) begin v4_key_n = {1'b0, new_note}; v4_freq_n = freq_of_key(new_note); end
            end
        end
    end

    // 定时器：每 4ms 更新一次声部分配，防止抢占混乱
    reg [15:0] assign_timer = 16'd0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) assign_timer <= 16'd0;
        else if (assign_timer == 16'd49151) assign_timer <= 16'd0;
        else assign_timer <= assign_timer + 1'b1;
    end

    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            v1_key <= 5'd31; v2_key <= 5'd31; v3_key <= 5'd31; v4_key <= 5'd31;
            v1_freq <= 0; v2_freq <= 0; v3_freq <= 0; v4_freq <= 0;
            note_prev <= 7'd0;
        end else if (assign_timer == 16'd49151) begin
            v1_key <= v1_key_n; v2_key <= v2_key_n; v3_key <= v3_key_n; v4_key <= v4_key_n;
            v1_freq <= v1_freq_n; v2_freq <= v2_freq_n; v3_freq <= v3_freq_n; v4_freq <= v4_freq_n;
            note_prev <= note_now;
        end
    end

    wire v1_gate = (v1_key != 5'd31);
    wire v2_gate = (v2_key != 5'd31);
    wire v3_gate = (v3_key != 5'd31);
    wire v4_gate = (v4_key != 5'd31);

    // 八度频率倍频处理
    wire [31:0] v1_fs = octave_shift ? (v1_freq << 1) : v1_freq;
    wire [31:0] v2_fs = octave_shift ? (v2_freq << 1) : v2_freq;
    wire [31:0] v3_fs = octave_shift ? (v3_freq << 1) : v3_freq;
    wire [31:0] v4_fs = octave_shift ? (v4_freq << 1) : v4_freq;

    
    // 8. 特色效果器：滑音 (Glide) + 揉弦 (Vibrato)
    
    // 延音踏板 (按键 0)
    wire sustain_pedal = key_pressed[0]; 
    localparam GRACE_TIME = 24'd2_457_600;
    reg [23:0] v1_grace = 0, v2_grace = 0, v3_grace = 0, v4_grace = 0;

    reg octave_shift_d = 1'b0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) octave_shift_d <= 1'b0;
        else        octave_shift_d <= octave_shift;
    end
    wire octave_changed = (octave_shift != octave_shift_d);

    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            v1_grace <= 0; v2_grace <= 0; v3_grace <= 0; v4_grace <= 0;
        end else begin
            if (v1_gate) v1_grace <= GRACE_TIME; else if (v1_grace > 0) v1_grace <= v1_grace - 1;
            if (v2_gate) v2_grace <= GRACE_TIME; else if (v2_grace > 0) v2_grace <= v2_grace - 1;
            if (v3_gate) v3_grace <= GRACE_TIME; else if (v3_grace > 0) v3_grace <= v3_grace - 1;
            if (v4_gate) v4_grace <= GRACE_TIME; else if (v4_grace > 0) v4_grace <= v4_grace - 1;
        end
    end

    wire v1_new_assign = (assign_timer == 16'd49151) && (v1_key_n != 5'd31) && (v1_key == 5'd31) && (v1_grace == 0);
    wire v2_new_assign = (assign_timer == 16'd49151) && (v2_key_n != 5'd31) && (v2_key == 5'd31) && (v2_grace == 0);
    wire v3_new_assign = (assign_timer == 16'd49151) && (v3_key_n != 5'd31) && (v3_key == 5'd31) && (v3_grace == 0);
    wire v4_new_assign = (assign_timer == 16'd49151) && (v4_key_n != 5'd31) && (v4_key == 5'd31) && (v4_grace == 0);

    // 滑音定时器
    reg [12:0] glide_timer = 13'd0;
    wire glide_tick = (glide_timer == 13'd5000);
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) glide_timer <= 13'd0;
        else if (glide_tick) glide_timer <= 13'd0;
        else glide_timer <= glide_timer + 1'b1;
    end

    // 4路独立滑音追踪处理 (每次步进 64 个频率字，实现顺畅过渡)
    reg [31:0] glide_1 = 0, glide_2 = 0, glide_3 = 0, glide_4 = 0;
    localparam GLIDE_STEP = 32'd64;

    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            glide_1 <= 0; glide_2 <= 0; glide_3 <= 0; glide_4 <= 0;
        end else if (auto_play) begin
            glide_1 <= v1_fs; glide_2 <= v2_fs; glide_3 <= v3_fs; glide_4 <= v4_fs;
        end else if (octave_changed) begin
            glide_1 <= v1_fs; glide_2 <= v2_fs; glide_3 <= v3_fs; glide_4 <= v4_fs;
        end else if (v1_new_assign || v2_new_assign || v3_new_assign || v4_new_assign) begin
            if (v1_new_assign) glide_1 <= octave_shift ? (v1_freq_n << 1) : v1_freq_n;
            if (v2_new_assign) glide_2 <= octave_shift ? (v2_freq_n << 1) : v2_freq_n;
            if (v3_new_assign) glide_3 <= octave_shift ? (v3_freq_n << 1) : v3_freq_n;
            if (v4_new_assign) glide_4 <= octave_shift ? (v4_freq_n << 1) : v4_freq_n;
        end else if (glide_tick) begin
            if (!v1_gate) begin if (v1_grace == 0 && !sustain_pedal) glide_1 <= 0; end
            else begin
                if (glide_1 < v1_fs) begin if (v1_fs - glide_1 > GLIDE_STEP) glide_1 <= glide_1 + GLIDE_STEP; else glide_1 <= v1_fs; end
                else if (glide_1 > v1_fs) begin if (glide_1 - v1_fs > GLIDE_STEP) glide_1 <= glide_1 - GLIDE_STEP; else glide_1 <= v1_fs; end
            end
            if (!v2_gate) begin if (v2_grace == 0 && !sustain_pedal) glide_2 <= 0; end
            else begin
                if (glide_2 < v2_fs) begin if (v2_fs - glide_2 > GLIDE_STEP) glide_2 <= glide_2 + GLIDE_STEP; else glide_2 <= v2_fs; end
                else if (glide_2 > v2_fs) begin if (glide_2 - v2_fs > GLIDE_STEP) glide_2 <= glide_2 - GLIDE_STEP; else glide_2 <= v2_fs; end
            end
            if (!v3_gate) begin if (v3_grace == 0 && !sustain_pedal) glide_3 <= 0; end
            else begin
                if (glide_3 < v3_fs) begin if (v3_fs - glide_3 > GLIDE_STEP) glide_3 <= glide_3 + GLIDE_STEP; else glide_3 <= v3_fs; end
                else if (glide_3 > v3_fs) begin if (glide_3 - v3_fs > GLIDE_STEP) glide_3 <= glide_3 - GLIDE_STEP; else glide_3 <= v3_fs; end
            end
            if (!v4_gate) begin if (v4_grace == 0 && !sustain_pedal) glide_4 <= 0; end
            else begin
                if (glide_4 < v4_fs) begin if (v4_fs - glide_4 > GLIDE_STEP) glide_4 <= glide_4 + GLIDE_STEP; else glide_4 <= v4_fs; end
                else if (glide_4 > v4_fs) begin if (glide_4 - v4_fs > GLIDE_STEP) glide_4 <= glide_4 - GLIDE_STEP; else glide_4 <= v4_fs; end
            end
        end
    end

    // 揉弦引擎 (按住发声 3 秒后自动触发，受延音踏板强行阻断)
    reg [25:0] vibrato_timer = 26'd0; reg auto_vibrato_en = 1'b0;
    reg [20:0] vib_delay_cnt = 21'd0; reg [7:0] vib_depth = 8'd0;
    wire any_gate = v1_gate | v2_gate | v3_gate | v4_gate;

    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            vibrato_timer <= 26'd0; auto_vibrato_en <= 1'b0; vib_delay_cnt <= 21'd0; vib_depth <= 8'd0;
        end else if (auto_play || !any_gate || (new_note != 4'd15) || sustain_pedal) begin
            vibrato_timer <= 26'd0; auto_vibrato_en <= 1'b0; vib_delay_cnt <= 21'd0; 
            // 平滑退出防止破音 (踩下延音踏板瞬间，揉弦颤音深度快速衰减至0)
            if (vib_depth > 0) vib_depth <= vib_depth - 1;
            else vib_depth <= 8'd0;
        end else begin
            if (vibrato_timer < 26'd36_864_000) vibrato_timer <= vibrato_timer + 1'b1;
            else auto_vibrato_en <= 1'b1; 
            if (auto_vibrato_en) begin
                if (vib_delay_cnt < 21'd1_843_200) vib_delay_cnt <= vib_delay_cnt + 1;
                else if (vib_depth < 8'd128) vib_depth <= vib_depth + 1;
            end
        end
    end

    // 正弦波 LUT (用于揉弦颤音 LFO 调制)
    function signed [15:0] lfo_sin_lut;
        input [5:0] addr;
        begin
            case (addr)
                6'd0 : lfo_sin_lut = 16'sd0;       6'd1 : lfo_sin_lut = 16'sd3212;
                6'd2 : lfo_sin_lut = 16'sd6393;    6'd3 : lfo_sin_lut = 16'sd9512;
                6'd4 : lfo_sin_lut = 16'sd12539;   6'd5 : lfo_sin_lut = 16'sd15446;
                6'd6 : lfo_sin_lut = 16'sd18204;   6'd7 : lfo_sin_lut = 16'sd20787;
                6'd8 : lfo_sin_lut = 16'sd23170;   6'd9 : lfo_sin_lut = 16'sd25329;
                6'd10: lfo_sin_lut = 16'sd27245;   6'd11: lfo_sin_lut = 16'sd28898;
                6'd12: lfo_sin_lut = 16'sd30273;   6'd13: lfo_sin_lut = 16'sd31356;
                6'd14: lfo_sin_lut = 16'sd32137;   6'd15: lfo_sin_lut = 16'sd32609;
                6'd16: lfo_sin_lut = 16'sd32767;   6'd17: lfo_sin_lut = 16'sd32609;
                6'd18: lfo_sin_lut = 16'sd32137;   6'd19: lfo_sin_lut = 16'sd31356;
                6'd20: lfo_sin_lut = 16'sd30273;   6'd21: lfo_sin_lut = 16'sd28898;
                6'd22: lfo_sin_lut = 16'sd27245;   6'd23: lfo_sin_lut = 16'sd25329;
                6'd24: lfo_sin_lut = 16'sd23170;   6'd25: lfo_sin_lut = 16'sd20787;
                6'd26: lfo_sin_lut = 16'sd18204;   6'd27: lfo_sin_lut = 16'sd15446;
                6'd28: lfo_sin_lut = 16'sd12539;   6'd29: lfo_sin_lut = 16'sd9512;
                6'd30: lfo_sin_lut = 16'sd6393;    6'd31: lfo_sin_lut = 16'sd3212;
                6'd32: lfo_sin_lut = 16'sd0;       6'd33: lfo_sin_lut = -16'sd3212;
                6'd34: lfo_sin_lut = -16'sd6393;   6'd35: lfo_sin_lut = -16'sd9512;
                6'd36: lfo_sin_lut = -16'sd12539;  6'd37: lfo_sin_lut = -16'sd15446;
                6'd38: lfo_sin_lut = -16'sd18204;  6'd39: lfo_sin_lut = -16'sd20787;
                6'd40: lfo_sin_lut = -16'sd23170;  6'd41: lfo_sin_lut = -16'sd25329;
                6'd42: lfo_sin_lut = -16'sd27245;  6'd43: lfo_sin_lut = -16'sd28898;
                6'd44: lfo_sin_lut = -16'sd30273;  6'd45: lfo_sin_lut = -16'sd31356;
                6'd46: lfo_sin_lut = -16'sd32137;  6'd47: lfo_sin_lut = -16'sd32609;
                6'd48: lfo_sin_lut = -16'sd32767;  6'd49: lfo_sin_lut = -16'sd32609;
                6'd50: lfo_sin_lut = -16'sd32137;  6'd51: lfo_sin_lut = -16'sd31356;
                6'd52: lfo_sin_lut = -16'sd30273;  6'd53: lfo_sin_lut = -16'sd28898;
                6'd54: lfo_sin_lut = -16'sd27245;  6'd55: lfo_sin_lut = -16'sd25329;
                6'd56: lfo_sin_lut = -16'sd23170;  6'd57: lfo_sin_lut = -16'sd20787;
                6'd58: lfo_sin_lut = -16'sd18204;  6'd59: lfo_sin_lut = -16'sd15446;
                6'd60: lfo_sin_lut = -16'sd12539;  6'd61: lfo_sin_lut = -16'sd9512;
                6'd62: lfo_sin_lut = -16'sd6393;   6'd63: lfo_sin_lut = -16'sd3212;
                default: lfo_sin_lut = 16'sd0;
            endcase
        end
    endfunction

    // LFO 相位累加器 (频率约为 4.86Hz)
    reg [31:0] lfo_phase = 32'd0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) lfo_phase <= 32'd0;
        else lfo_phase <= lfo_phase + 32'd1700; 
    end

    wire signed [15:0] lfo_raw = lfo_sin_lut(lfo_phase[31:26]);
    wire signed [16:0] lfo_uni = (lfo_raw >>> 1) + 17'sd16384;
    wire signed [31:0] vib_offset_raw = lfo_uni * vib_depth;
    wire signed [15:0] vibrato_offset = vib_offset_raw >>> 10; 

    // DDS 频率字叠加揉弦颤音偏移
    wire [31:0] freq1_add = (glide_1 == 0) ? 32'd0 : (glide_1 + vibrato_offset);
    wire [31:0] freq2_add = (glide_2 == 0) ? 32'd0 : (glide_2 + vibrato_offset);
    wire [31:0] freq3_add = (glide_3 == 0) ? 32'd0 : (glide_3 + vibrato_offset);
    wire [31:0] freq4_add = (glide_4 == 0) ? 32'd0 : (glide_4 + vibrato_offset);

    
    // 9. 纯硬件实时并行 DDS 引擎 (赛题红线和评分重点)
    
    // 每路拥有完全独立的 32-bit 相位累加器，无时分复用，无软件介入。
    reg [31:0] pa1 = 0, pa2 = 0, pa3 = 0, pa4 = 0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin 
            pa1 <= 32'h0000_0000; pa2 <= 32'h4000_0000; pa3 <= 32'h8000_0000; pa4 <= 32'hC000_0000; // 错开初始相位
        end else begin
            pa1 <= pa1 + freq1_add; 
            pa2 <= pa2 + freq2_add; 
            pa3 <= pa3 + freq3_add; 
            pa4 <= pa4 + freq4_add;
        end
    end

    
    // 10. 多音色波形生成 (赛题要求: ≥2 种音色预设)
    
    // 1. 钢琴
    wire signed [15:0] saw1 = {1'b0, pa1[31:16]} - 16'sd32768;
    wire signed [15:0] saw2 = {1'b0, pa2[31:16]} - 16'sd32768;
    wire signed [15:0] saw3 = {1'b0, pa3[31:16]} - 16'sd32768;
    wire signed [15:0] saw4 = {1'b0, pa4[31:16]} - 16'sd32768;

    // 2. 复古管风琴/8-bit游戏音
    wire signed [15:0] sqr1 = pa1[31] ? 16'sd30000 : -16'sd30000;
    wire signed [15:0] sqr2 = pa2[31] ? 16'sd30000 : -16'sd30000;
    wire signed [15:0] sqr3 = pa3[31] ? 16'sd30000 : -16'sd30000;
    wire signed [15:0] sqr4 = pa4[31] ? 16'sd30000 : -16'sd30000;

    // 3. 长笛
    wire [14:0] tri_amp_1 = pa1[31] ? (15'h7FFF - pa1[30:16]) : pa1[30:16];
    wire [14:0] tri_amp_2 = pa2[31] ? (15'h7FFF - pa2[30:16]) : pa2[30:16];
    wire [14:0] tri_amp_3 = pa3[31] ? (15'h7FFF - pa3[30:16]) : pa3[30:16];
    wire [14:0] tri_amp_4 = pa4[31] ? (15'h7FFF - pa4[30:16]) : pa4[30:16];

    wire signed [15:0] tri_wave1 = {tri_amp_1[14:0], 1'b0} - 16'sd32768;
    wire signed [15:0] tri_wave2 = {tri_amp_2[14:0], 1'b0} - 16'sd32768;
    wire signed [15:0] tri_wave3 = {tri_amp_3[14:0], 1'b0} - 16'sd32768;
    wire signed [15:0] tri_wave4 = {tri_amp_4[14:0], 1'b0} - 16'sd32768;

    // 音色选择器 (根据 timbre_sel 切换)
    wire signed [15:0] w1 = (timbre_sel == 2'b00) ? saw1 : (timbre_sel == 2'b01) ? sqr1 : tri_wave1;
    wire signed [15:0] w2 = (timbre_sel == 2'b00) ? saw2 : (timbre_sel == 2'b01) ? sqr2 : tri_wave2;
    wire signed [15:0] w3 = (timbre_sel == 2'b00) ? saw3 : (timbre_sel == 2'b01) ? sqr3 : tri_wave3;
    wire signed [15:0] w4 = (timbre_sel == 2'b00) ? saw4 : (timbre_sel == 2'b01) ? sqr4 : tri_wave4;

    
    // 11. 四路独立 ADSR 包络发生器 (展现钢琴级自然延音)
    
    // 包络速度控制，每 2000 个时钟采样一次 (约 6kHz 更新率)
    reg [15:0] adsr_div = 0; reg adsr_tick = 0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin adsr_div <= 0; adsr_tick <= 0; end
        else if (adsr_div == 16'd2000) begin adsr_div <= 0; adsr_tick <= 1; end
        else begin adsr_div <= adsr_div + 1; adsr_tick <= 0; end
    end

    // 钢琴延音慢速衰减分频器 (踏板踩下时，利用计数器溢出时间延长衰减周期)
    reg [7:0] pedal_cnt = 8'd0;
    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) pedal_cnt <= 8'd0;
        else if (adsr_tick) begin
            if (sustain_pedal) pedal_cnt <= pedal_cnt + 1'b1;
            else pedal_cnt <= 8'd0;
        end
    end

    reg [2:0] st1 = 0, st2 = 0, st3 = 0, st4 = 0;
    reg [7:0] e1 = 0, e2 = 0, e3 = 0, e4 = 0;
    localparam IDLE = 0, ATTACK = 1, DECAY = 2, SUSTAIN = 3;

    always @(posedge clk_12m288 or negedge rst_n_12m) begin
        if (!rst_n_12m) begin
            st1 <= IDLE; st2 <= IDLE; st3 <= IDLE; st4 <= IDLE;
            e1 <= 0; e2 <= 0; e3 <= 0; e4 <= 0;
        end else if (adsr_tick) begin
            // --- 声部 1 ---
            if (!v1_gate) begin 
                if (sustain_pedal) begin
                    // 踩下踏板：利用 pedal_cnt 溢出做极慢速衰减 (约 10 秒自然消音)
                    if (pedal_cnt == 8'd0) begin if (e1 > 1) e1 <= e1 - 1; else begin e1 <= 0; st1 <= IDLE; end end
                end else begin 
                    // 未踩踏板：快速释放 (正常断音)
                    if (e1 > 1) e1 <= e1 - 1; else begin e1 <= 0; st1 <= IDLE; end 
                end
            end else case (st1)
                IDLE: st1 <= ATTACK;
                ATTACK: if (e1 >= 255) begin e1 <= 255; st1 <= DECAY; end else e1 <= e1 + 1;
                DECAY: if (timbre_sel == 2'b01) begin e1 <= 255; st1 <= SUSTAIN; end // 方波无衰减
                       else if (e1 <= 128) begin e1 <= 128; st1 <= SUSTAIN; end
                       else e1 <= e1 - 2;
                SUSTAIN: if (timbre_sel == 2'b01) e1 <= 255; else e1 <= 128;
            endcase
            
            // --- 声部 2 ---
            if (!v2_gate) begin 
                if (sustain_pedal) begin
                    if (pedal_cnt == 8'd0) begin if (e2 > 1) e2 <= e2 - 1; else begin e2 <= 0; st2 <= IDLE; end end
                end else begin if (e2 > 1) e2 <= e2 - 1; else begin e2 <= 0; st2 <= IDLE; end end
            end else case (st2)
                IDLE: st2 <= ATTACK;
                ATTACK: if (e2 >= 255) begin e2 <= 255; st2 <= DECAY; end else e2 <= e2 + 1;
                DECAY: if (timbre_sel == 2'b01) begin e2 <= 255; st2 <= SUSTAIN; end
                       else if (e2 <= 128) begin e2 <= 128; st2 <= SUSTAIN; end
                       else e2 <= e2 - 2;
                SUSTAIN: if (timbre_sel == 2'b01) e2 <= 255; else e2 <= 128;
            endcase
            
            // --- 声部 3 ---
            if (!v3_gate) begin 
                if (sustain_pedal) begin
                    if (pedal_cnt == 8'd0) begin if (e3 > 1) e3 <= e3 - 1; else begin e3 <= 0; st3 <= IDLE; end end
                end else begin if (e3 > 1) e3 <= e3 - 1; else begin e3 <= 0; st3 <= IDLE; end end
            end else case (st3)
                IDLE: st3 <= ATTACK;
                ATTACK: if (e3 >= 255) begin e3 <= 255; st3 <= DECAY; end else e3 <= e3 + 1;
                DECAY: if (timbre_sel == 2'b01) begin e3 <= 255; st3 <= SUSTAIN; end
                       else if (e3 <= 128) begin e3 <= 128; st3 <= SUSTAIN; end
                       else e3 <= e3 - 2;
                SUSTAIN: if (timbre_sel == 2'b01) e3 <= 255; else e3 <= 128;
            endcase
            
            // --- 声部 4 ---
            if (!v4_gate) begin 
                if (sustain_pedal) begin
                    if (pedal_cnt == 8'd0) begin if (e4 > 1) e4 <= e4 - 1; else begin e4 <= 0; st4 <= IDLE; end end
                end else begin if (e4 > 1) e4 <= e4 - 1; else begin e4 <= 0; st4 <= IDLE; end end
            end else case (st4)
                IDLE: st4 <= ATTACK;
                ATTACK: if (e4 >= 255) begin e4 <= 255; st4 <= DECAY; end else e4 <= e4 + 1;
                DECAY: if (timbre_sel == 2'b01) begin e4 <= 255; st4 <= SUSTAIN; end
                       else if (e4 <= 128) begin e4 <= 128; st4 <= SUSTAIN; end
                       else e4 <= e4 - 2;
                SUSTAIN: if (timbre_sel == 2'b01) e4 <= 255; else e4 <= 128;
            endcase
        end
    end

    
    // 12. 安全混音总线与音量控制 (适配 4Ω 3W 扬声器)
    
    wire signed [23:0] m1 = w1 * $signed({1'b0, e1});
    wire signed [23:0] m2 = w2 * $signed({1'b0, e2});
    wire signed [23:0] m3 = w3 * $signed({1'b0, e3});
    wire signed [23:0] m4 = w4 * $signed({1'b0, e4});

    // 多声部数字累加

    wire signed [25:0] mix_sum_4 = m1[23:8] + m2[23:8] + m3[23:8] + m4[23:8];
    wire signed [25:0] mix_sum = mix_sum_4 + $signed({10'd0, click_audio});

    wire signed [15:0] mix_16 = mix_sum[17:2]; 
    
    // 物理防爆音/过载限幅器 (防止大功率功放触发断电保护)

    wire signed [15:0] clipped = (mix_16 > 16'sd28000)  ? 16'sd28000 :
                                (mix_16 < -16'sd28000) ? -16'sd28000 :
                                mix_16;

    // 4 档音量调节 (右移对应除以 2、8)

    wire signed [15:0] final_audio = (volume_level == 2'd3) ? clipped :
                                     (volume_level == 2'd2) ? (clipped >>> 1) :
                                     (volume_level == 2'd1) ? (clipped >>> 3) :
                                     16'sd0;

   
    // 13. 音频效果与 I2S 传输
   
    wire signed [15:0] audio_with_delay;
    delay_effect u_delay (
        .clk(clk_12m288), .rst_n(rst_n_12m), .effect_en(delay_en),
        .audio_in(final_audio), .audio_out(audio_with_delay)
    );

    i2s_tx u_i2s_tx (
        .clk(clk_12m288), .rst_n(rst_n_12m),
        .audio_l(audio_with_delay), .audio_r(audio_with_delay),
        .bck(hp_bck), .ws(hp_ws), .data(hp_din), .pa_en(pa_en)
    );

    
    // 14. 赛题可视化扩展：FPGA 硬件逻辑驱动的 LED 与幻彩灯效
    
    reg [3:0] max_note;
    reg [31:0] max_freq;
    always @(*) begin
        max_freq = 32'd0;
        max_note = 4'd0;
        if (auto_play && auto_note != 5'd31 && !auto_paused) begin
            max_freq = freq_of_melody(auto_note);
            if (auto_note > 5'd14)      max_note = auto_note - 5'd14; 
            else if (auto_note > 5'd7)  max_note = auto_note - 5'd7;  
            else                        max_note = auto_note[3:0];    
            if (octave_shift) max_freq = max_freq << 1;
        end else begin
            if (key_pressed[6])      begin max_freq = 32'd172581; max_note = 4'd7; end 
            else if (key_pressed[5]) begin max_freq = 32'd153766; max_note = 4'd6; end 
            else if (key_pressed[4]) begin max_freq = 32'd137048; max_note = 4'd5; end 
            else if (key_pressed[10])begin max_freq = 32'd122080; max_note = 4'd4; end 
            else if (key_pressed[3]) begin max_freq = 32'd115228; max_note = 4'd3; end 
            else if (key_pressed[2]) begin max_freq = 32'd102654; max_note = 4'd2; end 
            else if (key_pressed[1]) begin max_freq = 32'd91444;  max_note = 4'd1; end 
            if (octave_shift) max_freq = max_freq << 1;
        end
    end

    // LED 频率柱状图

    reg [7:0] led_reg;
    always @(*) begin
        if      (max_freq == 0)                led_reg = 8'b00000000;
        else if (max_freq < 32'd97000)         led_reg = 8'b00000001;
        else if (max_freq < 32'd108000)        led_reg = 8'b00000010;
        else if (max_freq < 32'd118000)        led_reg = 8'b00000100;
        else if (max_freq < 32'd130000)        led_reg = 8'b00001000;
        else if (max_freq < 32'd145000)        led_reg = 8'b00010000;
        else if (max_freq < 32'd163000)        led_reg = 8'b00100000;
        else if (max_freq < 32'd180000)        led_reg = 8'b01000000;
        else                                   led_reg = 8'b10000000;
    end
    assign led_o = metronome_en ? { (led7_beat ? 1'b0 : ~led_reg[7]), ~led_reg[6:0] } : ~led_reg;

    // WS2812 随音名变色

    reg [7:0] ws_r_12m, ws_g_12m, ws_b_12m;
    always @(*) begin
        case (max_note)
            4'd1: begin ws_r_12m = 8'd255; ws_g_12m = 8'd0;   ws_b_12m = 8'd0;   end // Do - 红
            4'd2: begin ws_r_12m = 8'd255; ws_g_12m = 8'd128; ws_b_12m = 8'd0;   end // Re - 橙
            4'd3: begin ws_r_12m = 8'd255; ws_g_12m = 8'd255; ws_b_12m = 8'd0;   end // Mi - 黄
            4'd4: begin ws_r_12m = 8'd0;   ws_g_12m = 8'd255; ws_b_12m = 8'd0;   end // Fa - 绿
            4'd5: begin ws_r_12m = 8'd0;   ws_g_12m = 8'd255; ws_b_12m = 8'd255; end // So - 青
            4'd6: begin ws_r_12m = 8'd0;   ws_g_12m = 8'd0;   ws_b_12m = 8'd255; end // La - 蓝
            4'd7: begin ws_r_12m = 8'd128; ws_g_12m = 8'd0;   ws_b_12m = 8'd255; end // Si - 紫
            default: begin ws_r_12m = 8'd0; ws_g_12m = 8'd0; ws_b_12m = 8'd0;    end 
        endcase
    end

    // 跨时钟域数据同步 (12.288MHz -> 50MHz) 严格遵循打两拍原则
    reg [7:0] ws_r_sync1, ws_r_sync2;
    reg [7:0] ws_g_sync1, ws_g_sync2;
    reg [7:0] ws_b_sync1, ws_b_sync2;
    always @(posedge sys_clk) begin
        ws_r_sync1 <= ws_r_12m; ws_r_sync2 <= ws_r_sync1;
        ws_g_sync1 <= ws_g_12m; ws_g_sync2 <= ws_g_sync1;
        ws_b_sync1 <= ws_b_12m; ws_b_sync2 <= ws_b_sync1;
    end

    wire ws_te;
    WS2812 #(
        .clk_freq(50_000_000), .fps(100), .used_led(1), .independent_led_ctrl("false")
    ) WS2812_inst (
        .sys_clk(sys_clk), .rst_n(rst_n), .Do(WS2812),
        .pixel_addr(0), .pixel_Red(ws_r_sync2), .pixel_Green(ws_g_sync2), .pixel_Blue(ws_b_sync2),
        .pixel_valid(1'b1), .TE(ws_te)
    );

    
    // 15. 延迟实测硬件标记 (用于赛题 ≤10ms 指标验证)
    
    // 任一通道 gate 打开时，引脚拉高，供外部示波器捕获，证明系统延迟极低
    assign debug_pin = v1_gate | v2_gate | v3_gate | v4_gate;

endmodule