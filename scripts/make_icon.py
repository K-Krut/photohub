import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 2


def rounded(size, radius, fill):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle((0, 0, size - 1, size - 1), radius, fill=fill)
    return img


def card(w, h, colors):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, w - 1, h - 1), 56, fill=(255, 255, 255, 255))
    m = 34
    sky, hill, sun = colors
    d.rounded_rectangle((m, m, w - m - 1, h - m - 1), 30, fill=sky)
    d.ellipse((w * 0.62, h * 0.2, w * 0.62 + 110, h * 0.2 + 110), fill=sun)
    d.polygon([(m, h - m), (w * 0.38, h * 0.42), (w * 0.62, h * 0.7), (w * 0.78, h * 0.52), (w - m, h * 0.78), (w - m, h - m)], fill=hill)
    return img


def main(out):
    s = SIZE * SCALE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bg = Image.new("RGBA", (s, s))
    px = bg.load()
    for y in range(s):
        t = y / s
        row = (int(46 + 30 * t), int(52 + 60 * t), int(110 + 90 * t), 255)
        for x in range(s):
            px[x, y] = row
    inset = int(s * 0.098)
    body = s - 2 * inset
    mask = rounded(body, int(body * 0.225), (255, 255, 255, 255))
    canvas.paste(bg.crop((inset, inset, s - inset, s - inset)), (inset, inset), mask)
    specs = [(-13, (-150, 60), ((250, 190, 120, 255), (190, 110, 80, 255), (255, 236, 200, 255))),
             (9, (150, 40), ((150, 200, 170, 255), (70, 130, 110, 255), (240, 250, 230, 255))),
             (-2, (0, -10), ((140, 190, 250, 255), (60, 100, 180, 255), (255, 220, 120, 255)))]
    for angle, (dx, dy), colors in specs:
        c = card(int(s * 0.44), int(s * 0.36), colors).rotate(angle, expand=True, resample=Image.BICUBIC)
        shadow = Image.new("RGBA", c.size, (0, 0, 0, 0))
        shadow.paste((0, 0, 0, 110), mask=c.split()[3])
        shadow = shadow.filter(ImageFilter.GaussianBlur(24))
        pos = ((s - c.width) // 2 + dx * SCALE // 1, (s - c.height) // 2 + dy * SCALE // 1)
        canvas.alpha_composite(shadow, (pos[0], pos[1] + 22))
        canvas.alpha_composite(c, pos)
    icon = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    tmp = Path(tempfile.mkdtemp()) / "AppIcon.iconset"
    tmp.mkdir()
    for base in (16, 32, 128, 256, 512):
        icon.resize((base, base), Image.LANCZOS).save(tmp / f"icon_{base}x{base}.png")
        icon.resize((base * 2, base * 2), Image.LANCZOS).save(tmp / f"icon_{base}x{base}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(tmp), "-o", out], check=True)
    icon.save(Path(out).with_suffix(".png"))


if __name__ == "__main__":
    main(sys.argv[1])
