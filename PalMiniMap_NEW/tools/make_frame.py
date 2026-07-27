"""
Gera `icons/T_minimap_frame.png`: a moldura que faz o minimapa redondo ser
REDONDO.

O PROBLEMA
----------
O Slate so recorta RETANGULOS alinhados aos eixos, entao o disco do minimapa e
montado com N faixas horizontais recortadas (ver `buildBands` em
`Scripts/render.lua`). A uniao das faixas e uma escada, nao um circulo: em
240 px com 24 faixas o contorno erra +-4 px, e isso se ve. Espacamento otimo
das faixas nao ajuda (medido: ganha 0,1 px), e sub-pixel exigiria ~150 faixas -
cada faixa e uma zona de recorte do Slate, ou seja, uma draw call POR FRAME.

A SOLUCAO
---------
Nao adianta melhorar a escada; adianta ESCONDE-LA. Esta moldura tem a borda
interna desenhada em supersampling, entao ela e um circulo de verdade,
antialiasado. Desenhada por cima da junta:

  * o disco das faixas e construido um pouco MENOR que o widget (INSET), para
    nenhum pedaco de terreno passar do raio externo da moldura;
  * a faixa opaca (RIM) e mais larga que o erro das faixas, entao a escada
    inteira fica embaixo dela;
  * o que se ve como contorno passa a ser a borda interna da moldura, que e
    perfeita.

Fora do raio externo o PNG e transparente, entao o jogo continua aparecendo
alem do disco - que e a razao de nunca ter dado para simplesmente pintar os
cantos.

Os dois numeros abaixo TEM DE BATER com os de `Scripts/render.lua`; ele os
declara com o mesmo nome, e `tools/check_frame.py` verifica que a moldura
cobre o erro em todo o intervalo de tamanho do menu (120 a 480 px).

USO
    python tools/make_frame.py

Requer Pillow.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "icons" / "T_minimap_frame.png"

SIZE = 512                  # desenhada ate 480 px em jogo, entao ~1:1
SUPERSAMPLE = 4

# --- estes dois tem de bater com render.lua ---------------------------
RIM = 0.038                 # largura da faixa opaca, em fracao do diametro
INSET = 0.018               # quanto o disco das faixas encolhe

# Mesma paleta de `round_icons.py`, para a moldura combinar com os medalhoes.
BEZEL_RGBA = (18, 22, 30, 255)
HAIRLINE_RGBA = (255, 255, 255, 225)
HAIRLINE = 0.004            # espessura do fio branco interno
GLOW = 0.010                # brilho suave para fora, no lugar do anel do jogo


def ring(size: int, outer: float, inner: float) -> Image.Image:
    """Anel antialiasado: 255 entre os dois raios, 0 fora. Raios em fracao do
    lado. Desenhado grande e reduzido com Lanczos - e daqui que vem a borda
    lisa, e o motivo de nao dar para fazer isto em tempo real no Lua."""
    big = size * SUPERSAMPLE
    layer = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(layer)
    centre = big / 2
    for radius, fill in ((outer * big, 255), (inner * big, 0)):
        draw.ellipse((centre - radius, centre - radius,
                      centre + radius, centre + radius), fill=fill)
    return layer.resize((size, size), Image.LANCZOS)


def main() -> int:
    outer = 0.5
    inner = 0.5 - RIM

    bezel = ring(SIZE, outer, inner)
    hairline = ring(SIZE, inner + HAIRLINE, inner)

    # O brilho fica POR FORA da faixa opaca, onde nao ha terreno para lavar -
    # que era o defeito de esticar o anel do jogo por cima do disco inteiro.
    glow = ring(SIZE, outer, outer - GLOW)
    glow = glow.filter(ImageFilter.GaussianBlur(SIZE * GLOW * 0.6))
    glow = glow.point(lambda p: p * 90 // 255)

    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    layer = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    layer.putalpha(glow)
    frame = Image.alpha_composite(frame, layer)

    layer = Image.new("RGBA", (SIZE, SIZE), BEZEL_RGBA)
    layer.putalpha(ImageChops.darker(layer.getchannel("A"), bezel))
    frame = Image.alpha_composite(frame, layer)

    layer = Image.new("RGBA", (SIZE, SIZE), HAIRLINE_RGBA)
    layer.putalpha(ImageChops.darker(layer.getchannel("A"), hairline))
    frame = Image.alpha_composite(frame, layer)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    frame.save(OUT, "PNG", optimize=True)
    print(f"{OUT.relative_to(ROOT)}  {SIZE}x{SIZE}  "
          f"{OUT.stat().st_size / 1024:.0f} KB")
    print(f"  faixa opaca {RIM * 100:.1f}% do diametro, disco recuado "
          f"{INSET * 100:.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
