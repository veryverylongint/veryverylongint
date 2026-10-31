#!/usr/bin/env python3
"""analyze_obs.py — 分析 OBS 拍摄的 Companion-01 裸眼 3D 屏视频

设计前提: 相机可能歪、有反光、每次位置不同 → 用画面四角的品红标记自动求
单应矩阵, 把任意拍摄角度拉正到 1440×2560 面板坐标再取样。

用法:
    python3 analyze_obs.py RECORDING.mov [--out report_dir] [--scale 720]

输出:
    - 终端报告: 每段图样的一致性(色相/亮度离散度)、视点读数、判定建议
    - report_dir/seg_XX.png  每段一张代表帧(已拉正)
    - report_dir/report.json
"""
import argparse, json, os, subprocess, sys
import numpy as np

PANEL_W, PANEL_H = 1440, 2560
MARK_M, MARK_S = 10, 96                       # 与 PatternTest 的角标一致
MARK_CENTERS = [(MARK_M + MARK_S / 2, MARK_M + MARK_S / 2),
                (PANEL_W - MARK_M - MARK_S / 2, MARK_M + MARK_S / 2),
                (MARK_M + MARK_S / 2, PANEL_H - MARK_M - MARK_S / 2),
                (PANEL_W - MARK_M - MARK_S / 2, PANEL_H - MARK_M - MARK_S / 2)]


def probe_meta(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=width,height,nb_frames,r_frame_rate,duration",
                          "-of", "json", path], capture_output=True, text=True).stdout
    st = json.loads(out)["streams"][0]
    num, den = st["r_frame_rate"].split("/")
    fps = float(num) / float(den)
    return int(st["width"]), int(st["height"]), fps, st.get("duration")


def decode(path, width, height):
    """按宽度缩放解码为 uint8 RGB 帧序列 (逐帧流式返回)"""
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={width}:{height}",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    if p.stdout is None:
        raise RuntimeError("ffmpeg 起不来")
    frame_bytes = width * height * 3
    while True:
        buf = p.stdout.read(frame_bytes)
        if len(buf) < frame_bytes:
            break
        yield np.frombuffer(buf, np.uint8).reshape(height, width, 3)


