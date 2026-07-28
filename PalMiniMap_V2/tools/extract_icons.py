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

CUIDADO: OS PNG SAO ARTE AUTORAL AGORA
--------------------------------------
Os icones em `icons/` foram REESTILIZADOS a mao (arredondados, estilo unico) -
nao sao mais so o que saiu do pak. Por isso este script NAO sobrescreve nada
por padrao: ele so grava o que ainda nao existe, e diz quantos pulou. Rodar
sem querer e perder o trabalho de estilo de 455 arquivos.

    python tools/extract_icons.py            # so o que falta
    python tools/extract_icons.py --force    # regrava TUDO, apaga o estilo

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
    # Yakushima vive numa SUBPASTA, mas o nome do objeto segue a mesma
    # convencao - entao gravado achatado em icons/ ele passa a ser encontrado
    # pelo caminho que o mod ja montava. Sao 11 especies que ate agora
    # apareciam como seta e eram classificadas como humano.
    re.compile(r"^Pal/Content/Pal/Texture/PalIcon/Normal/Yakushima/T_[^/]+_icon_normal$"),
    # Retratos de NPC humano. O nome NAO segue a convencao (a tribo
    # BOSS_Hunter_Rifle usa T_BOSS_NPC_Hunter), por isso a tabela do jogo e
    # decodificada abaixo para Scripts/npcicons.lua.
    re.compile(r"^Pal/Content/Pal/Texture/PalIcon/NPC/T_[^/]+$"),
    # (?i) de proposito: o jogo tem T_icon_Compass_Quest_0 com C MAIUSCULO, e
    # um padrao sensivel a caixa simplesmente nao o via. Perder um icone assim
    # e silencioso - nada falha, ele so nunca aparece na pasta.
    re.compile(r"(?i)^Pal/Content/Pal/Texture/UI/InGame/T_icon_(compass|map)_[^/]+$"),
    re.compile(r"^Pal/Content/Pal/Texture/UI/InGame/T_prt_map_[^/]+$"),
    re.compile(r"^Pal/Content/Pal/Texture/UI/Map/T_prt_map_circle_eff$"),
    # Ovos. O jogo NAO tem icone de bussola para ovo - a bussola do jogo base
    # nunca marca ovos - entao os 12 icones abaixo sao os do INVENTARIO, que
    # e onde o jogo mostra o ovo ao jogador. Um por elemento, mais o generico
    # e o "?" desconhecido; sources.lua escolhe pelo nome da classe do ator.
    # Note a pasta: `Pal/Content/Others/`, e nao `Pal/Content/Pal/` como todo
    # o resto - o mesmo mount point (`/Game/`), outro ramo.
    re.compile(r"^Pal/Content/Others/InventoryItemIcon/Texture/T_itemicon_Material_PalEgg[^/]*$"),
    # Efigie do Lifmunk e fruta de habilidade. Pelo mesmo motivo dos ovos: o
    # jogo nao tem glifo de bussola para nenhum dos dois, e ate 2.2.16 os dois
    # dividiam o T_icon_compass_ClearCheck com as notas - um check generico.
    #
    # ARTE COLORIDA E DE PROPOSITO, e nao so por ser "a certa": os glifos
    # brancos da bussola do jogo tem contorno fraco e SOMEM sobre neve. Medido
    # em grama, neve e deserto a 18px, que e o tamanho real no minimapa.
    re.compile(r"^Pal/Content/Others/InventoryItemIcon/Texture/T_itemicon_Relic$"),
    re.compile(r"^Pal/Content/Others/InventoryItemIcon/Texture/T_itemicon_Consume_SkillCard_Neutral$"),
)

# Fora de proposito:
#   PalIcon/SKin/*  - nenhuma linha da DT_PalCharacterIconDataTable aponta
#                     para essa pasta, entao nao ha tribo que chegue nelas.
#   T_Male_Scholar01_v02_Icon_normal, T_dummy_icon - um humano avulso e um
#                     placeholder; o primeiro, com esse nome, faria o probe
#                     de sources.lua classificar um humano como Pal.

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
# NAO vale para tudo. As artes de compasso ja vem pequenas do jogo, e o
# T_prt_map_circle_eff e esticado no minimapa inteiro - encolher aquele seria
# perder resolucao de verdade.
PORTRAIT_MAX = 64


