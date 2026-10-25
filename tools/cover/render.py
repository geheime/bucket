"""Render tools/cover/cover.html frame by frame (deterministic window.setT) to PNGs.
Usage: python3 render.py <url> <out_dir> [fps=20] [loop_ms=7000]"""
import sys, os
from playwright.sync_api import sync_playwright
url, out = sys.argv[1], sys.argv[2]
fps = int(sys.argv[3]) if len(sys.argv) > 3 else 20
loop = int(sys.argv[4]) if len(sys.argv) > 4 else 7000
os.makedirs(out, exist_ok=True)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={'width': 1280, 'height': 640}, device_scale_factor=1, color_scheme='light')
    pg.goto(url, wait_until='networkidle')
    pg.wait_for_function('document.fonts.ready.then(() => true)')
    pg.wait_for_function("document.querySelector('.icon').complete")
    n = round(loop * fps / 1000)
    for i in range(n):
        pg.evaluate(f'setT({i * 1000 / fps})')
        pg.locator('#stage').screenshot(path=f'{out}/f{i:04d}.png')
    b.close()
print(n, 'frames')
