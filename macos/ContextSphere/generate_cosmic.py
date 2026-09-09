#!/usr/bin/env python3
"""Generate cosmic backdrop with subtle starfield for ContextSphere."""
from PIL import Image, ImageDraw
import random

# Dimensions (macOS typical retina display consideration)
WIDTH = 3840
HEIGHT = 2160

# Create base image - very dark space
img = Image.new('RGB', (WIDTH, HEIGHT), color=(7, 8, 12))
draw = ImageDraw.Draw(img)

# Generate subtle stars with emphasis on dark central region
random.seed(42)  # Reproducible

def star_density(x, y):
    """Less dense near center, more at edges."""
    center_x, center_y = WIDTH / 2, HEIGHT / 2
    dist = ((x - center_x) ** 2 + (y - center_y) ** 2) ** 0.5
    max_dist = (center_x ** 2 + center_y ** 2) ** 0.5
    return dist / max_dist  # 0 at center, 1 at corners

# Place ~2000 subtle stars
for _ in range(2000):
    x = random.randint(0, WIDTH - 1)
    y = random.randint(0, HEIGHT - 1)

    density = star_density(x, y)

    # Skip most stars near center (keep it dark)
    if density < 0.4 and random.random() > 0.1:
        continue

    # Star brightness (very subtle, mostly dim)
    brightness = random.choices(
        [25, 35, 45, 60, 80],  # RGB values (very dim to slightly brighter)
        weights=[50, 30, 15, 4, 1]  # Heavily weighted toward dim
    )[0]

    # Star size (mostly single pixels, few slightly larger)
    size = random.choices([1, 2], weights=[90, 10])[0]

    color = (brightness, brightness, brightness + random.randint(0, 10))

    if size == 1:
        draw.point((x, y), fill=color)
    else:
        draw.ellipse([x, y, x + size, y + size], fill=color)

# Add very faint nebula-like gradient for depth (barely visible)
overlay = Image.new('RGB', (WIDTH, HEIGHT), color=(0, 0, 0))
overlay_draw = ImageDraw.Draw(overlay)

for i in range(10):
    x = random.randint(0, WIDTH)
    y = random.randint(0, HEIGHT)
    radius = random.randint(300, 800)

    # Extremely faint purple/blue tint
    color = random.choice([
        (5, 3, 8),
        (3, 4, 9),
        (4, 5, 10)
    ])

    overlay_draw.ellipse(
        [x - radius, y - radius, x + radius, y + radius],
        fill=color
    )

# Blend faint overlay
img = Image.blend(img, overlay, alpha=0.15)

# Save
output_path = '/Users/srivenkat/Ominrouter/chronodesk/macos/ContextSphere/Resources/Assets/cosmic-backdrop.png'
img.save(output_path, 'PNG', optimize=True)
print(f"Generated: {output_path}")
print(f"Dimensions: {WIDTH}x{HEIGHT}")
print(f"File size: {Image.open(output_path).size}")