def find_markers(img):
    """返回 4 个品红块质心 (左上,右上,左下,右下), 找不到给 None"""
    r, g, b = img[..., 0].astype(np.int16), img[..., 1].astype(np.int16), img[..., 2].astype(np.int16)
    mask = (r > 110) & (b > 110) & (g < 0.62 * np.minimum(r, b))
    if mask.sum() < 50:
        return None
    h, w = mask.shape
    pts = []
    for (y0, y1, x0, x1) in [(0, h // 2, 0, w // 2), (0, h // 2, w // 2, w),
                             (h // 2, h, 0, w // 2), (h // 2, h, w // 2, w)]:
        sub = mask[y0:y1, x0:x1]
        if sub.sum() < 8:
            return None
        ys, xs = np.nonzero(sub)
        pts.append((xs.mean() + x0, ys.mean() + y0))
    return pts


BARS_Y = [760 + k * (170 + 40) + 85 for k in range(6)]   # 视点二进制条的中心 y


def read_view_bits(img, H):
    """从 6 条二进制条读视点号; 读不出返回 (None, None)"""
    cols = warp_sample(img, H, [720] * 6, BARS_Y, rad=4)
    if np.isnan(cols).any():
        return None, None
    # 只有 6 条都落在"条"的两档亮度上才认, 否则这是别的图样
    vals = [float(c.mean()) for c in cols]
    if not all(min(abs(v - 70), abs(v - 250)) <= 14 for v in vals):
        return None, None
    bits = [1 if v > 150 else 0 for v in vals]
    view = int("".join(str(b) for b in bits), 2)
    return (view if view < 40 else None), bits


def homography(src, dst):
    """DLT: src(视频) -> dst(面板)"""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        A.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    _, _, vt = np.linalg.svd(np.array(A))
    H = vt[-1].reshape(3, 3)
    return H / H[2, 2]


def warp_sample(img, H, xs, ys, rad=3):
    """在面板坐标 (xs,ys) 处取样, 返回 (N,3) 中位色"""
    inv = np.linalg.inv(H)
    h, w = img.shape[:2]
    cols = []
    for x, y in zip(xs, ys):
        v = inv @ np.array([x, y, 1.0])
        vx, vy = v[0] / v[2], v[1] / v[2]
        ix, iy = int(round(vx)), int(round(vy))
        if ix < rad or iy < rad or ix >= w - rad or iy >= h - rad:
            cols.append([np.nan] * 3)
            continue
        patch = img[iy - rad:iy + rad + 1, ix - rad:ix + rad + 1].reshape(-1, 3)
        cols.append(np.median(patch, axis=0))
    return np.array(cols, float)


def hue_of(rgb):
    r, g, b = [c / 255.0 for c in rgb]
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d < 1e-6:
        return np.nan
    if mx == r:
        h = (60 * ((g - b) / d)) % 360
    elif mx == g:
        h = 60 * ((b - r) / d) + 120
    else:
        h = 60 * ((r - g) / d) + 240
    return h


def circ_std(hues):
    h = np.radians(np.array([x for x in hues if not np.isnan(x)]))
    if len(h) < 2:
        return np.nan
    return float(np.degrees(np.sqrt(-2 * np.log(max(1e-9, abs(np.exp(1j * h).mean())))))) 


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", default="report")
    ap.add_argument("--scale", type=int, default=720)
    ap.add_argument("--min-run", type=float, default=1.0, help="一段图样最短秒数")
    a = ap.parse_args()

    w, h, fps, dur = probe_meta(a.video)
    print(f"视频 {w}x{h} @ {fps:.2f}fps  {dur}s")

    os.makedirs(a.out, exist_ok=True)
    grid = [(x, y) for y in np.linspace(400, 2160, 5) for x in np.linspace(240, 1200, 5)]

    frames, metas, raw_frames = [], [], []
    H_last = None
    sw, sh = a.scale, int(round(h * a.scale / w))
    for i, img in enumerate(decode(a.video, sw, sh)):
        mk = find_markers(img)
        if mk is not None:
            H = homography(mk, MARK_CENTERS)
            H_last = H
        else:
            H = H_last
        if H is None:
            continue
        cols = warp_sample(img, H, [p[0] for p in grid], [p[1] for p in grid])
        resid = 0.0
        if mk is not None:
            for (mx, my), (px, py) in zip(mk, MARK_CENTERS):
                v = H @ np.array([mx, my, 1.0]); v /= v[2]
                resid = max(resid, float(np.hypot(v[0] - px, v[1] - py)))
        vid, vbits = read_view_bits(img, H)
        med = np.nanmedian(cols, axis=0)
        sat = float(np.max(med) - np.min(med))
        metas.append({"t": i / fps, "rgb": np.nan_to_num(med).tolist(),
                      "view": vid, "bits": vbits, "resid": round(resid, 1),
                      "spread": float(np.nanstd(cols, axis=0).mean()),
                      "sat": round(sat, 1),
                      "hue": hue_of(med) if sat >= 30 else np.nan,
                      "hue_spread": circ_std([hue_of(c) for c in cols if max(c) - min(c) >= 30]) if sat >= 30 else np.nan,
                      "lum": float(np.nanmean(med))})
        raw_frames.append(img)
        if len(metas) % 60 == 0:
            print(f"  ... {metas[-1]['t']:.1f}s  med=({med[0]:.0f},{med[1]:.0f},{med[2]:.0f})  spread={metas[-1]['spread']:.1f}")

    if not metas:
        print("!! 没找到品红角标 —— 画面里没有屏, 或角标被反光/过曝吃掉")
        sys.exit(1)

    # 分段: 相邻帧中位色距离突变处切段
    d = [0.0] + [float(np.linalg.norm(np.array(metas[i]["rgb"]) - np.array(metas[i - 1]["rgb"]))) for i in range(1, len(metas))]
    thr = max(12.0, float(np.percentile(d, 85)))
    segs, cur = [], 0
    for i in range(1, len(metas)):
        if d[i] > thr:
            segs.append((cur, i)); cur = i
    segs.append((cur, len(metas)))
    segs = [s for s in segs if (s[1] - s[0]) / fps >= a.min_run]

    report = []
    print(f"\n检出 {len(segs)} 段图样 (阈值 {thr:.0f})")
    for k, (s, e) in enumerate(segs):
        seg = metas[s:e]
        rgb = np.median(np.array([m["rgb"] for m in seg]), axis=0)
        spread = float(np.median([m["spread"] for m in seg]))
        hs = [m["hue_spread"] for m in seg if not np.isnan(m["hue_spread"])]
        lum_sd = float(np.std([m["lum"] for m in seg]))
        row = {"seg": k, "t0": round(seg[0]["t"], 2), "t1": round(seg[-1]["t"], 2),
               "rgb": [round(float(c), 1) for c in rgb],
               "hue": None if np.isnan(hue_of(rgb)) else round(float(hue_of(rgb)), 1),
               "空间离散_mean": round(spread, 1),
               "空间离散_色相_deg": round(float(np.nanmedian(hs)), 1) if hs else None,
               "时间亮度抖动": round(lum_sd, 1),
               "单应残差_px": round(float(np.median([m["resid"] for m in seg])), 1),
               "视点读数": sorted({m["view"] for m in seg if m["view"] is not None}),
               "色相漂移_deg": round(float(np.nanmax([m["hue"] for m in seg]) - np.nanmin([m["hue"] for m in seg])), 1)
                              if any(not np.isnan(m["hue"]) for m in seg) else None}
        report.append(row)
        print(f"  [{k}] {row['t0']:6.2f}s–{row['t1']:6.2f}s  RGB={row['rgb']}  色相={row['hue']}"
              f"  视点={row['视点读数']}  空间离散={row['空间离散_mean']:.1f}"
              f"  色相离散={row['空间离散_色相_deg']}  色相漂移={row['色相漂移_deg']}"
              f"  抖动={row['时间亮度抖动']}  角标残差={row['单应残差_px']}px")

        # 存代表帧(已拉正: 按 H 采样回 1440x2560 太大, 这里只存原视频帧)
        mid = (s + e) // 2
        idx = min(mid, len(raw_frames) - 1)
        out_png = os.path.join(a.out, f"seg_{k:02d}.png")
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", a.video, "-vf",
                        f"select=eq(n\\,{idx})", "-frames:v", "1", out_png], capture_output=True)

    # 视点读数: 若存在色相段, 用色相估计当前视点号
    print("\n判读提示:")
    for row in report:
        if row["色相漂移_deg"] is not None and row["空间离散_色相_deg"] is not None:
            if row["色相漂移_deg"] > 25 and row["空间离散_色相_deg"] < 40:
                print(f"  段{row['seg']}: 段内色相漂移 {row['色相漂移_deg']:.0f}° 且屏幕内色相统一"
                      f" → 视点确实随相机移动而切换(交错在工作)")
            elif row["空间离散_色相_deg"] >= 40:
                print(f"  段{row['seg']}: 屏内色相离散 {row['空间离散_色相_deg']:.0f}° 偏大"
                      f" → 该位置同时看到多个视点(串扰/相位差), 换 deviation 再试")
        if row["视点读数"]:
            print(f"  段{row['seg']}: 读到的视点号 {row['视点读数']}")
    with open(os.path.join(a.out, "report.json"), "w") as f:
        json.dump({"video": a.video, "segments": report}, f, ensure_ascii=False, indent=2)
    print(f"\n报告: {os.path.join(a.out, 'report.json')}")


if __name__ == "__main__":
    main()
