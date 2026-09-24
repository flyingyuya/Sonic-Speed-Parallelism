//=============================================================================
// tb_eq_cascade.v - 均衡器 RTL 与 Python 定点黄金模型逐位对拍
//-----------------------------------------------------------------------------
// 流程：
//   1. 从 sim/vectors/ 读入系数 / 输入 / 黄金输出
//   2. 通过 coe_we 端口逐条写入 25 个系数
//   3. 按 48kHz 节拍灌入 6000 个样本，收集 RTL 输出
//   4. 与黄金输出逐位比较，同时把 RTL 输出写文件供 Python 二次核对
//
// 运行： bash scripts/sim/run_iv.sh      （工作目录必须是仓库根目录）
//=============================================================================
`timescale 1ns/1ps

module tb_eq_cascade;

    localparam integer DW    = 24;
    localparam integer CW    = 18;
    localparam integer CF    = 16;
    localparam integer AW    = 48;
    localparam integer NSECT = 5;
    localparam integer NCOE  = NSECT * 5;
    localparam integer NSAMP = 6000;

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    reg                    rst_n = 1'b0;
    reg                    coe_we = 1'b0;
    reg  [4:0]             coe_addr = 5'd0;
    reg  signed [CW-1:0]   coe_wdata = {CW{1'b0}};
    reg                    bypass = 1'b0;
    reg  signed [DW-1:0]   x_in = {DW{1'b0}};
    reg                    x_valid = 1'b0;
    wire                   x_ready;
    wire signed [DW-1:0]   y_out;
    wire                   y_valid;

    eq_cascade #(
        .DW(DW), .CW(CW), .CF(CF), .AW(AW), .NSECT(NSECT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .coe_we(coe_we), .coe_addr(coe_addr), .coe_wdata(coe_wdata),
        .bypass(bypass),
        .x_in(x_in), .x_valid(x_valid), .x_ready(x_ready),
        .y_out(y_out), .y_valid(y_valid)
    );

    reg signed [CW-1:0] coe [0:NCOE-1];
    reg signed [DW-1:0] xv  [0:NSAMP-1];
    reg signed [DW-1:0] yv  [0:NSAMP-1];

    integer errors   = 0;
    integer n_out    = 0;
    integer i;
    integer fd;
    integer first_err = -1;

    reg signed [DW-1:0] ycap [0:NSAMP-1];   // RTL 实际输出，导出供 Python 核对

    //-------------------------------------------------------------------------
    // 输出收集 + 比较
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && y_valid) begin
            if (n_out < NSAMP) begin
                ycap[n_out] = y_out;
                if (y_out !== yv[n_out]) begin
                    errors = errors + 1;
                    if (first_err < 0) begin
                        first_err = n_out;
                        $display("  [错] #%0d  RTL=%0d  黄金=%0d  差=%0d",
                                 n_out, $signed(y_out), $signed(yv[n_out]),
                                 $signed(y_out) - $signed(yv[n_out]));
                    end
                end
            end
            n_out = n_out + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        // VCD 波形默认关闭（6000 样本的波形有几百 MB），
        // 需要看波形时用：WAVE=1 bash scripts/sim/run_iv.sh eq_cascade
        if (!$test$plusargs("novcd")) begin
            $dumpfile("sim/build/tb_eq_cascade.vcd");
            $dumpvars(1, tb_eq_cascade);
        end

        $readmemh("sim/vectors/eq_coeff.hex", coe);
        $readmemh("sim/vectors/eq_in.hex",    xv);
        $readmemh("sim/vectors/eq_out.hex",   yv);

        $display("=========================================================");
        $display(" eq_cascade  RTL vs Python 定点黄金模型 逐位对拍");
        $display(" 样本数=%0d  段数=%0d  数据 Q1.%0d  系数 Q2.%0d",
                 NSAMP, NSECT, DW-1, CF);
        $display("=========================================================");

        // 复位
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // 写入 25 个系数
        for (i = 0; i < NCOE; i = i + 1) begin
            @(posedge clk);
            coe_we    <= 1'b1;
            coe_addr  <= i[4:0];
            coe_wdata <= coe[i];
        end
        @(posedge clk);
        coe_we <= 1'b0;

        // 按 48kHz 节拍灌样本（每样本间隔 20 个 clk，远大于 DUT 的 6 周期）
        for (i = 0; i < NSAMP; i = i + 1) begin
            @(posedge clk);
            while (!x_ready) @(posedge clk);
            x_in    <= xv[i];
            x_valid <= 1'b1;
            @(posedge clk);
            x_valid <= 1'b0;
            repeat (20) @(posedge clk);
        end

        // 等待流水线排空
        repeat (40) @(posedge clk);

        // 导出 RTL 实际输出，供 Python 侧再次核对
        fd = $fopen("sim/build/eq_out_rtl.hex", "w");
        for (i = 0; i < n_out && i < NSAMP; i = i + 1)
            $fdisplay(fd, "%06x", ycap[i]);
        $fclose(fd);

        $display("---------------------------------------------------------");
        $display(" 输出样本数 : %0d / %0d", n_out, NSAMP);
        $display(" 逐位不符数 : %0d", errors);
        if (errors == 0 && n_out == NSAMP)
            $display(" 结果       : *** PASS ***  RTL 与黄金模型完全一致");
        else
            $display(" 结果       : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

endmodule
