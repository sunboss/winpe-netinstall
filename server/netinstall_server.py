#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WinPE 网络安装服务端（零第三方依赖，仅用 Python 标准库）

功能：
  - GET /                  服务状态页（列出可用镜像）
  - GET /api/manifest      镜像清单 JSON（客户端 NetInstall.ps1 拉取）
  - GET /files/<name>      镜像文件下载（支持 Range 断点续传，适配 BITS）
  - POST /api/report       客户端安装结果上报（写入 reports.log）

用法：
  python3 netinstall_server.py --dir ./images --port 8080
  镜像文件（.wim/.esd/.swm）放到 --dir 目录，并在同目录下编写 manifest.json

manifest.json 示例见同目录 manifest.example.json
"""
import argparse
import datetime
import html
import json
import mimetypes
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

VERSION = "1.0.0"


class Handler(BaseHTTPRequestHandler):
    server_version = "WinPENetInstall/" + VERSION

    # ---------- 工具 ----------
    def _images_dir(self):
        return self.server.images_dir

    def _send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _load_manifest(self):
        path = os.path.join(self._images_dir(), "manifest.json")
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            return {"server": "netinstall/" + VERSION, "images": []}
        except json.JSONDecodeError as e:
            return {"error": "manifest.json 解析失败: %s" % e}

    def _base_url(self):
        # 优先用 Host 头拼出客户端可达的地址
        host = self.headers.get("Host")
        if not host:
            host = "%s:%d" % self.server.server_address
        return "http://%s" % host

    def log_message(self, fmt, *args):  # noqa: N802 - 保持基类签名
        sys.stdout.write("[%s] %s\n" % (
            datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            fmt % args))
        sys.stdout.flush()

    # ---------- 路由 ----------
    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if path == "/" or path == "/index.html":
            return self._handle_index()
        if path == "/api/manifest":
            return self._handle_manifest()
        if path.startswith("/files/"):
            return self._handle_file(path[len("/files/"):])
        self.send_error(404, "Not Found")

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/report":
            return self._handle_report()
        self.send_error(404, "Not Found")

    # ---------- 处理器 ----------
    def _handle_index(self):
        manifest = self._load_manifest()
        images = manifest.get("images", [])
        rows = []
        for img in images:
            size = img.get("size", 0)
            size_str = "%.2f GB" % (size / 102.4**3) if size else "未知"
            rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                html.escape(str(img.get("id", ""))),
                html.escape(str(img.get("name", ""))),
                size_str,
                html.escape(str(img.get("description", ""))),
            ))
        page = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>WinPE 网络安装服务</title>
<style>body{font-family:sans-serif;max-width:900px;margin:40px auto;padding:0 16px}
table{border-collapse:collapse;width:100%%}td,th{border:1px solid #ccc;padding:8px;text-align:left}
code{background:#f4f4f4;padding:2px 6px;border-radius:4px}</style></head>
<body>
<h1>🖥️ WinPE 网络安装服务 <small>v%s</small></h1>
<p>客户端（WinPE）在启动后访问 <code>http://本机IP:端口/api/manifest</code> 获取镜像清单。</p>
<h2>可用镜像（%d）</h2>
<table><tr><th>ID</th><th>名称</th><th>大小</th><th>说明</th></tr>%s</table>
<h2>快速开始</h2>
<ol>
<li>把 <code>.wim</code> / <code>.esd</code> 镜像放入 images 目录</li>
<li>编辑 <code>images/manifest.json</code> 登记镜像信息（含 SHA-256）</li>
<li>用 WinPE 启动盘启动目标机器，按提示输入本服务地址完成安装</li>
</ol>
</body></html>""" % (VERSION, len(images), "\n".join(rows) if rows else
                     "<tr><td colspan=4>暂无镜像，请先放入镜像文件并编辑 manifest.json</td></tr>")
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_manifest(self):
        manifest = self._load_manifest()
        base = self._base_url()
        # 把相对路径补成客户端可直接用的绝对 URL
        for img in manifest.get("images", []):
            f = img.get("file", "")
            if f and not img.get("http_url"):
                img["http_url"] = base + "/files/" + f
        manifest["server_time"] = datetime.datetime.now().isoformat(timespec="seconds")
        self._send_json(manifest)

    def _handle_file(self, name):
        # 防目录穿越
        if ".." in name or name.startswith("/"):
            self.send_error(403, "Forbidden")
            return
        fpath = os.path.join(self._images_dir(), name)
        if not os.path.isfile(fpath):
            self.send_error(404, "File Not Found")
            return
        fsize = os.path.getsize(fpath)
        ctype = mimetypes.guess_type(fpath)[0] or "application/octet-stream"

        # 解析 Range 头（BITS 断点续传用）
        range_hdr = self.headers.get("Range")
        start, end = 0, fsize - 1
        status = 200
        if range_hdr:
            m = re.match(r"bytes=(\d*)-(\d*)$", range_hdr.strip())
            if m:
                s, e = m.groups()
                # 仅支持 start-end / start- 形式；后缀形式(-N)不支持则忽略
                if s:
                    start = int(s)
                    end = int(e) if e else fsize - 1
                    if 0 <= start <= end < fsize:
                        status = 206
                    else:
                        self.send_error(416, "Range Not Satisfiable")
                        return
        length = end - start + 1

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        # 让浏览器/下载工具直接保存而不是尝试打开
        self.send_header("Content-Disposition",
                         'attachment; filename="%s"' % os.path.basename(fpath))
        if status == 206:
            self.send_header("Content-Range",
                             "bytes %d-%d/%d" % (start, end, fsize))
        self.end_headers()

        # 分块发送，避免大文件占内存
        with open(fpath, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _handle_report(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            data = {"raw": raw[:200].decode("utf-8", "replace")}
        data["_received_at"] = datetime.datetime.now().isoformat(timespec="seconds")
        data["_client_ip"] = self.client_address[0]
        log_path = os.path.join(self._images_dir(), "reports.log")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
        self._send_json({"ok": True})


def main():
    ap = argparse.ArgumentParser(description="WinPE 网络安装服务端")
    ap.add_argument("--dir", default="images", help="镜像目录（默认 ./images）")
    ap.add_argument("--host", default="0.0.0.0", help="监听地址（默认 0.0.0.0）")
    ap.add_argument("--port", type=int, default=8080, help="监听端口（默认 8080）")
    args = ap.parse_args()

    images_dir = os.path.abspath(args.dir)
    os.makedirs(images_dir, exist_ok=True)
    # 没有 manifest.json 时生成一个空模板，避免客户端 404
    manifest_path = os.path.join(images_dir, "manifest.json")
    if not os.path.exists(manifest_path):
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump({"server": "netinstall/" + VERSION, "images": []},
                      f, ensure_ascii=False, indent=2)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.images_dir = images_dir
    print("=" * 60)
    print(" WinPE 网络安装服务 v%s" % VERSION)
    print(" 镜像目录: %s" % images_dir)
    print(" 清单接口: http://<本机IP>:%d/api/manifest" % args.port)
    print(" 状态页面: http://<本机IP>:%d/" % args.port)
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n服务已停止")


if __name__ == "__main__":
    main()
