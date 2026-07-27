"""
Transforma os retratos de icons/ em medalhoes redondos: disco escuro atras da
arte, recorte circular e um anel branco fino na borda.

POR QUE ISTO EXISTE
-------------------
Os retratos saem do pak como quadrados 64x64 e no minimapa sao desenhados
soltos sobre o mapa. So recortar em circulo nao resolve: de 411 retratos, 268
vem com o fundo TRANSPARENTE - o Pal aparece flutuando, sem forma nenhuma, e o
recorte nao corta nada porque nao ha nada nos cantos. E preciso desenhar o
circulo, nao so recortar.

Entao cada icone vira tres camadas:

    1. DISCO   - circulo inscrito preenchido com DISC_RGBA. Translucido, entao
                 o mapa ainda aparece um pouco por tras do Pal.
    2. ARTE    - a textura original com o alfa cortado no mesmo circulo.
    3. ANEL    - contorno de RING_WIDTH px em branco, que e o que faz o
                 circulo se ler como circulo mesmo nos retratos que ja tinham
                 fundo claro proprio.

Tudo isso e feito NA EXTRACAO, nao em tempo real: o Lua continua desenhando um
quad com uma textura e nao sabe de nada disso. Ver `Scripts/assets.lua`.

BORDA
-----
Os circulos (mascara e anel) sao desenhados em SUPERSAMPLE vezes o tamanho e
reduzidos com Lanczos. E isso que da a borda suave; uma mascara desenhada
direto em 64x64 sai serrilhada, e serrilhado num icone de 18 px na tela
cintila quando ele se mexe.

O alfa do recorte e o MENOR entre o que ja existia e a mascara, nao a mascara
sozinha - a arte ja tem transparencia propria, e sobrescrever devolveria pixel
opaco onde o jogo queria vazio.

RODAR DUAS VEZES
----------------
Cada PNG gravado leva um chunk de texto `palminimap_round`. Quem ja tem a
marca e pulado, entao chamar isto depois de todo extract_icons.py e barato e
nao empilha disco sobre disco. `--force` reprocessa assim mesmo.

USO
    python tools/round_icons.py             # todos os retratos
    python tools/round_icons.py --all       # inclui compasso e artes de mapa
    python tools/round_icons.py --force     # ignora a marca

Os icones de compasso ficam de fora por padrao: sao simbolos que ja vem com
fundo transparente e ocupam o quadrado inteiro, entao o medalhao so cortaria
pedaco deles.

Retrato aqui e Pal E humano. Os retratos de NPC (`T_BOSS_NPC_*`, `T_NPC_*`)
nao terminam em `_icon_normal` - o jogo nao usa essa convencao para humano -
entao precisam de padrao proprio, senao ficariam quadrados no meio de
medalhoes.

Requer Pillow.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "icons"

SUPERSAMPLE = 8
DISC_RGBA = (18, 22, 30, 190)
RING_RGBA = (255, 255, 255, 235)
RING_WIDTH = 2.0            # em pixels do icone final (64x64)

MARK = "palminimap_round"
MARK_VALUE = "circle-v1"


def _circle(size: tuple[int, int], width: float | None) -> Image.Image:
    """Circulo inscrito em L, antialiasado por supersampling.

    `width` None preenche; um numero desenha so o contorno, com a espessura
    para DENTRO da borda para o anel nao ser cortado pela propria mascara.
    """
    image_width, image_height = size
    big = Image.new("L", (image_width * SUPERSAMPLE, image_height * SUPERSAMPLE), 0)
    diameter = min(big.size)
    left = (big.width - diameter) // 2
    top = (big.height - diameter) // 2
    box = (left, top, left + diameter - 1, top + diameter - 1)

    draw = ImageDraw.Draw(big)
    if width is None:
        draw.ellipse(box, fill=255)
    else:
        thickness = max(1, round(width * SUPERSAMPLE))
        inset = thickness // 2
        draw.ellipse((box[0] + inset, box[1] + inset,
                      box[2] - inset, box[3] - inset),
                     outline=255, width=thickness)
    return big.resize(size, Image.LANCZOS)


def masks_for(size: tuple[int, int]) -> tuple[Image.Image, Image.Image]:
    return _circle(size, None), _circle(size, RING_WIDTH)


def medallion(art: Image.Image, disc_mask: Image.Image,
              ring_mask: Image.Image) -> Image.Image:
    size = art.size

    art = art.copy()
    art.putalpha(ImageChops.darker(art.getchannel("A"), disc_mask))

    disc = Image.new("RGBA", size, DISC_RGBA)
    disc.putalpha(ImageChops.darker(disc.getchannel("A"), disc_mask))

    ring = Image.new("RGBA", size, RING_RGBA)
    ring.putalpha(ImageChops.darker(ring.getchannel("A"), ring_mask))

    return Image.alpha_composite(Image.alpha_composite(disc, art), ring)


def round_icon(path: Path, cache: dict, force: bool) -> bool:
    image = Image.open(path)
    image.load()
    if not force and image.info.get(MARK) == MARK_VALUE:
        return False

    art = image.convert("RGBA")
    if art.size not in cache:
        cache[art.size] = masks_for(art.size)
    disc_mask, ring_mask = cache[art.size]

    info = PngImagePlugin.PngInfo()
    info.add_text(MARK, MARK_VALUE)
    # optimize=True porque isto roda uma vez e os arquivos vao no zip do mod.
    medallion(art, disc_mask, ring_mask).save(path, "PNG", optimize=True,
                                              pnginfo=info)
    return True


PORTRAITS = ("*_icon_normal.png", "T_BOSS_NPC_*.png", "T_NPC_*.png")


def main(argv: list[str]) -> int:
    patterns = ("*.png",) if "--all" in argv else PORTRAITS
    force = "--force" in argv
    files = sorted({path for pattern in patterns for path in ICONS.glob(pattern)})
    if not files:
        print(f"nenhum PNG em {ICONS}")
        return 1

    cache: dict[tuple[int, int], tuple[Image.Image, Image.Image]] = {}
    changed = 0
    for index, path in enumerate(files, 1):
        if round_icon(path, cache, force):
            changed += 1
        print(f"  {index}/{len(files)}", end="\r")

    print(" " * 30, end="\r")
    total = sum(path.stat().st_size for path in files)
    skipped = len(files) - changed
    print(f"{changed} de {len(files)} PNG viraram medalhao"
          + (f" ({skipped} ja tinham a marca)" if skipped else "")
          + f" - {total / 1024 / 1024:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
