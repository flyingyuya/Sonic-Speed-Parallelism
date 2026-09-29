#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
uart_term.py - 本工程的 UART 命令通道终端 / 自检工具

上位机 <-> FPGA 的协议（见 rtl/control/cmd_proc.v）：

    命令：<字母><两位hex>     字母不区分大小写，敲完第二位【立刻执行】，不用回车
          V  <2位hex>   视图使能位图（bit0=柱状 bit1=极坐标 bit2=波形，默认 0x07）
          S  <2位hex>   柱体风格
          H  <2位hex>   色相滚动速度（每 2^H 帧滚一级）
          G  <2位hex>   波形增益
          B  <2位hex>   背景模式（实际只用低 4 位）
          A  <2位hex>   自动轮换视图（bit0=1 开启）
          ?             回读当前配置

    回应：20 字节，固定格式，以 CRLF 结尾
          "V07 S00 H02 G03 B0\r\n"
           ^^^ ^^^ ^^^ ^^^ ^^
           |   |   |   |   └─ B 只有【一位】hex（代码里是 cfg_bg_mode[3:0]）
           |   |   |   └───── G
           |   |   └───────── H
           |   └───────────── S
           └───────────────── V

    ⚠️ 写命令【不回显】。改完参数要主动发 '?' 才能看到新值。

用法：
    # 交互模式（默认）：直接打字，回车发送；Ctrl-C 退出
    ./scripts/uart_term.py

    # 跑一遍协议自检
    ./scripts/uart_term.py --test

    # 依次发几条命令并打印回应
    ./scripts/uart_term.py -c '?' -c V02 -c '?' -c A01

    # 指定设备/波特率
    ./scripts/uart_term.py -p /dev/ttyUSB0 -b 115200
