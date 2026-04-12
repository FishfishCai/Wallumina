#!/usr/bin/env python3
"""Generate app icon for VideoWallpaper."""
import subprocess, os, tempfile, math
from PIL import Image, ImageDraw

def create_icon_png(size, path):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = int(size * 0.08)
    radius = int(size * 0.18)

    # Rounded rectangle background - dark blue-purple gradient
    for y in range(size):
        for x in range(size):
            # Check rounded rect bounds
            in_x = margin <= x < size - margin
            in_y = margin <= y < size - margin
            if not (in_x and in_y):
                continue
            # Corner check
            corners = [
                (margin + radius, margin + radius, x < margin + radius, y < margin + radius),
                (size - margin - radius, margin + radius, x >= size - margin - radius, y < margin + radius),
                (margin + radius, size - margin - radius, x < margin + radius, y >= size - margin - radius),
                (size - margin - radius, size - margin - radius, x >= size - margin - radius, y >= size - margin - radius),
            ]
            inside = True
            for cx, cy, cond_x, cond_y in corners:
                if cond_x and cond_y:
                    if (x - cx) ** 2 + (y - cy) ** 2 > radius ** 2:
                        inside = False
                        break
            if inside:
                t = (y - margin) / max(size - 2 * margin, 1)
                r = int(18 + 22 * t)
                g = int(12 + 8 * t)
                b = int(45 + 35 * (1 - t))
                img.putpixel((x, y), (r, g, b, 255))

    # Play triangle - light blue
    cx = size * 0.52
    cy = size * 0.48
    tri_h = size * 0.35
    tri_w = tri_h * 0.85
    points = [
        (cx - tri_w * 0.35, cy - tri_h * 0.5),
        (cx + tri_w * 0.65, cy),
        (cx - tri_w * 0.35, cy + tri_h * 0.5),
    ]
    draw.polygon(points, fill=(100, 190, 255, 240))

    # Small globe hint bottom-right
    gcx = size * 0.73
    gcy = size * 0.73
    gr = size * 0.11
    draw.ellipse([gcx - gr, gcy - gr, gcx + gr, gcy + gr], outline=(80, 160, 220, 160), width=max(1, size // 128))
    draw.line([gcx - gr, gcy, gcx + gr, gcy], fill=(80, 160, 220, 120), width=max(1, size // 128))
    # Vertical ellipse
    for angle in range(0, 360, 2):
        rad = math.radians(angle)
        ex = gcx + gr * 0.4 * math.cos(rad)
        ey = gcy + gr * math.sin(rad)
        draw.point((ex, ey), fill=(80, 160, 220, 120))

    img.save(path)

# macOS iconset requires exact naming convention
size_map = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

iconset_dir = tempfile.mkdtemp() + "/AppIcon.iconset"
os.makedirs(iconset_dir)

for name, size in size_map.items():
    create_icon_png(size, os.path.join(iconset_dir, name))
    print(f"  Generated {name} ({size}x{size})")

project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
icns_path = os.path.join(project_dir, "VideoWallpaper.app", "Contents", "Resources", "AppIcon.icns")
subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True)
print(f"Icon created: {icns_path}")