def needs_downscale(stem: str) -> bool:
    """Arte grande que o minimapa desenha entre 10 e 40 px, e que por isso
    precisa ser reduzida na extracao - ver PORTRAIT_MAX acima.

    Sao dois grupos, pelo mesmo motivo e nao por serem parecidos:
      * retratos de personagem (/PalIcon/), 128x128 no pak;
      * icones de ovo do inventario, 256x256 - ainda pior, porque foram
        feitos para caber num slot de inventario e nao num marcador de mapa.
    """
    return "/PalIcon/" in stem or "/InventoryItemIcon/" in stem


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
    if needs_downscale(stem) and max(image.size) > PORTRAIT_MAX:
        scale = PORTRAIT_MAX / max(image.size)
        image = image.resize((max(1, round(image.width * scale)),
                              max(1, round(image.height * scale))),
                             Image.LANCZOS)

    dest.parent.mkdir(parents=True, exist_ok=True)
    # optimize=True porque isto roda uma vez e os arquivos vao no zip do mod.
    image.save(dest, "PNG", optimize=True)
    return None


# ---------------------------------------------------------------------
# A tabela de icones de NPC
#
# Para Pal a convencao basta: a tribo `Alpaca` usa `T_Alpaca_icon_normal`, e
# sources.lua monta esse caminho sozinho. Para humano ela NAO vale --
# `BOSS_Hunter_Rifle` usa `T_BOSS_NPC_Hunter`, `BOSS_Ninja` usa
# `T_BOSS_NPC_Male_Ninja`, `BOSS_Scientist_LaserRifle` usa
# `T_BOSS_NPC_Male_Scientist`. Nao da para derivar; tem de ser lido.
#
# A fonte e `DT_PalCharacterIconDataTable`, a tabela do proprio jogo. O
# UAssetGUI devolve o export CRU (nao resolve o CompositeDataTable), mas o
# usmap diz que `PalCharacterIconDataRow` tem uma unica propriedade, `Icon`
# (SoftObject), e isso fixa o registro em 30 bytes:
#
#     FName RowName | 2 bytes de cabecalho unversioned |
#     FName PackageName | FName AssetName | int32 SubPathString (sempre 0)
#
# O inicio das linhas e achado exigindo `start + NumRows*30 == len(dados)`,
# que so bate no lugar certo - nada aqui e chutado, e um erro de leitura nao
# passa silencioso.
# ---------------------------------------------------------------------
ICON_TABLE = "Pal/Content/Pal/DataTable/Character/DT_PalCharacterIconDataTable"
UASSETGUI = Path(r"d:/mods_palworld/_tools/UAssetGUI.exe")
USMAP = Path(r"d:/mods_palworld/_tools/Palworld.usmap")
NPC_LUA = ROOT / "Scripts" / "npcicons.lua"
ROW_SIZE = 30


def icon_table_rows() -> dict[str, tuple[str, str]]:
    """{row key: (package, object name)} da tabela de icones do jogo."""
    import base64
    import json

    unpack([ICON_TABLE])
    src = BUILD / "extract" / Path(ICON_TABLE.replace("/", os.sep) + ".uasset")
    dst = BUILD / "json" / "DT_PalCharacterIconDataTable.json"
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(UASSETGUI), "tojson", str(src), str(dst),
                    "VER_UE5_1", str(USMAP)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    document = json.loads(dst.read_text(encoding="utf-8"))
    names = document["NameMap"]
    data = base64.b64decode(document["Exports"][0]["Data"])

    for start in range(8, 64, 2):
        count = struct.unpack_from("<i", data, start - 4)[0]
        if count > 0 and start + count * ROW_SIZE == len(data):
            break
    else:
        raise RuntimeError("nao achei o inicio das linhas em "
                           "DT_PalCharacterIconDataTable")

    rows: dict[str, tuple[str, str]] = {}
    for index in range(count):
        offset = start + index * ROW_SIZE
        key_index, key_number = struct.unpack_from("<ii", data, offset)
        package_index = struct.unpack_from("<i", data, offset + 10)[0]
        object_index = struct.unpack_from("<i", data, offset + 18)[0]
        sub_path = struct.unpack_from("<i", data, offset + 26)[0]
        if sub_path != 0:
            raise RuntimeError("FSoftObjectPath com SubPathString - o layout "
                               "de 30 bytes nao vale mais")
        key = names[key_index]
        if key_number:
            key += f"_{key_number - 1}"
        rows[key] = (names[package_index], names[object_index])
    return rows


