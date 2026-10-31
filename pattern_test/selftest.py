#!/usr/bin/env python3
"""selftest.py — 不接屏也能验证 analyze_obs 的两件事:
1. 角标检测 + 单应还原 (任意透视/旋转)
2. 视点二进制条的读数 (给一张"单视点"画面, 应读出该视点号)

用法: python3 selftest.py
"""
import subprocess
import numpy as np
import analyze_obs as A

PANEL_W, PANEL_H = A.PANEL_W, A.PANEL_H


def panel_homography(vw=720, vh=1280):
    src = np.array([[0, 0], [PANEL_W, 0], [0, PANEL_H], [PANEL_W, PANEL_H]], float)
    dst = np.array([[46, 38], [676, 64], [24, 1244], [700, 1216]], float)
    rows = []
    for (x, y), (u, v) in zip(src, dst):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(rows))
    H = vt[-1].reshape(3, 3)
    return H / H[2, 2]


def bars_panel(view, n=6):
    """1440×2560 面板: 某视点的 6 条二进制条 + 四角品红标记"""
    img = np.full((PANEL_H, PANEL_W, 3), 40, np.uint8)
    for k in range(n):
        y0 = 760 + k * (170 + 40)
        on = (view >> (n - 1 - k)) & 1
        img[y0:y0 + 170, 120:PANEL_W - 120] = 250 if on else 70
    m, s = A.MARK_M, A.MARK_S
    for (x, y) in [(m, m), (PANEL_W - s - m, m), (m, PANEL_H - s - m), (PANEL_W - s - m, PANEL_H - s - m)]:
        img[y:y + s, x:x + s] = (255, 0, 255)
    return img


def warp_to_camera(panel, H, vw=720, vh=1280):
    Hi = np.linalg.inv(H)
    yy, xx = np.mgrid[0:vh, 0:vw]
    p = np.stack([xx.ravel(), yy.ravel(), np.ones(vw * vh)], 0)
    q = Hi @ p
    q /= q[2]
    u = np.clip(q[0], 0, PANEL_W - 1.001).astype(int)
    v = np.clip(q[1], 0, PANEL_H - 1.001).astype(int)
    return panel[v, u].reshape(vh, vw, 3)


def main():
    H = panel_homography()
    ok_geo = ok_bits = True
    for view in (0, 17, 23, 39):
        cam = warp_to_camera(bars_panel(view), H)
        mk = A.find_markers(cam)
        if mk is None:
            print(f"view {view}: 角标未检出 ❌"); ok_geo = False; continue
        Hh = A.homography(mk, A.MARK_CENTERS)
        resid = max(float(np.hypot(*( (Hh @ np.array([mx, my, 1.0]))[:2] / (Hh @ np.array([mx, my, 1.0]))[2] - np.array(c) )))
                    for (mx, my), c in zip(mk, A.MARK_CENTERS))
        got, bits = A.read_view_bits(cam, Hh)
        flag = "✅" if got == view else "❌"
        print(f"view {view:2d}: 角标残差 {resid:5.1f}px  位数 {bits}  读数 {got} {flag}")
        ok_bits &= (got == view)
    print("\n结果:", "全部通过" if (ok_geo and ok_bits) else "有失败项")
    return 0 if (ok_geo and ok_bits) else 1


if __name__ == "__main__":
    raise SystemExit(main())
