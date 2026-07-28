"""
Gera `icons/T_minimap_note.png` - o marcador de NOTA do minimapa.

POR QUE ISTO EXISTE
-------------------
Todos os outros marcadores usam arte do proprio jogo. Nota e a unica excecao,
e nao por preguica: O JOGO NAO TEM NENHUM GLIFO DE DOCUMENTO. Procurado em

    T_icon_compass_*        (inclusive os 17 numerados, que nao tem nome
                             descritivo e por isso escapam de busca por nome)
    T_icon_Compass_Quest_*  (com C maiusculo)
    T_icon_ItemCategory_*
    T_itemicon_*            note|memo|paper|book|journal|document|log
                            map|letter|scroll|blueprint|schematic|parchment

O mais proximo eram o livro de tecnologia e o mapa do tesouro - dois itens
DIFERENTES, e ambos ilegiveis a 18px (o livro e verde sobre grama verde; o
pergaminho vira um risco bege).

Ate a 2.2.16 a nota usava `T_icon_compass_ClearCheck`, o mesmo check generico
da efigie e da fruta.

CONTORNO ESCURO, NAO SO BRANCO
------------------------------
Os glifos brancos da bussola do jogo somem sobre neve - medido a 18px sobre
grama, neve e deserto. Os que sobrevivem (o ClearCheck, por exemplo) tem
contorno escuro. Este tem tambem.

    python tools/make_note_icon.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "icons" / "T_minimap_note.png"

SIZE = 64          # o mesmo tamanho dos outros icones ja reduzidos
SS = 8             # supersampling: as bordas diagonais precisam disso

PAPER = (255, 255, 255, 255)
INK = (24, 28, 36, 255)          # o mesmo tom escuro do contorno do ClearCheck
LINE = (120, 132, 150, 255)      # as linhas de texto

OUTLINE = 0.055                  # espessura do contorno, fracao do lado


def build() -> Image.Image:
    s = SIZE * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Uma pagina com o canto dobrado. Retrato, porque a 18px uma silhueta
    # vertical se distingue do losango do ClearCheck e do circulo do ovo.
    m = int(s * 0.16)             # margem
    fold = int(s * 0.26)          # tamanho da dobra
    left, top, right, bottom = m, int(s * 0.10), s - m, s - int(s * 0.10)

    page = [
        (left, top),
        (right - fold, top),
        (right, top + fold),
        (right, bottom),
        (left, bottom),
    ]
    ow = max(1, int(s * OUTLINE))
    d.polygon(page, fill=PAPER, outline=INK, width=ow)

    # a dobra do canto, para nao virar so um retangulo
    d.line([(right - fold, top), (right - fold, top + fold), (right, top + fold)],
           fill=INK, width=ow)

    # tres linhas de texto: o que faz a pagina ler como "algo escrito"
    tl, tr = left + int(s * 0.10), right - int(s * 0.10)
    lw = max(1, int(s * 0.045))
    for i, frac in enumerate((0.42, 0.56, 0.70)):
        y = int(top + (bottom - top) * frac)
        end = tr if i < 2 else tl + int((tr - tl) * 0.6)   # a ultima e curta
        d.line([(tl, y), (end, y)], fill=LINE, width=lw)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    # sombra suave por baixo, como a arte de bussola do jogo tem
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (0, 0), img.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(SIZE * 0.03))
    return Image.alpha_composite(shadow, img)


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    build().save(OUT)
    print(f"{OUT.relative_to(ROOT)} gravado ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
