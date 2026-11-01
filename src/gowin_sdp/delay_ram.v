//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.12.04 (64-bit)
//IP Version: 1.0
//Part Number: GW5AT-LV60PG484AC1/I0
//Device: GW5AT-60
//Device Version: B
//Created Time: Sun Oct 25 19:20:11 2026

module delay_ram (dout, clka, cea, clkb, ceb, oce, reset, ada, din, adb);

output [15:0] dout;
input clka;
input cea;
input clkb;
input ceb;
input oce;
input reset;
input [3:0] ada;
input [15:0] din;
input [3:0] adb;

wire [15:0] sdpb_inst_0_dout_w;
wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;

SDPB sdpb_inst_0 (
    .DO({sdpb_inst_0_dout_w[15:0],dout[15:0]}),
    .CLKA(clka),
    .CEA(cea),
    .CLKB(clkb),
    .CEB(ceb),
    .OCE(oce),
    .RESET(reset),
    .BLKSELA({gw_gnd,gw_gnd,gw_gnd}),
    .BLKSELB({gw_gnd,gw_gnd,gw_gnd}),
    .ADA({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,ada[3:0],gw_gnd,gw_gnd,gw_vcc,gw_vcc}),
    .DI({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,din[15:0]}),
    .ADB({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,adb[3:0],gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

defparam sdpb_inst_0.READ_MODE = 1'b0;
defparam sdpb_inst_0.BIT_WIDTH_0 = 16;
defparam sdpb_inst_0.BIT_WIDTH_1 = 16;
defparam sdpb_inst_0.BLK_SEL_0 = 3'b000;
defparam sdpb_inst_0.BLK_SEL_1 = 3'b000;
defparam sdpb_inst_0.RESET_MODE = "SYNC";

endmodule //delay_ram
