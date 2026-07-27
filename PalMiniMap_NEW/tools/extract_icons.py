"""
Extrai os icones que o minimapa usa do .pak do jogo e grava como PNG em
PalMiniMap/icons/.

POR QUE ISTO EXISTE
-------------------
Carregar um icone com `LoadAsset` custa uma passada COMPLETA pelo carregador
de pacotes da Unreal: achar o pacote no .pak, abrir, desserializar, construir
o UTexture2D, registrar no gerenciador de streaming e, depois, esperar o
streamer trazer o mip 0. Pior: `LoadAsset` e um flush SINCRONO da fila de
carregamento assincrona, entao ele espera atras do que o proprio jogo estiver
carregando naquele instante. Num lugar cheio de Pals isso vira o
microtravamento que o jogador sente quando cada seta vira um retrato.

Um PNG solto no disco nao passa por nada disso.
`UKismetRenderingLibrary::ImportFileAsTexture2D` le o arquivo, decodifica com
o IImageWrapper e cria uma textura TRANSIENTE (`NeverStream`, 1 mip). Nenhum
pacote, nenhuma fila assincrona, nenhum streaming - e uns 128x128 decodificam
em fracao de milissegundo. Ver `Scripts/assets.lua`.

O NOME DO ARQUIVO E A CHAVE
---------------------------
Cada PNG e gravado com o nome do OBJETO do asset:

    /Game/Pal/Texture/PalIcon/Normal/T_Alpaca_icon_normal.T_Alpaca_icon_normal
    -> icons/T_Alpaca_icon_normal.png

Assim o Lua nao precisa de tabela nenhuma: ele deriva o nome do arquivo do
caminho do asset que ja ia pedir. O que nao tiver PNG cai sozinho no
LoadAsset de sempre.

USO
    python tools/extract_icons.py

Requer Pillow (le DXT1/DXT5 direto) e repak.exe.
"""

from __future__ import annotations

import io
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
ICONS_OUT = ROOT / "icons"

REPAK = Path(r"d:/mods_palworld/_tools/repak/repak.exe")
PAK = Path(r"G:/SteamLibrary/steamapps/common/Palworld/Pal/Content/Paks/Pal-Windows.pak")

# Exatamente o que os Scripts pedem. O T_WorldMap fica de fora de proposito:
# e uma textura gigante, carregada UMA vez no build() e nao no caminho quente,
# entao virar PNG so gastaria dezenas de MB no disco sem tirar travamento
# nenhum.
WANTED = (
    re.compile(r"^Pal/Content/Pal/Texture/PalIcon/Normal/T_[^/]+_icon_normal$"),
    re.compile(r"^Pal/Content/Pal/Texture/UI/InGame/T_icon_(compass|map)_[^/]+$"),
    re.compile(r"^Pal/Content/Pal/Texture/UI/InGame/T_prt_map_[^/]+$"),
    re.compile(r"^Pal/Content/Pal/Texture/UI/Map/T_prt_map_circle_eff$"),
)

# PF_* -> (FourCC do DDS, bytes por bloco, pixels por bloco no eixo)
FORMATS = {
    "PF_DXT1": (b"DXT1", 8, 4),
    "PF_DXT3": (b"DXT3", 16, 4),
    "PF_DXT5": (b"DXT5", 16, 4),
    "PF_BC4": (b"BC4U", 8, 4),
    "PF_BC5": (b"BC5U", 16, 4),
    "PF_B8G8R8A8": (b"RGBA", 4, 1),
}

BULKDATA_ForceInlinePayload = 0x40

# `CreateTransient` - o que o ImportFileAsTexture2D usa - faz uma textura de UM
# mip so. Os retratos vem do pak com 128x128 e cadeia de mips completa, e o
# minimapa os desenha entre 10 e 40 px: sem mips, amostrar 128 em 18 cintila
# quando o icone se mexe. Reduzir para 64 com Lanczos AQUI faz na hora da
# extracao o que a cadeia de mips faria em tempo real, e ainda corta o arquivo
# e o custo de decodificacao em quatro.
#
# So os retratos. As artes de compasso ja vem pequenas do jogo, e o
# T_prt_map_circle_eff e esticado no minimapa inteiro - encolher aquele seria
# perder resolucao de verdade.
PORTRAIT_MAX = 64


def is_portrait(stem: str) -> bool:
    return stem.endswith("_icon_normal")


def pak_entries() -> list[str]:
    out = subprocess.run([str(REPAK), "list", str(PAK)],
                         check=True, capture_output=True, text=True).stdout
    seen: dict[str, None] = {}
    for line in out.splitlines():
        line = line.strip().replace("\\", "/")
        stem, ext = os.path.splitext(line)
        if ext not in (".uasset", ".uexp", ".ubulk"):
            continue
        if any(pattern.match(stem) for pattern in WANTED):
            seen[stem] = None
    return list(seen)


def unpack(stems: list[str], batch: int = 50) -> None:
    """repak so le o indice, entao chamar varias vezes sai barato. Os lotes
    existem porque a linha de comando do Windows estoura perto de 32 KB."""
    out = BUILD / "extract"
    out.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(stems), batch):
        includes: list[str] = []
        for stem in stems[start:start + batch]:
            for ext in (".uasset", ".uexp", ".ubulk"):
                includes += ["-i", stem + ext]
        subprocess.run([str(REPAK), "unpack", "-o", str(out), "-f", "-q",
                        *includes, str(PAK)], check=True)
        print(f"  {min(start + batch, len(stems))}/{len(stems)}", end="\r")
    print(" " * 30, end="\r")


