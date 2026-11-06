# Draws the app icon (1024px) and writes Resources/AppIcon.icns via iconutil.
import os, subprocess, math
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# gradient background: deep plum to warm gold
bg = Image.new("RGBA", (S, S))
px = bg.load()
for y in range(S):
    for x in range(S):
        t = (x * 0.35 + y * 0.65) / S
        r = int(58 + (224 - 58) * t); g = int(22 + (160 - 22) * t); b = int(92 + (60 - 92) * t)
        px[x, y] = (r, g, b, 255)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([90, 90, S - 90, S - 90], radius=190, fill=255)
img.paste(bg, (0, 0), mask)
d = ImageDraw.Draw(img)
# waveform bars
cx, cy = S // 2, S // 2 + 40
heights = [120, 220, 330, 430, 330, 470, 300, 210, 120]
bw, gap = 46, 26
total = len(heights) * bw + (len(heights) - 1) * gap
x0 = cx - total // 2
for i, h in enumerate(heights):
    x = x0 + i * (bw + gap)
    d.rounded_rectangle([x, cy - h // 2, x + bw, cy + h // 2], radius=bw // 2, fill=(255, 255, 255, 240))
# small cross above
d.rounded_rectangle([cx - 14, 170, cx + 14, 300], radius=8, fill=(255, 244, 214, 255))
d.rounded_rectangle([cx - 50, 205, cx + 50, 233], radius=8, fill=(255, 244, 214, 255))
os.makedirs("build/AppIcon.iconset", exist_ok=True)
for size in [16, 32, 64, 128, 256, 512]:
    img.resize((size, size), Image.LANCZOS).save(f"build/AppIcon.iconset/icon_{size}x{size}.png")
    img.resize((size * 2, size * 2), Image.LANCZOS).save(f"build/AppIcon.iconset/icon_{size}x{size}@2x.png")
subprocess.run(["iconutil", "-c", "icns", "build/AppIcon.iconset", "-o", "Resources/AppIcon.icns"], check=True)
img.resize((256, 256), Image.LANCZOS).save("build/icon-preview.png")
print("icon ok")