"""

import argparse
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("缺少 pyserial。Arch 上装： sudo pacman -S python-pyserial")


FRAME_LEN = 20          # 固定 20 字节（18 字符 + CRLF）
CRLF = b"\r\n"


def open_port(port, baud):
    """打开串口，出错时给出可操作的提示。"""
    try:
        return serial.Serial(port, baud, timeout=0.2)
    except (PermissionError, serial.SerialException) as e:
        msg = str(e)
        if isinstance(e, PermissionError) or "Permission denied" in msg:
            print(f"❌ 没有权限打开 {port}", file=sys.stderr)
            print("   设备属主是 root:uucp，两种解法：", file=sys.stderr)
            print("     永久： sudo usermod -aG uucp $USER   然后【重新登录】", file=sys.stderr)
            print(f"     临时： sudo chmod 666 {port}", file=sys.stderr)
        else:
            print(f"❌ 打不开 {port}: {e}", file=sys.stderr)
        avail = [p.device for p in list_ports.comports()
                 if p.device.startswith(("/dev/ttyUSB", "/dev/ttyACM"))]
        if avail:
            print(f"   当前可用的 USB 串口：{', '.join(avail)}", file=sys.stderr)
        else:
            print("   没检测到 USB 串口 —— 板子插了吗？（/dev/ttyS* 是主板自带的，没用）",
                  file=sys.stderr)
        sys.exit(1)


def read_frame(ser, timeout=1.0):
    """读一整帧（20 字节，以 CRLF 结尾）。超时返回 None。"""
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < timeout:
        chunk = ser.read(1)
        if not chunk:
            continue
        buf += chunk
        if buf.endswith(CRLF):
            return bytes(buf)
        if len(buf) > 128:              # 明显不是我们的帧，丢掉重来
            buf.clear()
    return None


def query(ser, timeout=1.0):
    """发 '?' 并读回一帧，返回解析出的 dict（失败返回 None）。"""
    ser.reset_input_buffer()
    ser.write(b"?")
    ser.flush()
    frame = read_frame(ser, timeout)
    if frame is None:
        return None
    text = frame.decode("ascii", "replace").strip()
    out = {"raw": text}
    for tok in text.split():
        if len(tok) >= 2:
            out[tok[0].upper()] = tok[1:]
    return out


def send(ser, cmd, wait=0.05):
    ser.write(cmd.encode())
    ser.flush()
    time.sleep(wait)


def show(cfg, label=""):
    if cfg is None:
        print(f"  {label}❌ 没收到回应（超时）")
        return False
    print(f"  {label}{cfg['raw']}")
    return True


# ---------------------------------------------------------------------------
# 自检：跑一遍协议，逐项判定
# ---------------------------------------------------------------------------
def run_test(ser):
    print("=" * 60)
    print(" UART 协议自检")
    print("=" * 60)

    ok = 0
    fail = 0

    def check(name, cond, extra=""):
        """⚠️ 每一次判定都必须过这里 —— 不能把 check 藏进 if 里。

        以前这里犯过一次错：把 check() 写在 `if show(cfg):` 里面，
        于是【读超时】时这条检查根本不会被执行，也不计入失败，
        汇总依然显示“全部通过”。这和账本第 35 条（回归脚本谎报）
        是同一类病：**测试工具自己必须先把“不知道”和“通过”分开**。
        """
        nonlocal ok, fail
        if cond:
            ok += 1
        else:
            fail += 1
        print(f"  {'✅' if cond else '❌'} {name}" + (f"   {extra}" if extra else ""))

    def step(title):
        print(f"\n{title}")

    # ---- ① 回读 -----------------------------------------------------------
    step("[1] 回读当前配置（发 '?'）")
    cfg = query(ser)
    if cfg is None:
        check("收到回应帧", False,
              "完全没回应。检查：波特率 115200？TX/RX 接反？板子复位了吗？")
        print("\n" + "=" * 60)
        print(f" 通过 {ok}  失败 {fail}")
        print("=" * 60)
        return ok, fail
    print(f"      原始帧: {cfg['raw']!r}")
    for k in "VSHGB":
        check(f"帧里有 '{k}' 字段", k in cfg, f"{k}={cfg.get(k, '—')}")

    base = {k: cfg.get(k) for k in "VSHGB"}

    # ---- ② 写 -> 回读 -----------------------------------------------------
    step("[2] 写 V02 再回读（应看到 V 变成 02）")
    send(ser, "V02")
    cfg2 = query(ser)
    check("收到回应帧", cfg2 is not None)
    if cfg2:
        print(f"      回读: {cfg2['raw']}")
        check("V 已变成 02", cfg2.get("V") == "02", f"V={cfg2.get('V')}")
    else:
        print("      ❌ 没收到回应（超时）")

    step("[3] 写回原值，恢复现场")
    send(ser, f"V{base.get('V', '07')}")
    cfg3 = query(ser)
    check("收到回应帧", cfg3 is not None)
    if cfg3:
        print(f"      回读: {cfg3['raw']}")
        check("V 已恢复", cfg3.get("V") == base.get("V"), f"V={cfg3.get('V')}")
    else:
        print("      ❌ 没收到回应（超时）")

    # ---- ③ 大小写容错 -----------------------------------------------------
    step("[4] 大小写容错（发小写 's00'）")
    send(ser, "s00")
    cfg4 = query(ser)
    check("收到回应帧", cfg4 is not None)
    if cfg4:
        print(f"      回读: {cfg4['raw']}")
        check("小写命令被接受", cfg4.get("S") == "00", f"S={cfg4.get('S')}")
    else:
        print("      ❌ 没收到回应（超时）")

    # ---- ④ '?' 是全局命令 -------------------------------------------------
    step("[5] '?' 必须全局有效：先发半条命令 'V'，再发 '?' 应照样有回执")
    # 旧实现里 '?' 在 S_HI/S_LO 会掉进“非法字符”被吃掉，要按两次才看得到回执。
    send(ser, "V", wait=0.02)          # 进 S_HI，等价于“命令写了一半”
    time.sleep(0.05)
    cfg5 = query(ser)                   # 这个 '?' 应该能触发回执
    check("半条命令下 '?' 仍有回执", cfg5 is not None,
          "旧实现会吞掉，需按两次" if cfg5 is None else "")
    if cfg5:
        print(f"      回读: {cfg5['raw']}（V 应仍为上电值 {base.get('V')}）")
        check("非法字符未造成写入", cfg5.get("V") == base.get("V"),
              f"V={cfg5.get('V')}")

    # ---- ⑤ 单个 hex 位：必须带终止符才生效 -------------------------------
    step("[6] 单个 hex 位带终止符：'V2\\r' -> V 应为 20（2 当高 4 位）")
    send(ser, "V2\r")
    cfg6 = query(ser)
    check("收到回应帧", cfg6 is not None)
    if cfg6:
        print(f"      回读: {cfg6['raw']}")
        check("V == 20", cfg6.get("V") == "20", f"V={cfg6.get('V')}")
    else:
        print("      ❌ 没收到回应（超时）")

    send(ser, f"V{base.get('V', '07')}")
    cfg7 = query(ser)
    check("两位 hex 的写命令仍能正常执行",
          cfg7 is not None and cfg7.get("V") == base.get("V"),
          f"V={cfg7.get('V') if cfg7 else '—'}")

    # ---- ⑥ 中间态非法字符后要能脱困 ---------------------------------------
    step("[7] 半条命令 + 非法字符 '#’ 后，状态机必须能脱困")
    send(ser, "V2#", wait=0.05)         # 进 S_LO 后被 '#' 打断
    time.sleep(0.1)
    cfg8 = query(ser)
    check("能脱困并响应 '?'", cfg8 is not None)
    if cfg8:
        print(f"      回读: {cfg8['raw']}")
        check("非法字符未造成写入", cfg8.get("V") == base.get("V"),
              f"V={cfg8.get('V')}")
    # 再发一条完整命令，验证真的还能干活
    send(ser, "V01")
    cfg9 = query(ser)
    check("脱困后完整命令能执行", cfg9 is not None and cfg9.get("V") == "01",
          f"V={cfg9.get('V') if cfg9 else '—'}")
    send(ser, f"V{base.get('V', '07')}")

    # ---- ⑦ 无关字符 ------------------------------------------------------
    step("[8] 无关字符（回车/空格）应被忽略，不破坏状态机")
    send(ser, "\r\n")
    time.sleep(0.1)
    cfgA = query(ser)
    check("收到回应帧", cfgA is not None)
    if cfgA:
        print(f"      回读: {cfgA['raw']}")

    # ---- ⑧ 帧长 ----------------------------------------------------------
    step("[9] 帧长检查")
    ser.reset_input_buffer()
    ser.write(b"?")
    ser.flush()
    fr = read_frame(ser, 1.0)
    check("刚好 20 字节且以 CRLF 结尾",
          fr is not None and len(fr) == FRAME_LEN,
          f"len={len(fr) if fr else '—'}")

    print("\n" + "=" * 60)
    print(f" 通过 {ok}  失败 {fail}")
    print("=" * 60)
    return ok, fail


# ---------------------------------------------------------------------------
# 交互模式
# ---------------------------------------------------------------------------
def run_interactive(ser):
    print("=" * 60)
    print(f" UART 交互终端  {ser.port} @ {ser.baudrate} 8N1")
    print(" 直接打字回车发送；'?' 回读配置；Ctrl-C 退出")
    print(" 提示：写命令不回显，改完要发 '?' 才能看到新值")
    print("=" * 60)
    print()
    show(query(ser), "当前配置: ")
    print()
    try:
        while True:
            try:
                line = input("> ").strip()
            except EOFError:
                break
            if not line:
                continue
            if line in ("q", "quit", "exit"):
                break
            send(ser, line)
            # 等一下再收，写命令通常没回应
            time.sleep(0.15)
            pending = ser.read(ser.in_waiting or 0)
            if pending:
                sys.stdout.write(pending.decode("ascii", "replace"))
                sys.stdout.flush()
            else:
                # 没回应时帮用户回读一次，方便看效果
                cfg = query(ser, timeout=0.5)
                if cfg:
                    print(f"  [回读] {cfg['raw']}")
    except KeyboardInterrupt:
        print()
    print("bye")


def main():
    ap = argparse.ArgumentParser(
        description="本工程的 UART 命令通道终端 / 自检工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("用法：")[1] if "用法：" in __doc__ else "")
    ap.add_argument("-p", "--port", default="/dev/ttyUSB0", help="串口设备（默认 /dev/ttyUSB0）")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="波特率（默认 115200）")
    ap.add_argument("-c", "--cmd", action="append", default=None,
                    help="依次发送这些命令并打印回应（可重复）")
    ap.add_argument("--test", action="store_true", help="跑一遍协议自检")
    ap.add_argument("-l", "--list", action="store_true", help="列出可用串口后退出")
    a = ap.parse_args()

    if a.list:
        ports = [p for p in list_ports.comports()
                 if p.device.startswith(("/dev/ttyUSB", "/dev/ttyACM"))]
        if not ports:
            print("没检测到 USB 串口（/dev/ttyS* 是主板自带的，不是开发板）")
            return 1
        for p in ports:
            print(f"  {p.device:20s} {p.description}")
        return 0

    ser = open_port(a.port, a.baud)
    with ser:
        if a.test:
            ok, fail = run_test(ser)
            return 1 if fail else 0
        if a.cmd:
            for c in a.cmd:
                send(ser, c)
                if c.strip() == "?":
                    show(query(ser), f"{c:>6s} -> ")
                else:
                    time.sleep(0.1)
                    got = ser.read(ser.in_waiting or 0)
                    if got:
                        print(f"  {c:>6s} -> {got.decode('ascii','replace').strip()}")
                    else:
                        cfg = query(ser)
                        show(cfg, f"{c:>6s} -> [回读] ")
            return 0
        run_interactive(ser)
        return 0


if __name__ == "__main__":
    sys.exit(main())
