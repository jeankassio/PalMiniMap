"""
Monta `bg.png`: uma imagem de exemplo do minimapa, para usar como fundo de
thumbnail.

ISTO NAO E UMA CAPTURA DE TELA. E uma composicao feita com as MESMAS artes e
as MESMAS proporcoes que o mod usa em jogo:

  * o terreno e um recorte do proprio `T_WorldMap` do jogo, na escala certa -
    o mod mostra 62 texels de um mapa de 4096 a cada 240 px de minimapa, o que
    da 124 texels do arquivo de 8192 que existe no pak;
  * os icones sao os PNG de `icons/`, ja com o estilo de medalhao aplicado;
  * os tamanhos saem de `cfg.iconSize` (18 em 240 px), as cores de `TINT` em
    `Scripts/sources.lua` e o fundo de `BACKDROP` em `Scripts/render.lua`.

Ou seja: o que aparece aqui e o que aparece no jogo, so que maior e sem o
resto da tela em volta.

USO
    python tools/make_thumbnail_bg.py

Requer Pillow, repak.exe e o .pak do jogo (o T_WorldMap nao vai junto com o
mod - sao 33 MB de textura - entao ele e extraido na hora e fica em build/).
"""

from __future__ import annotations

import io
import math
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_icons as E  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "icons"
OUT = ROOT / "bg.png"

WORLD_MAP = "Pal/Content/Pal/Texture/UI/Map/T_WorldMap"

# ---------------------------------------------------------------------
# Escala. Tudo aqui e derivado do minimapa de 240 px com os padroes do mod,
# entao mudar so SIZE muda a imagem inteira junto e nada sai fora de
# proporcao.
# ---------------------------------------------------------------------
CANVAS = 1050                   # 2x o thumbnail.png que ja existe (525)
SIZE = 900                      # diametro do minimapa
SCALE = SIZE / 240.0
ICON = round(18 * SCALE)        # cfg.iconSize
TEXELS = round(124 * SIZE / 240)  # quanto do T_WorldMap de 8192 cabe dentro

# Um trecho da regiao inicial: verde, com estradas, lago e costa. Em texels
# do arquivo de 8192.
CENTRE = (4470, 3400)

# O anel do jogo tem 128 px e aqui ele e esticado para 900. Esticar espalha o
# brilho da borda por todo o disco e lava o terreno - um artefato DESTA imagem,
# nao do jogo, onde ele cobre 240 px. Baixar a opacidade devolve a leitura que
# o minimapa tem em jogo.
RING_ALPHA = 0.5

# O mod recolhe os icones para dentro da borda (render.lua:
# `radius = half - cfg.iconSize * 0.35`), senao metade do medalhao fica
# pendurada para fora do disco.
ICON_INSET = 0.35

BACKDROP = (5, 8, 13)           # render.lua BACKDROP, sobre preto
TINT = {                        # sources.lua TINT
    "shiny": (255, 224, 77),
    "npc": (242, 217, 166),
    "player": (115, 199, 255),
    "egg": (255, 242, 191),
    "note": (204, 230, 255),
}

# O que fica no mapa. Posicao em fracao do RAIO, angulo em graus (0 = norte,
# horario), como se le num minimapa.
PALS = [
    ("T_Anubis_icon_normal", 0.30, 25, False),
    ("T_FoxMage_icon_normal", 0.55, 300, False),
    ("T_Alpaca_icon_normal", 0.42, 165, False),
    ("T_Penguin_icon_normal", 0.72, 210, False),
    ("T_BlueDragon_icon_normal", 0.62, 75, True),      # shiny: maior e dourado
    ("T_Boar_icon_normal", 0.80, 130, False),
    ("T_CatMage_icon_normal", 0.66, 340, False),
    ("T_SheepBall_icon_normal", 0.86, 15, False),
    ("T_ThunderDog_icon_normal", 0.50, 240, False),
    ("T_GrassPanda_icon_normal", 0.84, 285, False),
]

NPCS = [
    ("T_BOSS_NPC_Hunter", 0.36, 100),
    ("T_BOSS_NPC_Male_Trader01", 0.58, 150),
    ("T_BOSS_NPC_Female_Soldier", 0.74, 55),
]

# Simbolos de compasso: desenhados como vieram, sem medalhao.
POIS = [
    ("T_icon_compass_Teleport", 0.46, 320, None),
    ("T_icon_compass_Search_Treasure", 0.68, 190, None),
    ("T_icon_compass_dungeon", 0.78, 250, None),
    ("T_icon_compass_camp", 0.34, 200, None),
    ("T_icon_compass_tower", 0.88, 350, None),
    ("T_icon_compass_ClearCheck", 0.54, 120, TINT["note"]),
]


