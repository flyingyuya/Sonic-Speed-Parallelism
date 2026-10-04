//=============================================================================
// font_rom.v - 点阵字库 ROM（**由脚本生成，不要手改**）
//-----------------------------------------------------------------------------
// 生成脚本： scripts/golden/gen_font.py
//   重新生成： python3 scripts/golden/gen_font.py
//
// 规格： 5x7 点阵，占 8 行/字符（第 7 行留空当行距）
//   每个字符 8 个字节，每字节 bit4..bit0 = 该行从左到右的 5 个像素
//   （bit4 是最左）。行 0 在最上面。
//
//   取字： idx = char_code * 8 + row
//          bit = rom[idx] >> (4 - col) & 1      col ∈ 0..4
//
// 收录字符：   % - . / 0 1 2 3 4 5 6 7 8 9 : = A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
// 未收录的字符在渲染侧一律当空格处理。
//=============================================================================
`timescale 1ns/1ps

module font_rom #(
    parameter integer NCH = 91,      // 收录的字符数（按 ASCII 码直接寻址）
    parameter integer GW  = 5,      // 字形宽
    parameter integer GH  = 7       // 字形高（不含留空的行距行）
) (
    // 组合读取：扫描到哪个像素就查哪一位，不引入流水线
    input  wire [7:0]      ch,       // ASCII 码
    input  wire [2:0]      row,      // 第几行（0..7）
    output reg  [7:0]      bits      // bit4..bit0 = 该行的 5 个像素
);

    // ROM 内容：每个 ASCII 码 8 个字节
    reg [7:0] rom [0:NCH*8-1];

    integer i;
    initial begin
        for (i = 0; i < NCH*8; i = i + 1) rom[i] = 8'h00;   // 未收录 = 空格
        // '%' (0x25)
        rom[ 296] = 8'h19;   // row 0
        rom[ 297] = 8'h19;   // row 1
        rom[ 298] = 8'h02;   // row 2
        rom[ 299] = 8'h04;   // row 3
        rom[ 300] = 8'h08;   // row 4
        rom[ 301] = 8'h13;   // row 5
        rom[ 302] = 8'h13;   // row 6
        // '-' (0x2D)
        rom[ 360] = 8'h00;   // row 0
        rom[ 361] = 8'h00;   // row 1
        rom[ 362] = 8'h00;   // row 2
        rom[ 363] = 8'h1F;   // row 3
        rom[ 364] = 8'h00;   // row 4
        rom[ 365] = 8'h00;   // row 5
        rom[ 366] = 8'h00;   // row 6
        // '.' (0x2E)
        rom[ 368] = 8'h00;   // row 0
        rom[ 369] = 8'h00;   // row 1
        rom[ 370] = 8'h00;   // row 2
        rom[ 371] = 8'h00;   // row 3
        rom[ 372] = 8'h00;   // row 4
        rom[ 373] = 8'h0C;   // row 5
        rom[ 374] = 8'h0C;   // row 6
        // '/' (0x2F)
        rom[ 376] = 8'h01;   // row 0
        rom[ 377] = 8'h01;   // row 1
        rom[ 378] = 8'h02;   // row 2
        rom[ 379] = 8'h04;   // row 3
        rom[ 380] = 8'h08;   // row 4
        rom[ 381] = 8'h10;   // row 5
        rom[ 382] = 8'h10;   // row 6
        // '0' (0x30)
        rom[ 384] = 8'h0E;   // row 0
        rom[ 385] = 8'h11;   // row 1
        rom[ 386] = 8'h13;   // row 2
        rom[ 387] = 8'h15;   // row 3
        rom[ 388] = 8'h19;   // row 4
        rom[ 389] = 8'h11;   // row 5
        rom[ 390] = 8'h0E;   // row 6
        // '1' (0x31)
        rom[ 392] = 8'h04;   // row 0
        rom[ 393] = 8'h0C;   // row 1
        rom[ 394] = 8'h04;   // row 2
        rom[ 395] = 8'h04;   // row 3
        rom[ 396] = 8'h04;   // row 4
        rom[ 397] = 8'h04;   // row 5
        rom[ 398] = 8'h0E;   // row 6
        // '2' (0x32)
        rom[ 400] = 8'h0E;   // row 0
        rom[ 401] = 8'h11;   // row 1
        rom[ 402] = 8'h01;   // row 2
        rom[ 403] = 8'h02;   // row 3
        rom[ 404] = 8'h04;   // row 4
        rom[ 405] = 8'h08;   // row 5
        rom[ 406] = 8'h1F;   // row 6
        // '3' (0x33)
        rom[ 408] = 8'h1F;   // row 0
        rom[ 409] = 8'h02;   // row 1
        rom[ 410] = 8'h04;   // row 2
        rom[ 411] = 8'h02;   // row 3
        rom[ 412] = 8'h01;   // row 4
        rom[ 413] = 8'h11;   // row 5
        rom[ 414] = 8'h0E;   // row 6
        // '4' (0x34)
        rom[ 416] = 8'h02;   // row 0
        rom[ 417] = 8'h06;   // row 1
        rom[ 418] = 8'h0A;   // row 2
        rom[ 419] = 8'h12;   // row 3
        rom[ 420] = 8'h1F;   // row 4
        rom[ 421] = 8'h02;   // row 5
        rom[ 422] = 8'h02;   // row 6
        // '5' (0x35)
        rom[ 424] = 8'h1F;   // row 0
        rom[ 425] = 8'h10;   // row 1
        rom[ 426] = 8'h1E;   // row 2
        rom[ 427] = 8'h01;   // row 3
        rom[ 428] = 8'h01;   // row 4
        rom[ 429] = 8'h11;   // row 5
        rom[ 430] = 8'h0E;   // row 6
        // '6' (0x36)
        rom[ 432] = 8'h06;   // row 0
        rom[ 433] = 8'h08;   // row 1
        rom[ 434] = 8'h10;   // row 2
        rom[ 435] = 8'h1E;   // row 3
        rom[ 436] = 8'h11;   // row 4
        rom[ 437] = 8'h11;   // row 5
        rom[ 438] = 8'h0E;   // row 6
        // '7' (0x37)
        rom[ 440] = 8'h1F;   // row 0
        rom[ 441] = 8'h01;   // row 1
        rom[ 442] = 8'h02;   // row 2
        rom[ 443] = 8'h04;   // row 3
        rom[ 444] = 8'h08;   // row 4
        rom[ 445] = 8'h08;   // row 5
        rom[ 446] = 8'h08;   // row 6
        // '8' (0x38)
        rom[ 448] = 8'h0E;   // row 0
        rom[ 449] = 8'h11;   // row 1
        rom[ 450] = 8'h11;   // row 2
        rom[ 451] = 8'h0E;   // row 3
        rom[ 452] = 8'h11;   // row 4
        rom[ 453] = 8'h11;   // row 5
        rom[ 454] = 8'h0E;   // row 6
        // '9' (0x39)
        rom[ 456] = 8'h0E;   // row 0
        rom[ 457] = 8'h11;   // row 1
        rom[ 458] = 8'h11;   // row 2
        rom[ 459] = 8'h0F;   // row 3
        rom[ 460] = 8'h01;   // row 4
        rom[ 461] = 8'h02;   // row 5
        rom[ 462] = 8'h0C;   // row 6
        // ':' (0x3A)
        rom[ 464] = 8'h00;   // row 0
        rom[ 465] = 8'h0C;   // row 1
        rom[ 466] = 8'h0C;   // row 2
        rom[ 467] = 8'h00;   // row 3
        rom[ 468] = 8'h0C;   // row 4
        rom[ 469] = 8'h0C;   // row 5
        rom[ 470] = 8'h00;   // row 6
        // '=' (0x3D)
        rom[ 488] = 8'h00;   // row 0
        rom[ 489] = 8'h00;   // row 1
        rom[ 490] = 8'h1F;   // row 2
        rom[ 491] = 8'h00;   // row 3
        rom[ 492] = 8'h1F;   // row 4
        rom[ 493] = 8'h00;   // row 5
        rom[ 494] = 8'h00;   // row 6
        // 'A' (0x41)
        rom[ 520] = 8'h0E;   // row 0
        rom[ 521] = 8'h11;   // row 1
        rom[ 522] = 8'h11;   // row 2
        rom[ 523] = 8'h1F;   // row 3
        rom[ 524] = 8'h11;   // row 4
        rom[ 525] = 8'h11;   // row 5
        rom[ 526] = 8'h11;   // row 6
        // 'B' (0x42)
        rom[ 528] = 8'h1E;   // row 0
        rom[ 529] = 8'h11;   // row 1
        rom[ 530] = 8'h11;   // row 2
        rom[ 531] = 8'h1E;   // row 3
        rom[ 532] = 8'h11;   // row 4
        rom[ 533] = 8'h11;   // row 5
        rom[ 534] = 8'h1E;   // row 6
        // 'C' (0x43)
        rom[ 536] = 8'h0E;   // row 0
        rom[ 537] = 8'h11;   // row 1
        rom[ 538] = 8'h10;   // row 2
        rom[ 539] = 8'h10;   // row 3
        rom[ 540] = 8'h10;   // row 4
        rom[ 541] = 8'h11;   // row 5
        rom[ 542] = 8'h0E;   // row 6
        // 'D' (0x44)
        rom[ 544] = 8'h1C;   // row 0
        rom[ 545] = 8'h12;   // row 1
        rom[ 546] = 8'h11;   // row 2
        rom[ 547] = 8'h11;   // row 3
        rom[ 548] = 8'h11;   // row 4
        rom[ 549] = 8'h12;   // row 5
        rom[ 550] = 8'h1C;   // row 6
        // 'E' (0x45)
        rom[ 552] = 8'h1F;   // row 0
        rom[ 553] = 8'h10;   // row 1
        rom[ 554] = 8'h10;   // row 2
        rom[ 555] = 8'h1E;   // row 3
        rom[ 556] = 8'h10;   // row 4
        rom[ 557] = 8'h10;   // row 5
        rom[ 558] = 8'h1F;   // row 6
        // 'F' (0x46)
        rom[ 560] = 8'h1F;   // row 0
        rom[ 561] = 8'h10;   // row 1
        rom[ 562] = 8'h10;   // row 2
        rom[ 563] = 8'h1E;   // row 3
        rom[ 564] = 8'h10;   // row 4
        rom[ 565] = 8'h10;   // row 5
        rom[ 566] = 8'h10;   // row 6
        // 'G' (0x47)
        rom[ 568] = 8'h0E;   // row 0
        rom[ 569] = 8'h11;   // row 1
        rom[ 570] = 8'h10;   // row 2
        rom[ 571] = 8'h17;   // row 3
        rom[ 572] = 8'h11;   // row 4
        rom[ 573] = 8'h11;   // row 5
        rom[ 574] = 8'h0F;   // row 6
        // 'H' (0x48)
        rom[ 576] = 8'h11;   // row 0
        rom[ 577] = 8'h11;   // row 1
        rom[ 578] = 8'h11;   // row 2
        rom[ 579] = 8'h1F;   // row 3
        rom[ 580] = 8'h11;   // row 4
        rom[ 581] = 8'h11;   // row 5
        rom[ 582] = 8'h11;   // row 6
        // 'I' (0x49)
        rom[ 584] = 8'h0E;   // row 0
        rom[ 585] = 8'h04;   // row 1
        rom[ 586] = 8'h04;   // row 2
        rom[ 587] = 8'h04;   // row 3
        rom[ 588] = 8'h04;   // row 4
        rom[ 589] = 8'h04;   // row 5
        rom[ 590] = 8'h0E;   // row 6
        // 'J' (0x4A)
        rom[ 592] = 8'h01;   // row 0
        rom[ 593] = 8'h01;   // row 1
        rom[ 594] = 8'h01;   // row 2
        rom[ 595] = 8'h01;   // row 3
        rom[ 596] = 8'h11;   // row 4
        rom[ 597] = 8'h11;   // row 5
        rom[ 598] = 8'h0E;   // row 6
        // 'K' (0x4B)
        rom[ 600] = 8'h11;   // row 0
        rom[ 601] = 8'h12;   // row 1
        rom[ 602] = 8'h14;   // row 2
        rom[ 603] = 8'h18;   // row 3
        rom[ 604] = 8'h14;   // row 4
        rom[ 605] = 8'h12;   // row 5
        rom[ 606] = 8'h11;   // row 6
        // 'L' (0x4C)
        rom[ 608] = 8'h10;   // row 0
        rom[ 609] = 8'h10;   // row 1
        rom[ 610] = 8'h10;   // row 2
        rom[ 611] = 8'h10;   // row 3
        rom[ 612] = 8'h10;   // row 4
        rom[ 613] = 8'h10;   // row 5
        rom[ 614] = 8'h1F;   // row 6
        // 'M' (0x4D)
        rom[ 616] = 8'h11;   // row 0
        rom[ 617] = 8'h1B;   // row 1
        rom[ 618] = 8'h15;   // row 2
        rom[ 619] = 8'h11;   // row 3
        rom[ 620] = 8'h11;   // row 4
        rom[ 621] = 8'h11;   // row 5
        rom[ 622] = 8'h11;   // row 6
        // 'N' (0x4E)
        rom[ 624] = 8'h11;   // row 0
        rom[ 625] = 8'h19;   // row 1
        rom[ 626] = 8'h15;   // row 2
        rom[ 627] = 8'h13;   // row 3
        rom[ 628] = 8'h11;   // row 4
        rom[ 629] = 8'h11;   // row 5
        rom[ 630] = 8'h11;   // row 6
        // 'O' (0x4F)
        rom[ 632] = 8'h0E;   // row 0
        rom[ 633] = 8'h11;   // row 1
        rom[ 634] = 8'h11;   // row 2
        rom[ 635] = 8'h11;   // row 3
        rom[ 636] = 8'h11;   // row 4
        rom[ 637] = 8'h11;   // row 5
        rom[ 638] = 8'h0E;   // row 6
        // 'P' (0x50)
        rom[ 640] = 8'h1E;   // row 0
        rom[ 641] = 8'h11;   // row 1
        rom[ 642] = 8'h11;   // row 2
        rom[ 643] = 8'h1E;   // row 3
        rom[ 644] = 8'h10;   // row 4
        rom[ 645] = 8'h10;   // row 5
        rom[ 646] = 8'h10;   // row 6
        // 'Q' (0x51)
        rom[ 648] = 8'h0E;   // row 0
        rom[ 649] = 8'h11;   // row 1
        rom[ 650] = 8'h11;   // row 2
        rom[ 651] = 8'h11;   // row 3
        rom[ 652] = 8'h15;   // row 4
        rom[ 653] = 8'h12;   // row 5
        rom[ 654] = 8'h0D;   // row 6
        // 'R' (0x52)
        rom[ 656] = 8'h1E;   // row 0
        rom[ 657] = 8'h11;   // row 1
        rom[ 658] = 8'h11;   // row 2
        rom[ 659] = 8'h1E;   // row 3
        rom[ 660] = 8'h14;   // row 4
        rom[ 661] = 8'h12;   // row 5
        rom[ 662] = 8'h11;   // row 6
        // 'S' (0x53)
        rom[ 664] = 8'h0F;   // row 0
        rom[ 665] = 8'h10;   // row 1
        rom[ 666] = 8'h10;   // row 2
        rom[ 667] = 8'h0E;   // row 3
        rom[ 668] = 8'h01;   // row 4
        rom[ 669] = 8'h01;   // row 5
        rom[ 670] = 8'h1E;   // row 6
        // 'T' (0x54)
        rom[ 672] = 8'h1F;   // row 0
        rom[ 673] = 8'h04;   // row 1
        rom[ 674] = 8'h04;   // row 2
        rom[ 675] = 8'h04;   // row 3
        rom[ 676] = 8'h04;   // row 4
        rom[ 677] = 8'h04;   // row 5
        rom[ 678] = 8'h04;   // row 6
        // 'U' (0x55)
        rom[ 680] = 8'h11;   // row 0
        rom[ 681] = 8'h11;   // row 1
        rom[ 682] = 8'h11;   // row 2
        rom[ 683] = 8'h11;   // row 3
        rom[ 684] = 8'h11;   // row 4
        rom[ 685] = 8'h11;   // row 5
        rom[ 686] = 8'h0E;   // row 6
        // 'V' (0x56)
        rom[ 688] = 8'h11;   // row 0
        rom[ 689] = 8'h11;   // row 1
        rom[ 690] = 8'h11;   // row 2
        rom[ 691] = 8'h11;   // row 3
        rom[ 692] = 8'h11;   // row 4
        rom[ 693] = 8'h0A;   // row 5
        rom[ 694] = 8'h04;   // row 6
        // 'W' (0x57)
        rom[ 696] = 8'h11;   // row 0
        rom[ 697] = 8'h11;   // row 1
        rom[ 698] = 8'h11;   // row 2
        rom[ 699] = 8'h11;   // row 3
        rom[ 700] = 8'h15;   // row 4
        rom[ 701] = 8'h1B;   // row 5
        rom[ 702] = 8'h11;   // row 6
        // 'X' (0x58)
        rom[ 704] = 8'h11;   // row 0
        rom[ 705] = 8'h11;   // row 1
        rom[ 706] = 8'h0A;   // row 2
        rom[ 707] = 8'h04;   // row 3
        rom[ 708] = 8'h0A;   // row 4
        rom[ 709] = 8'h11;   // row 5
        rom[ 710] = 8'h11;   // row 6
        // 'Y' (0x59)
        rom[ 712] = 8'h11;   // row 0
        rom[ 713] = 8'h11;   // row 1
        rom[ 714] = 8'h0A;   // row 2
        rom[ 715] = 8'h04;   // row 3
        rom[ 716] = 8'h04;   // row 4
        rom[ 717] = 8'h04;   // row 5
        rom[ 718] = 8'h04;   // row 6
        // 'Z' (0x5A)
        rom[ 720] = 8'h1F;   // row 0
        rom[ 721] = 8'h01;   // row 1
        rom[ 722] = 8'h02;   // row 2
        rom[ 723] = 8'h04;   // row 3
        rom[ 724] = 8'h08;   // row 4
        rom[ 725] = 8'h10;   // row 5
        rom[ 726] = 8'h1F;   // row 6
    end

    always @(ch or row) begin
        // 越界（比如控制字符或超出收录范围）一律返回空格，不会读出 X
        if (ch > NCH - 1)
            bits = 8'h00;
        else
            bits = rom[ch*8 + row];
    end

endmodule
