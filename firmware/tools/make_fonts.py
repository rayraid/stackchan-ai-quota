#!/usr/bin/env python3
"""把开源字体切成机器人用的平滑字体（VLW 格式，M5GFX 直接能用）。

字体来源（SIL Open Font License 1.1，见 fonts/OFL-*.txt）：
  - Noto Sans SC：中文（英文界面也用它）
  - Noto Sans JP：日文（用日文字形，不拿简体字形凑）
  - Inter：数字
只截取用得到的字：
  - 正文 14/16 号：中文是常用汉字（GB2312 一级），日文是假名 + JIS 第一水准汉字，再加英文和标点
  - 标题 18/26/38 号：只截取 src/i18n.cpp 里那种语言的固定文字

用法（在 firmware 目录）：
  ../.venv/bin/pip install freetype-py
  ../.venv/bin/python tools/make_fonts.py fonts/src
fonts/src 里要有 NotoSansSC.ttf、NotoSansJP.ttf、Inter.ttf（google/fonts 仓库里的可变字体）。
"""
import os
import re
import struct
import sys

import freetype

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'fonts')

ASCII = ''.join(chr(c) for c in range(0x20, 0x7F))
PUNCT = '，。、：；！？“”‘’（）《》【】…—～·￥×÷°' + ''.join(chr(c) for c in range(0xFF01, 0xFF5F))
KANA = ''.join(chr(c) for c in list(range(0x3041, 0x3097)) + list(range(0x30A1, 0x30FD))) + '々〜「」『』、。・'

# 小管家生成、发给机器人的文字（时间段、恢复时间、提醒原因等），基本都在常用字里，这里再保险一下
MAC_ZH = '小时本周本月今天明天周一二三四五六日恢复重置照现在的速度后用完不到做完了等你看结果需要批准有问题要问出错停下新消息未知项目测试暂时读还没用过'
MAC_JA = '時間今週今月今日明日月火水木金土曜回復リセット完了しました結果を確認承認が必要質問がありますエラーで停止お知らせ不明なプロジェクトテスト取得できません未使用このペースだと後に上限'


def decode_rows(codec, his, los):
    out = []
    for hi in his:
        for lo in los:
            try:
                out.append(bytes([hi, lo]).decode(codec))
            except UnicodeDecodeError:
                pass
    return ''.join(out)


def gb2312_level1():
    return decode_rows('gb2312', range(0xB0, 0xD8), range(0xA1, 0xFF))


def jis_level1():
    return decode_rows('euc_jp', range(0xB0, 0xD0), range(0xA1, 0xFF))


def table_chars(lang):
    """src/i18n.cpp 里某种语言那张表用到的字"""
    src = open(os.path.join(HERE, '..', 'src', 'i18n.cpp'), encoding='utf-8').read()
    m = re.search(r'%s\[S_COUNT\] = \{(.*?)\n\};' % lang, src, re.S)
    return ''.join(sorted(set(m.group(1))))


def render(font_path, size, chars, wght, opsz=None, name=''):
    face = freetype.Face(font_path)
    coords = [wght] if opsz is None else [max(14, min(32, opsz)), wght]
    face.set_var_design_coords(coords)
    face.set_pixel_sizes(0, size)
    glyphs = []
    for ch in sorted(set(chars), key=ord):
        cp = ord(ch)
        if cp < 0x20 or cp > 0xFFFF or face.get_char_index(cp) == 0:
            continue
        face.load_char(ch, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_LIGHT)
        g = face.glyph
        bm = g.bitmap
        w, h = bm.width, bm.rows
        data = bytearray()
        for r in range(h):
            data += bytes(bm.buffer[r * bm.pitch: r * bm.pitch + w])
        adv = int(round(g.advance.x / 64))
        if w > 255 or adv > 255:
            raise SystemExit('字太大了：%s %d' % (ch, size))
        glyphs.append((cp, h, w, adv, g.bitmap_top, g.bitmap_left, bytes(data)))
    asc = int(round(face.size.ascender / 64))
    desc = int(round(-face.size.descender / 64))
    out = bytearray(struct.pack('>6i', len(glyphs), 11, size, 0, asc, desc))
    for cp, h, w, adv, top, left, _ in glyphs:
        out += struct.pack('>7i', cp, h, w, adv, top, left, 0)
    for g in glyphs:
        out += g[6]
    with open(os.path.join(OUT, name + '.vlw'), 'wb') as f:
        f.write(out)
    print('%-8s %3dpx  %4d 个字  %7.1f KB' % (name, size, len(glyphs), len(out) / 1024))
    return len(out)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, 'src')
    sc, jp, num = (os.path.join(src, n) for n in ('NotoSansSC.ttf', 'NotoSansJP.ttf', 'Inter.ttf'))
    zh_title = ASCII + PUNCT + table_chars('ZH') + table_chars('EN')
    ja_title = ASCII + PUNCT + table_chars('JA')
    zh_body = ASCII + PUNCT + gb2312_level1() + zh_title + MAC_ZH
    ja_body = ASCII + PUNCT + KANA + jis_level1() + ja_title + MAC_JA
    os.makedirs(OUT, exist_ok=True)
    total = 0
    total += render(sc, 14, zh_body, 400, name='cn14')
    total += render(sc, 16, zh_body, 500, name='cn16')
    total += render(sc, 18, zh_title, 700, name='cn18b')
    total += render(sc, 26, zh_title, 700, name='cn26b')
    total += render(sc, 38, zh_title, 800, name='cn38b')
    total += render(jp, 14, ja_body, 400, name='jp14')
    total += render(jp, 16, ja_body, 500, name='jp16')
    total += render(jp, 18, ja_title, 700, name='jp18b')
    total += render(jp, 26, ja_title, 700, name='jp26b')
    total += render(jp, 38, ja_title, 800, name='jp38b')
    total += render(num, 15, ASCII, 700, opsz=15, name='num15b')
    total += render(num, 18, ASCII, 600, opsz=18, name='num18')
    total += render(num, 22, ASCII, 700, opsz=22, name='num22b')
    total += render(num, 28, ASCII, 700, opsz=28, name='num28b')
    print('合计 %.2f MB' % (total / 1024 / 1024))


if __name__ == '__main__':
    main()