def parse_texture(uexp: Path) -> dict | None:
    """Le o FTexturePlatformData cozido e devolve o mip 0.

    Layout (UE5.1, logo depois das propriedades):
        SizeX | SizeY | PackedData | FString "PF_..." |
        FirstMipToSerialize | NumMips |
        por mip: BulkDataFlags | ElementCount | SizeOnDisk | OffsetInFile |
                 [payload, se inline] | SizeX | SizeY | SizeZ
    """
    data = uexp.read_bytes()
    index = data.find(b"PF_")
    if index < 16:
        return None
    end = data.find(b"\x00", index)
    pixel_format = data[index:end].decode("ascii", "ignore")
    size_x, size_y = struct.unpack_from("<ii", data, index - 16)

    position = end + 1
    _first, mip_count = struct.unpack_from("<ii", data, position)
    position += 8
    if mip_count < 1:
        return None

    flags, _elements, size_on_disk, offset = struct.unpack_from("<iiiq", data, position)
    position += 20
    inline = bool(flags & BULKDATA_ForceInlinePayload)
    return {"width": size_x, "height": size_y, "format": pixel_format,
            "inline": inline, "offset": offset, "size": size_on_disk,
            "payload": data[position:position + size_on_disk] if inline else b""}


def mip0_size(width: int, height: int, pixel_format: str) -> int:
    _, block_bytes, block_pixels = FORMATS[pixel_format]
    if block_pixels == 1:
        return width * height * block_bytes
    blocks_x = max(1, (width + block_pixels - 1) // block_pixels)
    blocks_y = max(1, (height + block_pixels - 1) // block_pixels)
    return blocks_x * blocks_y * block_bytes


def dds_bytes(width: int, height: int, pixel_format: str, payload: bytes) -> bytes:
    """Reempacota o mip 0 com um cabecalho DDS. Nada e recomprimido aqui - os
    bytes sao os mesmos do pak; o DDS existe so para o Pillow saber le-los."""
    fourcc, _, block_pixels = FORMATS[pixel_format]
    DDSD = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000       # CAPS HEIGHT WIDTH PF LINEARSIZE

    if fourcc == b"RGBA":
        pf = struct.pack("<II4sIIIII", 32, 0x41, b"\0\0\0\0", 32,
                         0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
        pitch = width * 4
    else:
        pf = struct.pack("<II4sIIIII", 32, 0x4, fourcc, 0, 0, 0, 0, 0)
        pitch = mip0_size(width, height, pixel_format)

    header = struct.pack("<4sIIIIIII", b"DDS ", 124, DDSD, height, width, pitch, 0, 1)
    header += b"\0" * 44 + pf + struct.pack("<IIIII", 0x1000, 0, 0, 0, 0)
    return header + payload


def convert(stem: str, dest: Path) -> str | None:
    """None em caso de sucesso, ou o motivo da falha."""
    base = BUILD / "extract" / Path(stem.replace("/", os.sep))
    uexp = base.with_suffix(".uexp")
    if not uexp.exists():
        return "sem .uexp"

    mip = parse_texture(uexp)
    if mip is None:
        return "FTexturePlatformData nao reconhecido"
    if mip["format"] not in FORMATS:
        return f"formato {mip['format']} nao suportado"

    if mip["inline"]:
        payload = mip["payload"]
    else:
        ubulk = base.with_suffix(".ubulk")
        if not ubulk.exists():
            return "mip 0 esta no .ubulk, que nao foi extraido"
        payload = ubulk.read_bytes()[mip["offset"]:mip["offset"] + mip["size"]]

    expected = mip0_size(mip["width"], mip["height"], mip["format"])
    if len(payload) != expected:
        return f"mip 0 incompleto ({len(payload)}/{expected})"

    image = Image.open(io.BytesIO(dds_bytes(mip["width"], mip["height"],
                                            mip["format"], payload)))
    image.load()
    image = image.convert("RGBA")
    if is_portrait(stem) and max(image.size) > PORTRAIT_MAX:
        scale = PORTRAIT_MAX / max(image.size)
        image = image.resize((max(1, round(image.width * scale)),
                              max(1, round(image.height * scale))),
                             Image.LANCZOS)

    dest.parent.mkdir(parents=True, exist_ok=True)
    # optimize=True porque isto roda uma vez e os arquivos vao no zip do mod.
    image.save(dest, "PNG", optimize=True)
    return None


def main() -> int:
    if not REPAK.exists():
        print(f"repak.exe nao encontrado em {REPAK}")
        return 1
    if not PAK.exists():
        print(f"pak nao encontrado em {PAK}")
        return 1

    print("[1/3] lendo o indice do pak")
    stems = pak_entries()
    print(f"  {len(stems)} texturas correspondem ao que os Scripts pedem")

    print(f"[2/3] desempacotando {len(stems)} texturas")
    unpack(stems)

    print("[3/3] convertendo para PNG")
    ICONS_OUT.mkdir(parents=True, exist_ok=True)
    failures: dict[str, str] = {}
    written = total = 0
    for stem in sorted(stems):
        name = stem.rsplit("/", 1)[-1]
        dest = ICONS_OUT / f"{name}.png"
        error = convert(stem, dest)
        if error is None:
            written += 1
            total += dest.stat().st_size
        else:
            failures[name] = error

    print(f"  {written} PNG em {ICONS_OUT.relative_to(ROOT)} ({total / 1024 / 1024:.1f} MB)")
    if failures:
        print(f"  {len(failures)} falharam:")
        for name, reason in list(failures.items())[:10]:
            print(f"    {name}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