def world_map() -> Image.Image:
    """O T_WorldMap decodificado. Fica em build/ para nao reextrair 33 MB a
    cada execucao."""
    cached = E.BUILD / "T_WorldMap.png"
    if cached.exists():
        return Image.open(cached).convert("RGB")

    E.unpack([WORLD_MAP])
    uexp = E.BUILD / "extract" / Path(WORLD_MAP.replace("/", os.sep) + ".uexp")
    mip = E.parse_texture(uexp)
    if mip is None or not mip["inline"]:
        raise RuntimeError("nao consegui ler o mip 0 do T_WorldMap")
    dds = E.dds_bytes(mip["width"], mip["height"], mip["format"], mip["payload"])
    image = Image.open(io.BytesIO(dds))
    image.load()
    image = image.convert("RGB")
    cached.parent.mkdir(parents=True, exist_ok=True)
    image.save(cached)
    return image


def terrain() -> Image.Image:
    half = TEXELS // 2
    crop = world_map().crop((CENTRE[0] - half, CENTRE[1] - half,
                             CENTRE[0] + half, CENTRE[1] + half))
    return crop.resize((SIZE, SIZE), Image.LANCZOS)


def tinted(image: Image.Image, colour: tuple[int, int, int] | None) -> Image.Image:
    """Multiplica pelo tint, como o SetColorAndOpacity do UMG faz."""
    if colour is None:
        return image
    r, g, b, a = image.split()
    scale = lambda channel, value: channel.point(  # noqa: E731
        lambda p: p * value // 255)
    return Image.merge("RGBA", (scale(r, colour[0]), scale(g, colour[1]),
                                scale(b, colour[2]), a))


def place(canvas: Image.Image, name: str, distance: float, angle: float,
          size: int, colour: tuple[int, int, int] | None = None) -> None:
    icon = Image.open(ICONS / f"{name}.png").convert("RGBA")
    icon = icon.resize((size, size), Image.LANCZOS)
    icon = tinted(icon, colour)

    radians = math.radians(angle)
    radius = ((SIZE / 2) - ICON * ICON_INSET) * distance
    x = CANVAS / 2 + radius * math.sin(radians)
    y = CANVAS / 2 - radius * math.cos(radians)
    canvas.alpha_composite(icon, (round(x - size / 2), round(y - size / 2)))


def main() -> int:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))

    # fundo: o mesmo cinza-azulado escuro do backdrop, com uma vinheta suave
    # para o disco nao encostar na borda da imagem
    glow = Image.new("RGBA", (CANVAS, CANVAS), BACKDROP + (255,))
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).ellipse(
        (CANVAS * 0.02, CANVAS * 0.02, CANVAS * 0.98, CANVAS * 0.98), fill=255)
    canvas.paste(glow, (0, 0), mask.filter(ImageFilter.GaussianBlur(CANVAS / 12)))

    # o terreno, recortado no disco - o mod faz isso com faixas horizontais
    # com clipping, porque o Slate so corta retangulos; aqui uma mascara
    # circular da o mesmo resultado
    disc = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(disc).ellipse((0, 0, SIZE - 1, SIZE - 1), fill=255)
    disc = disc.filter(ImageFilter.GaussianBlur(1.2))
    map_layer = terrain().convert("RGBA")
    map_layer.putalpha(disc)
    origin = (CANVAS - SIZE) // 2
    canvas.alpha_composite(map_layer, (origin, origin))

    # a arte circular do proprio jogo por cima da borda
    ring = Image.open(ICONS / "T_prt_map_circle_eff.png").convert("RGBA")
    ring = ring.resize((SIZE, SIZE), Image.LANCZOS)
    ring.putalpha(ring.getchannel("A").point(lambda p: round(p * RING_ALPHA)))
    canvas.alpha_composite(ring, (origin, origin))

    for name, distance, angle, colour in POIS:
        place(canvas, name, distance, angle, ICON, colour)
    for name, distance, angle in NPCS:
        place(canvas, name, distance, angle, ICON)
    for name, distance, angle, shiny in PALS:
        place(canvas, name, distance, angle,
              ICON + (round(4 * SCALE) if shiny else 0),
              TINT["shiny"] if shiny else None)

    # o marcador do jogador fica sempre no centro exato
    player = Image.open(ICONS / "T_icon_map_player.png").convert("RGBA")
    player = player.resize((round(ICON * 1.35),) * 2, Image.LANCZOS)
    canvas.alpha_composite(player, ((CANVAS - player.width) // 2,
                                    (CANVAS - player.height) // 2))

    canvas.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"{OUT.relative_to(ROOT)}  {CANVAS}x{CANVAS}  "
          f"{OUT.stat().st_size / 1024:.0f} KB")
    print(f"  minimapa {SIZE} px, icones {ICON} px, {TEXELS} texels de terreno")
    print(f"  {len(PALS)} Pals, {len(NPCS)} NPCs, {len(POIS)} pontos de interesse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
