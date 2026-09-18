#!/usr/bin/env python3
# check-sources.py — 检测已导入的 type=1 源在 macOS 上是否真的能播
#
# 背景：TVBox 生态里绝大多数源是 type=3 的 jar spider（安卓 dex 实现），
# macOS 无法运行；Mac 只能用 type=1（CatVod/苹果CMS HTTP API）源。
# 而 type=1 源能否播，取决于三个环节各自是否活着：
#   1. API（?ac=detail）能否返回 JSON        → 反爬/失效会 403/非JSON
#   2. 播放地址 m3u8 能否拉到                → 单集地址失效/防盗链会 403/404
#   3. m3u8 里的分段（.ts）能否拉到          → 分段 CDN 经常时好时坏
# 本脚本对每个源抽最多 3 个剧集，实测上述三环，给出可用性排名。
#
# 用法: python3 scripts/check-sources.py [--per-site 3] [--workers 8]
# 需要：已导入配置（~/Library/Application Support/TVBoxMac/configs.json）
import argparse
import json
import os
import re
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

socket.setdefaulttimeout(8)
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = {"User-Agent": "okhttp/3.10.0"}  # TVBox 安卓默认 UA

CONFIG = os.path.expanduser("~/Library/Application Support/TVBoxMac/configs.json")


def enc(u):
    """URL 中文/空格编码，保留结构字符（源里常带中文路径）"""
    return urllib.parse.quote(u, safe=":/?&=#%+,;@!$()*~[]")


def fetch(u, timeout=8, limit=400000):
    try:
        r = urllib.request.urlopen(
            urllib.request.Request(enc(u), headers=UA), timeout=timeout, context=CTX)
        return r.getcode(), r.read(limit)
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception:
        return 0, b""


def strip_proxy(u):
    """还原 TVBox 本机代理地址：http://127.0.0.1:<port>/p/<n>/proxy/<真实URL>"""
    return re.sub(r"^https?://(127\.0\.0\.1|localhost):\d+/p/\d+/proxy/", "", u)


def build(api, query):
    api = api.rstrip("/")
    return api + ("&" if "?" in api else "?") + query


def absu(base, ref):
    if ref.startswith("http"):
        return ref
    p = urllib.parse.urlparse(base)
    return f"{p.scheme}://{p.netloc}" + (ref if ref.startswith("/") else "/" + ref)


def first_media(text):
    """master playlist → 返回子列表相对路径；media playlist → 返回首个分段"""
    m = re.search(r"^#EXT-X-STREAM-INF.*\n(?!\#)(.+)$", text, re.M)
    if m:
        return ("master", m.group(1).strip())
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return ("media", line)
    return (None, None)


def probe(name, api, per_site):
    api = strip_proxy(api)
    r = {"name": name, "api_ok": False, "eps": 0, "m3u8_ok": 0,
         "seg_ok": 0, "seg_times": [], "note": ""}
    code, data = fetch(build(api, "ac=detail&pg=1"))
    if code != 200:
        r["note"] = f"API {code}"
        return r
    try:
        lst = json.loads(data).get("list") or []
    except Exception:
        r["note"] = "API 非JSON（反爬/失效）"
        return r
    if not lst:
        r["note"] = "无列表"
        return r
    r["api_ok"] = True

    for vod in lst[:per_site]:
        try:
            c2, d2 = fetch(build(api, f"ac=detail&ids={vod.get('vod_id')}"))
            if c2 != 200:
                continue
            v = (json.loads(d2).get("list") or [{}])[0]
            m3u8 = None
            # 播放组形如 "第1集$url#第2集$url$$$组2..."：优先取直连媒体（.m3u8/.mp4）
            for g in (v.get("vod_play_url") or "").split("$$$"):
                for item in g.split("#")[:2]:
                    u = item.split("|")[-1].split("$")[-1]
                    if re.search(r"\.(m3u8|mp4)", u, re.I):
                        m3u8 = u
                        break
                if m3u8:
                    break
            if not m3u8:
                continue
            r["eps"] += 1
            c3, d3 = fetch(m3u8)
            if c3 != 200:
                continue
            kind, ref = first_media(d3.decode("utf-8", "ignore"))
            if kind == "master":
                c4, d4 = fetch(absu(m3u8, ref))
                if c4 != 200:
                    continue
                kind2, seg = first_media(d4.decode("utf-8", "ignore"))
                if kind2 != "media":
                    continue
                ref = absu(absu(m3u8, ref), seg)
            elif kind == "media":
                ref = absu(m3u8, ref)
            else:
                continue
            r["m3u8_ok"] += 1
            t0 = time.time()
            c5, d5 = fetch(ref, timeout=12, limit=300000)
            if c5 == 200 and len(d5) > 5000:
                r["seg_ok"] += 1
                r["seg_times"].append(round(time.time() - t0, 1))
        except Exception:
            pass
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-site", type=int, default=3, help="每个源抽测的剧集数")
    ap.add_argument("--workers", type=int, default=8, help="并发数")
    args = ap.parse_args()

    if not os.path.exists(CONFIG):
        print(f"找不到配置文件：{CONFIG}（先在 app 里导入配置）")
        return
    entries = json.load(open(CONFIG))
    sites, seen = [], set()
    for e in entries:
        for s in e["loaded"]["config"].get("sites", []):
            if s.get("type", 1) == 1 and str(s.get("api", "")).startswith("http"):
                key = s.get("api")
                if key in seen:
                    continue
                seen.add(key)
                sites.append((s.get("name", "?"), s["api"]))

    print(f"探测 {len(sites)} 个 type=1 源（Mac 可用类型），每源最多 {args.per_site} 个剧集…\n")
    out = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(probe, n, a, args.per_site) for n, a in sites]
        for i, f in enumerate(as_completed(futs), 1):
            r = f.result()
            out.append(r)
            print(f"[{i}/{len(sites)}] {r['name'][:20]:22} "
                  f"API{'✓' if r['api_ok'] else '✗'} 剧{r['eps']} "
                  f"m3u8 {r['m3u8_ok']} 分段 {r['seg_ok']} {r['note']}", flush=True)

    good = [r for r in out if r["seg_ok"] > 0]
    good.sort(key=lambda r: -(r["seg_ok"]))

    print("\n" + "=" * 66)
    print(f"✅ 实测能播（分段拉到数据）: {len(good)}/{len(out)}")
    for r in good:
        avg = (sum(r["seg_times"]) / len(r["seg_times"])) if r["seg_times"] else 0
        print(f"  {r['name'][:26]:28} 剧{r['eps']} m3u8成功{r['m3u8_ok']} "
              f"分段成功{r['seg_ok']} 平均{avg:.1f}s")
    print(f"\n❌ 当前不可用: {len(out) - len(good)}")
    for r in out:
        if r["seg_ok"] == 0:
            print(f"  {r['name'][:26]:28} {r['note'] or 'm3u8/分段拉不到（CDN 或地址失效）'}")
    print("\n提示：灰产源 CDN 时好时坏，建议隔一段时间重跑，保留多个可用源作备选。")


if __name__ == "__main__":
    main()
