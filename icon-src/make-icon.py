#!/usr/bin/env python3
"""Build the WA Reader for Muse app icon (1024x1024 PNG).

Design (Eric, Nov 16, 2026): the WhatsApp icon's color and shape — bright
green rounded square, white speech-bubble outline with the tail — but with
M's Muse avatar (plush moose in a lab coat) inside the bubble instead of
the phone handset.

Run: python3 make-icon.py   (writes icon-1024.png beside this script)
"""
from PIL import Image, ImageDraw

S = 4  # supersample factor for smooth edges
W = 1024 * S

# --- WhatsApp green gradient background (rounded square, transparent corners)
def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

top = (43, 224, 122)     # #2BE07A
bottom = (30, 190, 93)   # #1EBE5D
bg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
bd = ImageDraw.Draw(bg)
for y in range(W):
    bd.line([(0, y), (W, y)], fill=lerp(top, bottom, y / W) + (255,))
mask = Image.new("L", (W, W), 0)
md = ImageDraw.Draw(mask)
inset = int(0 * S)
radius = int(225 * S)
md.rounded_rectangle([inset, inset, W - inset, W - inset], radius=radius, fill=255)
icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)

d = ImageDraw.Draw(icon)

# --- Speech bubble: white outline ring (ellipse + tail), green inside.
cx, cy, r = int(512 * S), int(488 * S), int(298 * S)
tail = [(int(352 * S), int(726 * S)), (int(318 * S), int(838 * S)), (int(452 * S), int(756 * S))]
stroke = int(46 * S)

# outer (white)
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 255))
d.polygon(tail, fill=(255, 255, 255, 255))
# inner (green) — leaves a white ring; gradient approximated with mid green
inner = r - stroke
mid = lerp(top, bottom, 0.48) + (255,)
d.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=mid)
tail_in = [(int(366 * S), int(716 * S)), (int(344 * S), int(800 * S)), (int(446 * S), int(740 * S))]
d.polygon(tail_in, fill=mid)

icon = icon.resize((1024, 1024), Image.LANCZOS)

# --- Moose avatar cut-out inside the bubble, where the phone would be.
moose = Image.open("moose-cutout.png").convert("RGBA")
target_h = 500
scale = target_h / moose.size[1]
target_w = int(moose.size[0] * scale)
moose = moose.resize((target_w, target_h), Image.LANCZOS)
x = (1024 - target_w) // 2
y = 488 - target_h // 2 - 6
icon.alpha_composite(moose, (x, y))

# Touch-up: the avatar photo has a genuine background concavity where the
# coat's collar flap meets the body; on green it reads as a notch. Fill that
# one small spot with coat white (feathered, kept inside the coat outline).
from PIL import ImageFilter
patch = Image.new("RGBA", icon.size, (0, 0, 0, 0))
pd = ImageDraw.Draw(patch)
pd.ellipse([586, 470, 616, 512], fill=(250, 250, 250, 255))
patch = patch.filter(ImageFilter.GaussianBlur(3))
icon.alpha_composite(patch)

icon.save("icon-1024.png")
print("saved icon-1024.png; moose at", (x, y), "size", (target_w, target_h))
