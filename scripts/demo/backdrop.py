import argparse
import math

from PIL import Image, ImageFilter

BASE = (9, 11, 30)
BLOBS = [
    (0.08, 0.20, 0.42, (24, 62, 168)),
    (0.22, 0.88, 0.40, (8, 132, 140)),
    (0.62, 0.10, 0.38, (92, 44, 178)),
    (0.95, 0.55, 0.36, (146, 40, 140)),
    (0.55, 0.95, 0.34, (30, 88, 170)),
    (0.42, 0.48, 0.30, (52, 36, 120)),
]


def render(width, height):
    small_w, small_h = 160, round(160 * height / width)
    image = Image.new("RGB", (small_w, small_h))
    pixels = image.load()
    aspect = width / height
    for y in range(small_h):
        for x in range(small_w):
            u, v = x / (small_w - 1), y / (small_h - 1)
            color = list(BASE)
            for bx, by, radius, tint in BLOBS:
                d = math.hypot((u - bx) * aspect, v - by) / radius
                weight = math.exp(-d * d * 1.6)
                for i in range(3):
                    color[i] += (tint[i] - BASE[i]) * weight * 0.85
            pixels[x, y] = tuple(min(255, round(c)) for c in color)
    image = image.filter(ImageFilter.GaussianBlur(3))
    return image.resize((width, height), Image.BICUBIC).filter(ImageFilter.GaussianBlur(6))


def main():
    parser = argparse.ArgumentParser(description="Write the dark gradient backdrop for README screenshots")
    parser.add_argument("out")
    parser.add_argument("--size", default="2880x1800")
    args = parser.parse_args()
    width, height = (int(n) for n in args.size.split("x"))
    render(width, height).save(args.out)


if __name__ == "__main__":
    main()
