from PIL import Image


def dhash(image):
    small = image.convert("RGB").resize((9, 8), Image.Resampling.BICUBIC)
    px = small.load()
    bits = 0
    for y in range(8):
        row = [(299 * r + 587 * g + 114 * b) // 1000 for r, g, b in (px[x, y] for x in range(9))]
        for x in range(8):
            bits = (bits << 1) | (row[x] > row[x + 1])
    return f"{bits:016x}"
