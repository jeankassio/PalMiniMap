"""
Verifica que `icons/T_minimap_frame.png` realmente esconde a escada das faixas,
em TODO o intervalo de tamanho que o menu permite (120 a 480 px).

Isto existe porque o acerto e geometrico e silencioso: se a faixa opaca ficar
estreita demais para o erro das faixas, ninguem recebe um erro - so aparece um
degrauzinho de terreno na borda, em alguns tamanhos e nao em outros. Entao a
geometria de `buildBands` e reproduzida aqui e medida.

    python tools/check_frame.py            # so os numeros
    python tools/check_frame.py --render    # grava build/frame_check.png

O `--render` monta a uniao das faixas com a moldura por cima, do jeito que o
jogo desenha, para dar para OLHAR o resultado e nao so ler a conta.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_frame import INSET, RIM  # noqa: E402

SIZES = (120, 160, 200, 240, 300, 360, 420, 480)


def band_count(size: int) -> int:
    """Copia de `bandCount` em render.lua."""
    n = math.floor(size * 0.10 + 0.5)
    return max(24, min(36, n))


def bands(size: int) -> list[tuple[float, float, float]]:
    """(x, y, largura) de cada faixa, em coordenadas do widget - a mesma
    conta de `buildBands`, com o recuo do disco."""
    n = band_count(size)
    R = size * 0.5
    r = R - INSET * size                  # raio do disco das faixas
    out = []
    for k in range(n):
        t0, t1 = k / n * math.pi, (k + 1) / n * math.pi
        y0 = R - r * math.cos(t0)
        y1 = R - r * math.cos(t1)
        w = r * math.sin((t0 + t1) * 0.5)
        if w > 0.5 and y1 - y0 > 0.5:
            out.append((R - w, y0, w * 2.0, y1 - y0))
    return out


def extremes(size: int) -> tuple[float, float]:
    """Raio minimo e maximo em que o terreno aparece, em px."""
    R = size * 0.5
    lo, hi = R, 0.0
    for x, y, w, h in bands(size):
        for cx in (x, x + w):
            for cy in (y, y + h):
                d = math.hypot(cx - R, cy - R)
                hi = max(hi, d)
        # o ponto mais PROXIMO do centro na borda externa da faixa e o que
        # deixa buraco: e o canto, mas so o lado onde a faixa e mais estreita
        # que o circulo
        for cy in (y, y + h):
            lo = min(lo, math.hypot(x + w - R, cy - R))
    return lo, hi


def main() -> int:
    R_out = 0.5
    R_in = 0.5 - RIM
    ok = True
    print(f"moldura: faixa opaca de {R_in * 100:.1f}% a {R_out * 100:.1f}% "
          f"do diametro, disco recuado {INSET * 100:.1f}%\n")
    print(f"{'tamanho':>8} {'faixas':>7} {'terreno min':>12} {'terreno max':>12}"
          f" {'folga dentro':>13} {'folga fora':>11}")
    for size in SIZES:
        lo, hi = extremes(size)
        inner_px, outer_px = R_in * size, R_out * size
        # O terreno tem de ALCANCAR a borda interna em todo o contorno (senao
        # sobra um vao entre o mapa e a moldura) e nao PASSAR da externa
        # (senao sobra um degrau de terreno para fora dela).
        slack_in = lo - inner_px
        slack_out = outer_px - hi
        good = slack_in >= 0 and slack_out >= 0
        ok = ok and good
        print(f"{size:>8} {band_count(size):>7} {lo:>11.1f}px {hi:>11.1f}px"
              f" {slack_in:>12.1f}px {slack_out:>10.1f}px"
              f"{'' if good else '   <-- FALHA'}")

    print("\n" + ("moldura cobre a escada em todos os tamanhos"
                  if ok else "MOLDURA INSUFICIENTE - aumente RIM em make_frame.py"))

    if "--render" in sys.argv:
        out = ROOT / "build" / "frame_check.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        frame_png = Image.open(ROOT / "icons" / "T_minimap_frame.png").convert("RGBA")
        tiles = []
        for size in (160, 240, 360):
            # xadrez, para dar para ver o que e transparente
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            draw = ImageDraw.Draw(canvas)
            for gy in range(0, size, 16):
                for gx in range(0, size, 16):
                    if (gx // 16 + gy // 16) % 2 == 0:
                        draw.rectangle((gx, gy, gx + 15, gy + 15),
                                       fill=(210, 60, 60, 255))
            terrain = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            td = ImageDraw.Draw(terrain)
            for x, y, w, h in bands(size):
                td.rectangle((round(x), round(y),
                              round(x + w) - 1, max(round(y), round(y + h) - 1)),
                             fill=(120, 170, 110, 255))
            canvas = Image.alpha_composite(canvas, terrain)
            canvas = Image.alpha_composite(
                canvas, frame_png.resize((size, size), Image.LANCZOS))
            tiles.append(canvas)
        sheet = Image.new("RGBA", (sum(t.width for t in tiles) + 40,
                                   max(t.height for t in tiles)), (0, 0, 0, 255))
        x = 0
        for t in tiles:
            sheet.alpha_composite(t, (x, 0))
            x += t.width + 20
        sheet.convert("RGB").save(out)
        print(f"\n{out.relative_to(ROOT)} - vermelho = o jogo aparecendo por tras")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
