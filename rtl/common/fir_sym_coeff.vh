//=============================================================================
// fir_sym_coeff.vh - 波形平滑 FIR 的系数（**自动生成，不要手改**）
//-----------------------------------------------------------------------------
//   由 scripts/golden/gen_wave_fir.py 生成。
//   改抽头数 / 截止频率 -> 改脚本里的 CHOSEN_N / CHOSEN_FC，然后重新 --emit。
//
//   设计：15 抽头、**线性相位（系数对称）**、Hamming 窗加窗 sinc 低通
//         截止 0.120*fs = 5760 Hz @48kHz
//   格式：Q2.16（18 位有符号），和 EQ 用同一套格式
//   系数和 = 65537（理想 65536）-> 直流增益误差 +0.00013 dB，可忽略
//
//   ⚠️ 只存了【前一半 + 中心】，共 8 个。对称 FIR 的后一半是镜像，
//      不必存 —— 这是省一半 ROM 和一半乘法器的关键。
//=============================================================================

    localparam integer FIR_N    = 15;      // 抽头数（奇数）
    localparam integer FIR_M    = 7;      // (N-1)/2，配对个数
    localparam integer FIR_CW   = 18;     // 系数位宽

    // 系数查询。idx 在展开的循环里都是常数 -> 综合器直接折叠掉，不占资源。
    function signed [FIR_CW-1:0] fir_coef;
        input [3:0] idx;
        begin
            case (idx)
            4'd0: fir_coef = -18'sd202;
            4'd1: fir_coef = -18'sd431;
            4'd2: fir_coef = -18'sd625;
            4'd3: fir_coef = 18'sd288;
            4'd4: fir_coef = 18'sd3462;
            4'd5: fir_coef = 18'sd8657;
            4'd6: fir_coef = 18'sd13709;
            4'd7: fir_coef = 18'sd15821;
                default: fir_coef = 18'sd0;
            endcase
        end
    endfunction
