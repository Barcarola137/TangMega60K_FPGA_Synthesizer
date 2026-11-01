// 模块名称：WS2812
// 项目名称：高云杯 选题二 - 基于FPGA的实时多音色合成电子乐器引擎
// 文件描述：WS2812 幻彩灯珠纯硬件驱动模块。
//           对应赛题拓展要求中的“基于FPGA硬件逻辑实时生成可视化反馈”。
//           本模块不使用任何软核或状态机软实现，完全通过计数器与移位寄存器
//           生成纳秒级的精确脉宽，实现音符到颜色的实时视听联动。

`timescale 1ns/1ns
module WS2812 #
(
	parameter clk_freq = 50_000_000,	// 驱动时钟频率 (默认 50MHz，周期 20ns)
	parameter fps = 60,               // 刷新率 (60帧/秒，保证视觉无闪烁)
	parameter used_led  = 1,          // 级联灯珠数量 (本系统使用 1 颗作为核心视觉反馈)
	parameter independent_led_ctrl = "true" // 独立控制模式
)(
	input sys_clk,
	input rst_n,
	output Do,
	/* LED Input Interface, Sync to sys_clk (数据输入，与系统时钟同步) */
	input  [7:0] pixel_addr,          // 像素地址 (多灯级联时使用)
	input  [7:0] pixel_Red,           // 红色分量
	input  [7:0] pixel_Green,         // 绿色分量
	input  [7:0] pixel_Blue,          // 蓝色分量
	input  pixel_valid,               // 数据有效标志
	output TE                         // Tearing Effect，用于防撕裂
);


	// 1. 颜色缓存与格式转换 (RGB -> GRB)

	// 注意：WS2812 的物理时序要求数据发送顺序为 G7-G0, R7-R0, B7-B0。
	// 所以这里在存入 memory 时，特意将输入的红绿蓝重新拼接为 {Green, Red, Blue}。
	reg [23:0] led_mem[used_led-1:0];
	reg [7:0] for_var;
	always@(posedge sys_clk or negedge rst_n)
	begin
		if(!rst_n)
		begin
			for(for_var=0; for_var<used_led; for_var=for_var+1)
			begin
				led_mem[for_var] <= 24'd0;
			end
		end else begin
			if(pixel_valid)
			begin
				if(independent_led_ctrl == "true")
				begin
					if(pixel_addr < used_led)
					begin
						led_mem[pixel_addr] <= {pixel_Green, pixel_Red, pixel_Blue};
					end
				end else begin
					for(for_var = 0; for_var < used_led; for_var = for_var+1)
					begin
						led_mem[for_var] <= {pixel_Green, pixel_Red, pixel_Blue};
					end
				end
			end
		end
	end


	// 2. 核心时序参数计算与物理层规范

	/*           WS2812 物理层通信协议 (纳秒级严格时序) 
	 *           1 Code (高电平长)                       0 Code (高电平短)
	 *	     __________		   _____			   ______			   _______
	 * _____|          |______|				______|		 |____________|
	 *      |<-------->|<---->|					  |<---->|<---------->|
	 *			 T1H      T0L						T0H			T0L
	 *			0.85us   0.4us						0.4us		0.85us
	 *
	 *   One code duration: T0H + T0L = 1.25us +- 600ns (单比特总时长 1.25us)
	 *   Reset Code: keep low for tReset(>50us) (帧间隔需拉低 >50us 表示复位)
	 */
	localparam cnt_H = clk_freq / 1_176_470; // 计算 0.85us 对应的时钟节拍数 (约 42.5 拍@50MHz)
	localparam cnt_L = clk_freq / 2_500_000; // 计算 0.4us 对应的时钟节拍数 (约 20 拍@50MHz)
	localparam cnt_dur = cnt_H + cnt_L;	 // 单比特完整周期 (1.25us 对应的节拍数)
	localparam cnt_1frame = clk_freq / fps;  // 一帧数据刷新周期的总节拍数

	reg [31:0] frame_cnt;       // 帧周期计数器
	reg ws2812_proging;         // 数据发送状态机标志位
	reg load_led;               // 载入颜色数据标志位

	reg [23:0] led_data;		// 临时颜色缓存
	reg [23:0] latch_led_data;	// 移位寄存器 (逐位输出给物理总线)
	reg [15:0] timing_cnt;		// 0/1 码的脉宽计时器
	reg [4:0]  led_bit_cnt;		// 当前发送到第几个 bit (0~23)
	reg [7:0] led_num_cnt;		// 当前发送到第几个灯珠

	reg tearing_effect;
	assign TE = tearing_effect;

	reg data_out;
	assign Do = data_out;


	// 3. 颜色数据载入与级联逻辑

	/* LED data Latch */
	always@(posedge sys_clk or negedge rst_n)
	begin
		if(!rst_n)
		begin
			led_data <= 24'd0;
		end else begin
			if(load_led)
			begin
				if(led_num_cnt >= used_led)
				begin
					led_data <= led_data;
				end else begin
					led_data <= led_mem[led_num_cnt];
				end
			end else begin
				led_data <= led_data;
			end
		end
	end


	// 4. 纯硬件状态机：逐帧、逐灯、逐比特状态流转

	always@(posedge sys_clk or negedge rst_n)
	begin
		if(!rst_n)
		begin
			frame_cnt <= 0;
			ws2812_proging <= 0;
			load_led <= 1;
			tearing_effect <= 0;

			timing_cnt <= 16'b0;
			led_bit_cnt <= 5'd0;
			led_num_cnt <= 8'd0;
			latch_led_data <= 24'd0;
		end else begin	
			// 帧率刷新控制
			if(frame_cnt >= cnt_1frame - 1)
			begin
				frame_cnt <= 0;
			end else begin
				frame_cnt <= frame_cnt + 1;
			end

			/* 预加载灯珠颜色数据 */
			if(frame_cnt >= cnt_1frame - 1)
			begin
				load_led <= 1;
			end else begin
				if(led_bit_cnt == 5'd22 && timing_cnt == cnt_dur)
				begin
					load_led <= 1;
				end else begin
					load_led <= 0;
				end
			end
			
			// 发送状态机
			if(ws2812_proging)	
			begin
				/* 当前 Bit 发送完毕 */
				if(timing_cnt == cnt_dur)	// 1bit 周期结束
				begin
					timing_cnt <= 0;	// 重置脉宽计时器

					/* 当前 LED 的 24bit 发送完毕 */
					if(led_bit_cnt == 5'd23)
					begin
						led_bit_cnt <= 5'd0;
						/* 所有灯珠数据发送完成，拉低总线生成 >50us 复位信号 */
						if(led_num_cnt == used_led - 1)	
						begin
							tearing_effect <= 1;
							latch_led_data <= 0;
							led_num_cnt <= 0;
							ws2812_proging <= 0;	// 回到空闲状态
						end else begin
							tearing_effect <= 0;
							latch_led_data <= led_data; // 级联下一个灯珠
							led_num_cnt <= led_num_cnt + 1'b1;
							ws2812_proging <= 1;
						end
					end else begin
						led_bit_cnt <= led_bit_cnt + 1'b1;
						// 移位寄存器左移，准备发送下一位 (高位先出)
						latch_led_data <= {latch_led_data[22:0], 1'b0};
						tearing_effect <= 0;
						led_num_cnt <= led_num_cnt;
						ws2812_proging <= 1;
					end

				end else begin
					timing_cnt <= timing_cnt + 1;
					led_bit_cnt <= led_bit_cnt;
					load_led <= 0;
					latch_led_data <= latch_led_data;
					tearing_effect <= 0;
					led_num_cnt <= led_num_cnt;
					ws2812_proging <= 1;
				end

			end else begin	// 等待新一轮数据写入
				if(frame_cnt == 0)
				begin
					timing_cnt <= 0;
					led_bit_cnt <= 0;
					load_led <= 0;
					latch_led_data <= led_data;
					tearing_effect <= 0;
					led_num_cnt <= 0;
					ws2812_proging <= 1;
				end else begin
					timing_cnt <= 0;
					led_bit_cnt <= 0;
					load_led <= 0;
					latch_led_data <= 0;
					tearing_effect <= 0;
					led_num_cnt <= 0;
					ws2812_proging <= 0;
				end
			end
		end
	end
	

	// 5. 物理层输出 (0 Code 与 1 Code 的占空比生成)

	/* Data shift */
	always@(posedge sys_clk or negedge rst_n)
	begin
		if(!rst_n)
		begin
			data_out <= 1'b0;
		end else begin
			if(ws2812_proging)
			begin
				// 判断当前最高位：1 则输出长高电平(0.85us)，0 则输出短高电平(0.4us)
				if(latch_led_data[23] == 1'b1)
				begin
					if(timing_cnt < cnt_H - 1)
					begin
						data_out <= 1'b1; // T1H (长高电平)
					end else begin
						data_out <= 1'b0; // T1L (短低电平)
					end
				end else begin
					if(timing_cnt < cnt_L - 1)
					begin
						data_out <= 1'b1; // T0H (短高电平)
					end else begin
						data_out <= 1'b0; // T0L (长低电平)
					end
				end
			end else begin
				data_out <= 1'b0; // 空闲时保持低电平，生成 >50us 的 Reset 信号
			end
		end
	end

endmodule