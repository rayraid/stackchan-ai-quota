#!/usr/bin/env python3
"""开发调试：通过 USB 串口向设备发命令、截屏（不需要看真机屏幕就能检查画面）。

用法（用项目里的 Python 运行：../.venv/bin/python tools/devtool.py ...）：
  devtool.py cmd "info"                    发一条命令并打印设备回应
  devtool.py shot out.png ["demo done" ...] 先发若干命令，再把当前画面存成 PNG
  devtool.py sheet out.png "demo calm;page face" "demo done" ...  多个画面拼成一张对照图
"""
import glob
import struct
import sys
import time
import zlib

import serial


def open_port():
    ports = sorted(glob.glob('/dev/cu.usbmodem*'))
    if not ports:
        sys.exit('没找到设备串口，确认 StackChan 已经用 USB 线连到这台 Mac')
    s = serial.Serial()
    s.port = ports[0]
    s.baudrate = 115200
    s.timeout = 0.2
    s.open()          # DTR/RTS 用默认值（两根都拉起），这样打开串口不会让设备复位
    # 等设备能回应命令为止（刚上电或刚烧录完需要几秒）
    t0 = time.time()
    while time.time() - t0 < 12:
        s.reset_input_buffer()
        s.write(b'\ninfo\n')
        s.flush()
        t1, out = time.time(), b''
        while time.time() - t1 < 1.0:
            out += s.read(4096)
        if b'INFO ' in out:
            return s
    sys.exit('设备没有回应命令')


def send(s, line, wait=0.8):
    s.reset_input_buffer()
    s.write((line + '\n').encode())
    s.flush()
    t0, out = time.time(), b''
    while time.time() - t0 < wait:
        out += s.read(4096)
    return out.decode('utf-8', 'replace').strip()


def grab(s):
    """向设备要一帧画面，返回 (宽, 高, 每行的 RGB 字节)"""
    s.reset_input_buffer()
    s.write(b'shot\n')
    s.flush()
    buf, t0 = b'', time.time()
    while time.time() - t0 < 20:
        buf += s.read(65536)
        if b'\nEND' in buf:
            break
    text = buf.decode('ascii', 'replace')
    i = text.find('SHOT ')
    if i < 0 or 'END' not in text:
        sys.exit('截屏失败，设备回应：' + text[:200])
    lines = text[i:].split('\n')
    w, h = map(int, lines[0].split()[1:3])
    rows = []
    for ln in lines[1:1 + h]:
        row = bytearray()
        for tok in ln.split():
            c, n = tok.split('*')
            c, n = int(c, 16), int(n)
            r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
            row += bytes(((r * 255) // 31, (g * 255) // 63, (b * 255) // 31)) * n
        if len(row) != w * 3:
            sys.exit('截屏数据不完整（第 %d 行）' % len(rows))
        rows.append(bytes(row))
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b''.join(b'\x00' + r for r in rows)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)
    print('已保存', path, '%dx%d' % (w, h))


def shot(s, path):
    write_png(path, *grab(s))


def sheet(s, path, groups, cols=3, gap=8):
    """每个参数是一组用分号隔开的命令；每组执行完截一帧，拼成一张对照图"""
    frames = []
    for g in groups:
        for c in g.split(';'):
            send(s, c.strip(), 0.4)
        time.sleep(0.35)
        frames.append(grab(s))
    w, h = frames[0][0], frames[0][1]
    n = len(frames)
    rows_n = (n + cols - 1) // cols
    W, H = cols * w + (cols + 1) * gap, rows_n * h + (rows_n + 1) * gap
    bg = bytes((60, 66, 78))
    out = [bytearray(bg * W) for _ in range(H)]
    for k, (_, _, rows) in enumerate(frames):
        x0, y0 = gap + (k % cols) * (w + gap), gap + (k // cols) * (h + gap)
        for y in range(h):
            out[y0 + y][x0 * 3:(x0 + w) * 3] = rows[y]
    write_png(path, W, H, [bytes(r) for r in out])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    s = open_port()
    if sys.argv[1] == 'cmd':
        for c in sys.argv[2:]:
            print(send(s, c))
    elif sys.argv[1] == 'shot':
        for c in sys.argv[3:]:
            print(send(s, c, 0.5))
        time.sleep(0.3)
        shot(s, sys.argv[2])
    elif sys.argv[1] == 'sheet':
        sheet(s, sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
