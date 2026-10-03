#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WinPE 网络安装方案 · 演示视频渲染器（Pillow 逐帧绘制 → ffmpeg 编码）"""
import subprocess, math, os

W, H, FPS = 1920, 1080, 24
FB = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
FR = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
OUT = os.path.dirname(os.path.abspath(__file__))

_FCACHE = {}
def F(size, bold=True):
    k = (size, bold)
    if k not in _FCACHE:
        _FCACHE[k] = ImageFont.truetype(FB if bold else FR, size)
    return _FCACHE[k]

from PIL import Image, ImageDraw, ImageFont

BG, PANEL, LINE = "#0a0f1e", "#111a2e", "#1e2a45"
CYAN, GREEN, YELLOW, RED = "#38bdf8", "#4ade80", "#fbbf24", "#f87171"
TXT, DIM = "#e8eef7", "#8b98ad"

DUR = {1: 6.19, 2: 9.60, 3: 13.51, 4: 27.07, 5: 14.57, 6: 5.83}
TAIL = 0.8

def ease(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3

def base():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    for x in range(0, W, 80):
        d.line([(x, 0), (x, H)], fill="#0d1425")
    for y in range(0, H, 80):
        d.line([(0, y), (W, y)], fill="#0d1425")
    d.line([(0, 0), (W, 0)], fill=CYAN, width=5)
    return img, d

def ctext(d, y, s, fnt, fill=TXT):
    bb = d.textbbox((0, 0), s, font=fnt)
    d.text(((W - (bb[2] - bb[0])) / 2, y), s, font=fnt, fill=fill)

def fade(img, t01):
    a = 1.0
    if t01 < 0.12: a = t01 / 0.12
    if t01 > 0.90: a = max(0.0, (1 - t01) / 0.10)
    if a >= 1: return img
    return Image.blend(Image.new("RGB", (W, H), "black"), img, a)

def pill(d, xy, text, fnt, fg=CYAN, bgc="#0f2233"):
    x0, y0, x1, y1 = xy
    d.rounded_rectangle(xy, radius=(y1 - y0) // 2, fill=bgc, outline=fg, width=2)
    bb = d.textbbox((0, 0), text, font=fnt)
    d.text(((x0 + x1 - (bb[2] - bb[0])) / 2, y0 + (y1 - y0 - (bb[3] - bb[1])) / 2 - bb[1]),
           text, font=fnt, fill=fg)

# ---------------- 场景 ----------------
def scene1(f, n):
    img, d = base(); t = f / n
    rise = (1 - ease(t * 3)) * 70
    ctext(d, 330 + rise, "Windows 网络安装", F(130), TXT)
    ctext(d, 520 + rise, "类 macOS 互联网恢复 · 自建版", F(56), CYAN)
    if t > 0.25:
        a = ease((t - 0.25) * 4)
        y = 700 + (1 - a) * 30
        bb = d.textbbox((0, 0), "WinPE 启动盘  +  自建服务端", font=F(40))
        w = bb[2] - bb[0] + 90
        pill(d, ((W - w) / 2, y, (W + w) / 2, y + 76), "WinPE 启动盘  +  自建服务端", F(40))
    ctext(d, 950, "开机联网 · 一键重装", F(36), DIM)
    return fade(img, t)

def scene2(f, n):
    img, d = base(); t = f / n
    ctext(d, 120, "为什么需要它？", F(64), TXT)
    e = ease(t * 3)
    # 左卡 macOS
    lx = 150 - (1 - e) * 250
    d.rounded_rectangle([(lx, 260), (lx + 730, 830)], radius=28, fill=PANEL, outline=LINE, width=2)
    d.text((lx + 60, 320), "macOS", font=F(72), fill=TXT)
    d.text((lx + 60, 430), "✓  互联网恢复", font=F(44), fill=GREEN)
    d.text((lx + 60, 510), "✓  开机联网重装", font=F(44), fill=GREEN)
    d.text((lx + 60, 620), "开箱即用，零维护", font=F(36), fill=DIM)
    # 右卡 Windows
    rx = 1040 + (1 - e) * 250
    d.rounded_rectangle([(rx, 260), (rx + 730, 830)], radius=28, fill=PANEL, outline=LINE, width=2)
    d.text((rx + 60, 320), "Windows", font=F(72), fill=TXT)
    d.text((rx + 60, 430), "✗  官方无此能力", font=F(44), fill=RED)
    d.text((rx + 60, 530), "政企现状：", font=F(40), fill=YELLOW)
    d.text((rx + 60, 600), "大量胖镜像", font=F(40), fill=DIM)
    d.text((rx + 60, 660), "Sysprep · Ghost · ISO", font=F(36), fill=DIM)
    d.text((rx + 60, 720), "版本管理极重", font=F(36), fill=DIM)
    # VS
    if t > 0.3:
        d.ellipse([(W/2-58, 500), (W/2+58, 616)], fill="#1a2340", outline=CYAN, width=3)
        bb = d.textbbox((0, 0), "VS", font=F(48))
        d.text((W/2-(bb[2]-bb[0])/2, 558-(bb[3]-bb[1])/2-bb[1]), "VS", font=F(48), fill=CYAN)
    return fade(img, t)

def dash_arrow(d, x0, x1, y, color, frame, right=True):
    off = (frame * 6) % 24
    x = x0 - 24 + off if right else x0
    segs = []
    xx = x0 - 24 + off
    while xx < x1:
        a, b = max(xx, x0), min(xx + 12, x1)
        if b > a: d.line([(a, y), (b, y)], fill=color, width=4)
        xx += 24
    # 箭头
    ax = x1 if right else x0
    s = -1 if right else 1
    d.polygon([(ax, y), (ax + 18*s, y-11), (ax + 18*s, y+11)], fill=color)

def scene3(f, n):
    img, d = base(); t = f / n
    ctext(d, 110, "方案架构", F(64), TXT)
    e = ease(t * 4)
    # 左节点
    ny = 360 + (1 - e) * 60
    d.rounded_rectangle([(180, ny), (700, ny+320)], radius=24, fill=PANEL, outline=CYAN, width=3)
    ctext_at = lambda y, s, fn, c: (lambda bb: d.text((450-(bb[2]-bb[0])/2, y), s, font=fn, fill=c))(d.textbbox((0,0),s,font=fn))
    ctext_at(ny+60, "目标机器", F(56), TXT)
    ctext_at(ny+150, "WinPE 启动盘", F(40), CYAN)
    ctext_at(ny+215, "安装程序全自动", F(32), DIM)
    # 右节点
    d.rounded_rectangle([(1220, ny), (1740, ny+320)], radius=24, fill=PANEL, outline=GREEN, width=3)
    ctext_at2 = lambda y, s, fn, c: (lambda bb: d.text((1480-(bb[2]-bb[0])/2, y), s, font=fn, fill=c))(d.textbbox((0,0),s,font=fn))
    ctext_at2(ny+60, "服务端", F(56), TXT)
    ctext_at2(ny+150, "镜像库 · 清单 API", F(40), GREEN)
    ctext_at2(ny+215, "Python 零依赖", F(32), DIM)
    # 箭头
    if t > 0.25:
        labels = [("拉取镜像清单  GET /api/manifest", CYAN, True),
                  ("获取镜像  SMB 直读 / HTTP 下载", GREEN, False),
                  ("上报结果  POST /api/report", YELLOW, True)]
        for i, (lab, col, r2l) in enumerate(labels):
            y = ny + 70 + i * 95
            if r2l: dash_arrow(d, 710, 1210, y, col, f, right=True)
            else:   dash_arrow(d, 710, 1210, y, col, f, right=False)
            bb = d.textbbox((0, 0), lab, font=F(28))
            d.text(((710+1210-(bb[2]-bb[0]))/2, y-46), lab, font=F(28), fill=col)
    # 底部三步
    if t > 0.45:
        steps = ["① 开机进 WinPE", "② 联网拉取镜像清单", "③ 选镜像一键安装"]
        for i, s in enumerate(steps):
            a = ease((t-0.45)*5 - i*0.12)
            y = 800 + (1-a)*30
            bb = d.textbbox((0,0), s, font=F(36)); w = bb[2]-bb[0]+80
            x0 = 960 - (3* (w+40))/2 + i*(w+40) + 20
            if a > 0: pill(d, (x0, y, x0+w, y+68), s, F(36))
    return fade(img, t)

TERM = [
    ("==> 连接服务端 http://192.168.1.10:8080", CYAN),
    ("  [OK] 服务端连接正常", GREEN),
    ("==> 获取镜像清单", CYAN),
    ("  [1] Win11 24H2 精简基线  (4.50 GB, smb)", TXT),
    ("  [2] Win11 24H2 财务专用  (5.77 GB, http)", TXT),
    ("选择要安装的镜像 [1]: 1", YELLOW),
    ("  [OK] 已选择：精简基线", GREEN),
    ("==> 磁盘 0 分区布局：", CYAN),
    ("  序号   大小       盘符   类型", DIM),
    ("  1      100 MB            EFI 系统分区", TXT),
    ("  2      16 MB             MSR 保留分区", TXT),
    ("  3      200 GB     C:     数据分区", TXT),
    ("  4      276 GB     D:     数据分区", TXT),
    ("安装模式：[1] 整盘清空   [2] 保留分区", TXT),
    ("选择安装模式 [1]: 2", YELLOW),
    ("==> 正在格式化分区 3 为 NTFS ...", CYAN),
    ("  [OK] 目标分区就绪 (W:)，数据分区保留", GREEN),
    ("==> 正在释放镜像到 W: ...", CYAN),
    ("__PROGRESS__", None),
    ("  [OK] 镜像释放完成", GREEN),
    ("==> 写入系统引导 ... [OK]", CYAN),
    ("★ 安装完成！重启进入新系统", GREEN),
]

def scene4(f, n):
    img, d = base(); t = f / n
    ctext(d, 60, "安装实录（演示）", F(48), TXT)
    # 终端窗口
    x0, y0, x1, y1 = 120, 150, 1800, 990
    d.rounded_rectangle([(x0,y0),(x1,y1)], radius=20, fill="#0b1120", outline=LINE, width=2)
    d.rounded_rectangle([(x0,y0),(x1,y0+58)], radius=20, fill="#141d33", outline=None)
    d.rectangle([(x0,y0+38),(x1,y0+58)], fill="#141d33")
    for i, c in enumerate([RED, YELLOW, GREEN]):
        d.ellipse([(x0+28+i*36, y0+19),(x0+48+i*36, y0+39)], fill=c)
    d.text((x0+140, y0+14), "WinPE  ·  NetInstall.ps1 —— Windows 网络安装", font=F(28), fill=DIM)
    fn = F(24); lh = 33; tx, ty = x0+40, y0+88
    # 行显示计划
    reveal = [8 + i*20 for i in range(18)] + [None] + [512, 548, 584]
    # 进度条 360→500
    for i, (txt, col) in enumerate(TERM):
        rf = reveal[i]
        if txt == "__PROGRESS__":
            if f < 360: continue
            p = ease((f-360)/140)
            yy = ty + i*lh
            bw = 900
            d.rounded_rectangle([(tx, yy+4),(tx+bw, yy+28)], radius=12, fill="#1a2340")
            d.rounded_rectangle([(tx, yy+4),(tx+bw*p, yy+28)], radius=12, fill=GREEN)
            d.text((tx+bw+24, yy-2), "%d%%" % int(p*100), font=fn, fill=GREEN)
            continue
        if rf is None or f < rf: continue
        yy = ty + i*lh
        if yy > y1 - 40: continue
        d.text((tx, yy), txt, font=fn, fill=col)
    # 光标
    shown = [i for i, rf in enumerate(reveal) if rf is not None and f >= rf and TERM[i][0] != "__PROGRESS__"]
    if shown and (f // 12) % 2 == 0:
        i = shown[-1]; txt, col = TERM[i]
        bb = d.textbbox((0,0), txt, font=fn)
        d.rectangle([(tx+bb[2]+6, ty+i*lh+4),(tx+bb[2]+18, ty+i*lh+28)], fill=CYAN)
    return fade(img, t)

def scene5(f, n):
    img, d = base(); t = f / n
    ctext(d, 110, "核心能力", F(64), TXT)
    cards = [
        ("双安装模式", "整盘清空 / 保留分区", CYAN),
        ("镜像安全校验", "SHA-256 全程校验", GREEN),
        ("双通道传输", "SMB 直读 / HTTP 断点续传", YELLOW),
        ("安装上报审计", "结果回传服务端", "#c084fc"),
    ]
    for i, (title, sub, col) in enumerate(cards):
        a = ease(t*4 - i*0.35)
        if a < 0.08: continue
        cx, cy = 480 + (i%2)*960, 400 + (i//2)*300
        w2, h2 = 400*a, 120*a
        r = max(0, min(24, min(w2, h2) - 1))  # PIL 内部 y0+r+1/y1-r-1，要求 r <= (高-2)/2
        d.rounded_rectangle([(cx-w2, cy-h2),(cx+w2, cy+h2)], radius=r, fill=PANEL, outline=col, width=3)
        if a > 0.7:
            bb = d.textbbox((0,0), title, font=F(44))
            d.text((cx-(bb[2]-bb[0])/2, cy-62), title, font=F(44), fill=col)
            bb2 = d.textbbox((0,0), sub, font=F(32))
            d.text((cx-(bb2[2]-bb2[0])/2, cy+6), sub, font=F(32), fill=DIM)
    return fade(img, t)

def scene6(f, n):
    img, d = base(); t = f / n
    rise = (1-ease(t*3))*50
    ctext(d, 380+rise, "方案已开源", F(110), TXT)
    if t > 0.2:
        url = "github.com/sunboss/winpe-netinstall"
        bb = d.textbbox((0,0), url, font=F(44)); w = bb[2]-bb[0]+100
        pill(d, ((W-w)/2, 580, (W+w)/2, 664), url, F(44), fg=GREEN, bgc="#0e2417")
    ctext(d, 740, "服务端 · 客户端 · 文档齐全，拿去就能试", F(40), DIM)
    return fade(img, t)

SCENES = {1: scene1, 2: scene2, 3: scene3, 4: scene4, 5: scene5, 6: scene6}

def render_scene(i):
    frames = int((DUR[i] + TAIL) * FPS)
    fn = os.path.join(OUT, "frames%d.mp4" % i)
    p = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", "%dx%d" % (W, H), "-framerate", str(FPS), "-i", "-",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
         "-pix_fmt", "yuv420p", fn],
        stdin=subprocess.PIPE)
    for fr in range(frames):
        img = SCENES[i](fr, frames)
        p.stdin.write(img.tobytes())
    p.stdin.close(); p.wait()
    # 混入配音（音频补齐尾部静音）
    fa = os.path.join(OUT, "scene%d.mp4" % i)
    vdur = frames / FPS
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", fn, "-i", os.path.join(OUT, "audio", "s%d.mp3" % i),
         "-af", "apad=whole_dur=%.2f" % vdur, "-c:v", "copy", "-c:a", "aac",
         "-shortest", fa], check=True)
    os.remove(fn)
    print("场景 %d 完成（%d 帧，%.1fs）" % (i, frames, vdur), flush=True)

if __name__ == "__main__":
    for i in range(1, 7):
        render_scene(i)
    # 拼接
    lst = os.path.join(OUT, "concat.txt")
    with open(lst, "w") as fp:
        for i in range(1, 7):
            fp.write("file 'scene%d.mp4'\n" % i)
    final = os.path.join(OUT, "winpe-netinstall-demo.mp4")
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
         "-i", lst, "-c", "copy", final], check=True)
    print("成品:", final)
