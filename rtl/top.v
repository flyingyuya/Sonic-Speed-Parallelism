`timescale 1ns/1ps

module top (
    input  wire clk_200m_p,     // R4, 200MHz 差分 P
    input  wire clk_200m_n,     // T4, 200MHz 差分 N
    input  wire rst_btn_n,      // R14, 复位按键，低有效

    output wire [1:0] led       // led[0]→W22, led[1]→Y22，高点亮
);

    wire clk_sys;       // 48 MHz
    wire clk_pix;       // 12.5 MHz
    wire mmcm_locked;   // 锁相指示
    wire rst_async_n;   // 锁相的异步复位
    wire rst_n_sys;     // 同步释放的异步复位(sys 时钟域)
    // wire rst_n_pix;     // 同步释放的异步复位(pix 时钟域)

    clk_gen clk_gen_u (
        //input
        .clk_200m_p     (clk_200m_p ),
        .clk_200m_n     (clk_200m_n ),
        .rst_btn_n      (rst_btn_n  ),
        // output
        .clk_sys        (clk_sys    ),
        .clk_pix        (clk_pix    ),
        .mmcm_locked    (mmcm_locked)
    );

    assign rst_async_n = rst_btn_n & mmcm_locked;

    rst_sync u_rst_sys (
        .clk            (clk_sys    ),
        .rst_async_n    (rst_async_n),

        .rst_n          (rst_n_sys  )
    );

    // rst_sync u_rst_pix (
    //     .clk            (clk_pix    ),
    //     .rst_async_n    (rst_async_n),
    //
    //     .rst_n          (rst_n_pix  )
    // );

    localparam [24:0] CNT_MAX = 25'd24_000_000;// 500ms 计数值
    reg [24:0] cnt;
    reg led_reg;
    always@(posedge clk_sys) begin
        if (!rst_n_sys) begin
            cnt <= 'd0;
        end
        else begin
            if (cnt < CNT_MAX-1) begin
                cnt <= cnt + 1'd1;
            end
            else begin
                cnt <= 'd0;
            end
        end
    end

    always@(posedge clk_sys) begin
        if (!rst_n_sys) begin
            led_reg <= 1'd0;
        end
        else begin
            if (cnt == CNT_MAX-1) begin
                led_reg <= ~led_reg;
            end
            else begin
                led_reg <= led_reg;
            end
        end
    end

    assign led[0] = led_reg;
    assign led[1] = mmcm_locked;

endmodule