def write_npc_table(rows: dict[str, tuple[str, str]]) -> int:
    """CharacterID -> caminho completo da textura, para TODA linha da tabela.

    A versao 2.2.2 filtrava `if "/PalIcon/NPC/" in package` e ficava com 34
    linhas - so os NPCs "BOSS". Isso descartava justamente os que o jogador
    encontra o tempo todo, porque o retrato de mercador, aldeao e guarda NAO
    fica em PalIcon/NPC: fica em PalIcon/Normal, junto com os dos Pals.

        Male_Trader01    -> PalIcon/Normal/T_PalDealer_icon_normal
        Male_Trader02    -> PalIcon/Normal/T_SalesPerson_Green_icon_normal
        VisitingMerchant -> PalIcon/Normal/T_Female_MobuCitizen_icon_normal
        Guard_Rifle      -> PalIcon/Normal/T_Police_icon_normal
        BOSS_Hunter_Rifle-> PalIcon/NPC/T_BOSS_NPC_Hunter

    Ou seja: a pasta nao diz nada sobre ser humano ou Pal, e nao havia razao
    para filtrar por ela. Agora vai a tabela inteira, com o caminho completo,
    porque a pasta varia por linha e o Lua nao tem como adivinhar.
    """
    lines = [
        "-- GERADO POR tools/extract_icons.py - NAO EDITE A MAO.",
        "--",
        "-- CharacterID -> caminho da textura do retrato, lido da",
        "-- DT_PalCharacterIconDataTable do jogo.",
        "--",
        "-- E indexado pelo CharacterID e nao pelo nome do ator: um mesmo",
        "-- blueprint (BP_NPC_HumanNormal) e spawnado como mercador, aldeao",
        "-- ou guarda, entao o nome do ator NAO determina o retrato. Ver",
        "-- characterIdOf() em sources.lua.",
        "--",
        "-- O caminho vem completo porque a pasta muda por linha: retrato de",
        "-- mercador fica em PalIcon/Normal, o dos NPC 'BOSS' em PalIcon/NPC.",
        "",
        "return {",
    ]
    for key in sorted(rows):
        package, obj = rows[key]
        # o pacote vem como /Game/Pal/Texture/... ; o objeto e o nome dentro
        lines.append(f'    ["{key}"] = "{package}.{obj}",')
    lines.append("}")
    NPC_LUA.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(rows)


def main() -> int:
    if not REPAK.exists():
        print(f"repak.exe nao encontrado em {REPAK}")
        return 1
    if not PAK.exists():
        print(f"pak nao encontrado em {PAK}")
        return 1

    print("[1/4] lendo o indice do pak")
    stems = pak_entries()
    print(f"  {len(stems)} texturas correspondem ao que os Scripts pedem")

    print(f"[2/4] desempacotando {len(stems)} texturas")
    unpack(stems)

    force = "--force" in sys.argv
    print("[3/4] convertendo para PNG" + (" (--force: REGRAVANDO TUDO)" if force else ""))
    ICONS_OUT.mkdir(parents=True, exist_ok=True)
    failures: dict[str, str] = {}
    written = skipped = total = 0
    for stem in sorted(stems):
        name = stem.rsplit("/", 1)[-1]
        dest = ICONS_OUT / f"{name}.png"
        # O que ja esta la pode ter sido reestilizado a mao. Ver o aviso no
        # topo: sobrescrever e destrutivo e nao da para desfazer.
        if dest.exists() and not force:
            skipped += 1
            continue
        error = convert(stem, dest)
        if error is None:
            written += 1
            total += dest.stat().st_size
        else:
            failures[name] = error

    print(f"  {written} PNG novos em {ICONS_OUT.relative_to(ROOT)} "
          f"({total / 1024 / 1024:.1f} MB)")
    if skipped:
        print(f"  {skipped} preservados (ja existiam) - use --force para regravar")

    print("[4/4] tabela de icones de NPC")
    npc_count = write_npc_table(icon_table_rows())
    print(f"  {npc_count} tribos de NPC em {NPC_LUA.relative_to(ROOT)}")
    if failures:
        print(f"  {len(failures)} falharam:")
        for name, reason in list(failures.items())[:10]:
            print(f"    {name}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
