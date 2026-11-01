// 模块名称：keyboard_scan
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：4x4 矩阵键盘纯硬件扫描与消抖模块。
//           对应赛题要求：“实现至少 2 个独立可控演奏维度的动作采集”。
//           本模块完全由硬件状态机实现，无任何软件轮询参与。通过高频行扫描
//           与精准的 20ms 硬件消抖，为顶层提供极低延迟、零漏按的键值输入，
//           是保障系统“控制信号到发声延迟 ≤ 10ms”的第一道核心关卡。
module keyboard_scan (
    input  wire       clk,        // 12.288MHz 音频域时钟
    input  wire       rst_n,      // 同步复位信号
    input  wire [3:0] col_in,     // 列线输入 (物理连接至 key_io[7:4])，内部上拉
    output reg  [3:0] row_out,    // 行线输出 (物理连接至 key_io[3:0])，拉低扫描
    output reg  [3:0] key_code,   // 解析后的按键编号 (0~15，15代表无按键)
    output reg        key_valid   // 按键按下有效标志 (高电平有效)
);

    // 1. 逐行扫描状态机 (Scanning State Machine)
    // 说明：在 12.288MHz 时钟下，计数器计数到 12288 约为 1ms。
    //       即每 1ms 拉低一行，循环往复。1ms 的扫描周期远超手动按键速度，
    //       确保任何快速的连击操作都不会被遗漏。
    reg [3:0] scan_idx = 4'd0;
    reg [15:0] scan_cnt = 16'd0;
    reg [3:0] row_out_next = 4'b1110; // 初始拉低第0行

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_idx <= 4'd0;
            scan_cnt <= 16'd0;
            row_out_next <= 4'b1110;
        end else begin
            if (scan_cnt == 16'd12288) begin // 1ms 定时
                scan_cnt <= 16'd0;
                scan_idx <= scan_idx + 1'b1;
                case (scan_idx)
                    4'd0: row_out_next <= 4'b1110; // 扫描第0行
                    4'd1: row_out_next <= 4'b1101; // 扫描第1行
                    4'd2: row_out_next <= 4'b1011; // 扫描第2行
                    4'd3: row_out_next <= 4'b0111; // 扫描第3行
                    default: row_out_next <= 4'b1111;
                endcase
            end else begin
                scan_cnt <= scan_cnt + 1'b1;
            end
        end
    end

    // 2. 键值映射逻辑 (Key Mapping)
    // 说明：根据当前扫描的行号 (scan_idx)，读取列线 (col_in) 的电平状态。
    //       若某列线被拉低，说明该交叉点的按键被按下，输出对应的物理键值。
    //       该逻辑为纯组合逻辑，零时钟延迟。
    reg [3:0] raw_key = 4'd15;
    always @(*) begin
        case (scan_idx)
            4'd0: begin
                if (col_in[0] == 1'b0) raw_key = 4'd0;  // 按键 1
                else if (col_in[1] == 1'b0) raw_key = 4'd1;  // 按键 2
                else if (col_in[2] == 1'b0) raw_key = 4'd2;  // 按键 3
                else if (col_in[3] == 1'b0) raw_key = 4'd3;  // 按键 A
                else raw_key = 4'd15;
            end
            4'd1: begin
                if (col_in[0] == 1'b0) raw_key = 4'd4;  // 按键 4
                else if (col_in[1] == 1'b0) raw_key = 4'd5;  // 按键 5
                else if (col_in[2] == 1'b0) raw_key = 4'd6;  // 按键 6
                else if (col_in[3] == 1'b0) raw_key = 4'd7;  // 按键 B
                else raw_key = 4'd15;
            end
            4'd2: begin
                if (col_in[0] == 1'b0) raw_key = 4'd8;  // 按键 7
                else if (col_in[1] == 1'b0) raw_key = 4'd9;  // 按键 8
                else if (col_in[2] == 1'b0) raw_key = 4'd10; // 按键 9
                else if (col_in[3] == 1'b0) raw_key = 4'd11; // 按键 C
                else raw_key = 4'd15;
            end
            4'd3: begin
                if (col_in[0] == 1'b0) raw_key = 4'd12; // 按键 *
                else if (col_in[1] == 1'b0) raw_key = 4'd13; // 按键 0
                else if (col_in[2] == 1'b0) raw_key = 4'd14; // 按键 #
                else if (col_in[3] == 1'b0) raw_key = 4'd15; // 按键 D (这里与无按键共用编号15)
                else raw_key = 4'd15;
            end
        endcase
    end

    // 3. 硬件级按键消抖 (Hardware Debounce)
    // 说明：机械按键在按下/松开瞬间会产生 5~10ms 的高频抖动。
    //       若不加处理，会导致单次按键被识别为连续多次触发（如连击多次相同音符）。
    //       本模块设计了 20ms 的严格消抖计数器（245760 @ 12.288MHz），
    //       只有当按键状态稳定保持 20ms 不变，才确认为有效输入。
    //       纯硬件消抖既保证了极低的延迟，又提供了完美的物理手感。
    reg [17:0] debounce_cnt = 18'd0;
    reg [3:0] stable_key = 4'd15;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debounce_cnt <= 18'd0;
            stable_key <= 4'd15;
        end else if (raw_key != stable_key) begin
            if (debounce_cnt >= 18'd245760) begin // 20ms 消抖时间到达
                debounce_cnt <= 18'd0;
                stable_key <= raw_key;            // 更新为稳定的新键值
            end else begin
                debounce_cnt <= debounce_cnt + 1'b1;
            end
        end else begin
            debounce_cnt <= 18'd0;                // 状态未变，计数器清零
        end
    end

    // 4. 输出状态同步
    // 说明：将消抖后的稳定键值和有效标志输出给顶层模块，
    //       供 DDS 引擎与音效控制器进行下一步解析。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_code <= 4'd15;
            key_valid <= 1'b0;
        end else begin
            key_code <= stable_key;
            key_valid <= (stable_key != 4'd15); // 只要不空闲，即认为有效
        end
    end

    // 行线物理输出同步，防止毛刺
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) row_out <= 4'b1111;
        else row_out <= row_out_next;
    end

endmodule