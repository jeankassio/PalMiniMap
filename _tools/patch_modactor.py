"""Patch ModActor.json:
1. Zoom Z+scroll -> Z + teclas +/- (substitui GetInputAxisKeyValue por pseudo-eixo de teclas)
2. SetActive(false/true) no scene capture junto de cada HideMap/ShowMap (economia de GPU)
3. Caminho da config: Paldar.modconfig.json -> PalMiniMap.modconfig.json
4. String de log de load (cosmético)
Recalcula todos os offsets absolutos (jumps, push flow, switch, latent linkages, entry points).
"""
import json, copy, sys
sys.path.insert(0, '.')
from decompile import Sizer, T

SRC = 'ModActor.json'
DST = 'ModActor.patched.json'

data = json.load(open(SRC, encoding='utf-8-sig'))
exports = data['Exports']
imports = data['Imports']
sz = Sizer(imports, exports)

ug = None
ug_idx = None
for i, ex in enumerate(exports):
    if ex.get('ObjectName') == 'ExecuteUbergraph_ModActor':
        ug = ex
        ug_idx = i + 1  # FPackageIndex for this export
assert ug is not None

stmts = ug['ScriptBytecode']

def offsets():
    offs = []
    o = 0
    for e in stmts:
        offs.append(o)
        o += sz.size(e)
    return offs, o

old_offs, old_total = offsets()
assert old_total == ug['ScriptBytecodeSize'] == 63796, old_total
old_index = {off: n for n, off in enumerate(old_offs)}
old_boundaries = set(old_offs) | {old_total}

# ---------- collect all absolute refs (for baseline validation & remap) ----------
def iter_absolute_refs(bytecode):
    """Yield (container, key, exact) — absolute ubergraph offsets. exact=True deve cair
    em fronteira de statement; exact=False pode apontar para dentro do statement (switch)."""
    def walk(e):
        if isinstance(e, dict):
            t = T(e)
            if t in ('EX_Jump', 'EX_JumpIfNot'):
                yield (e, 'CodeOffset', True)
            elif t == 'EX_PushExecutionFlow':
                yield (e, 'PushingAddress', True)
            elif t == 'EX_SwitchValue':
                yield (e, 'EndGotoOffset', False)
                for c in e.get('Cases', []):
                    yield (c, 'NextOffset', False)
            elif t == 'EX_SkipOffsetConst':
                yield (e, 'Value', True)
            for v in e.values():
                if isinstance(v, (dict, list)):
                    yield from walk(v)
        elif isinstance(e, list):
            for v in e:
                yield from walk(v)
    yield from walk(bytecode)

def iter_stub_entries():
    """IntConst params of calls to ExecuteUbergraph_ModActor in other exports."""
    for ex in exports:
        bc = ex.get('ScriptBytecode')
        if not bc or ex is ug:
            continue
        def walk(e):
            if isinstance(e, dict):
                t = T(e)
                if t in ('EX_LocalFinalFunction', 'EX_FinalFunction', 'EX_CallMath'):
                    if e.get('StackNode') == ug_idx:
                        ps = e.get('Parameters', [])
                        assert len(ps) == 1 and T(ps[0]) == 'EX_IntConst', ps
                        yield ps[0]
                for v in e.values():
                    if isinstance(v, (dict, list)):
                        yield from walk(v)
            elif isinstance(e, list):
                for v in e:
                    yield from walk(v)
        yield from walk(bc)

# Baseline: exact refs must be statement boundaries; inexact must fall within script
bad = []
for holder, key, exact in iter_absolute_refs(stmts):
    v = holder[key]
    if exact and v not in old_boundaries:
        bad.append((T(holder), key, v))
    if not exact and not (0 <= v <= old_total):
        bad.append((T(holder), key, v, 'out of range'))
for p in iter_stub_entries():
    if p['Value'] not in old_boundaries:
        bad.append(('stub', 'Value', p['Value']))
assert not bad, bad
print(f'baseline OK: absolute refs validated ({len(stmts)} stmts)')

# ---------- build helper expressions ----------
def key_struct(keyname):
    return {
        "$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_StructConst, UAssetAPI",
        "Struct": -257, "StructSize": 32,
        "Value": [{"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_NameConst, UAssetAPI",
                   "Value": keyname}]
    }

is_down_template = copy.deepcopy(stmts[old_index[60479]]['AssignmentExpression'])  # EX_Context ctrl.IsInputKeyDown(...)

def is_down(keyname):
    ctx = copy.deepcopy(is_down_template)
    ctx['ContextExpression']['Parameters'] = [key_struct(keyname)]
    ctx['Offset'] = sz.size(ctx['ContextExpression'])
    return ctx

selectfloat_node = stmts[old_index[61210]]['Expression']['StackNode']  # -130 (KismetMathLibrary.SelectFloat)

def dbl(v):
    return {"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_DoubleConst, UAssetAPI", "Value": v}

def selectfloat(a, b, cond):
    return {"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_CallMath, UAssetAPI",
            "StackNode": selectfloat_node, "Parameters": [a, b, cond]}

# pseudo-eixo: +0.15 se '+' pressionado, -0.15 se '-' pressionado, 0 senão (double->float cast 3)
pseudo_axis = {
    "$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_PrimitiveCast, UAssetAPI",
    "ConversionType": 3,
    "Target": selectfloat(dbl(0.15),
                          selectfloat(dbl(-0.15), dbl(0.0), is_down('Subtract')),
                          is_down('Add'))
}

# ---------- edit 1: zoom axis statements ----------
for off in (60572, 60937):
    st = stmts[old_index[off]]
    assert T(st) == 'EX_Let'
    assert T(st['Expression']) == 'EX_FinalFunction'
    st['Expression'] = copy.deepcopy(pseudo_axis)
print('edit 1 ok: zoom pseudo-axis at 60572/60937')

# ---------- edit 2: SetActive inserts ----------
setactive_false = copy.deepcopy(stmts[old_index[42694]])
assert T(setactive_false) == 'EX_Context'
setactive_true = copy.deepcopy(setactive_false)
setactive_true['ContextExpression']['Parameters'][0]['$type'] = \
    "UAssetAPI.Kismet.Bytecode.Expressions.EX_True, UAssetAPI"

hide_sites = [25422, 26578, 45117, 48739]
show_sites = [25597, 26489, 26541, 48817]
for off in hide_sites + show_sites:
    st = stmts[old_index[off]]
    assert T(st) == 'EX_Context', (off, T(st))
    fn = st['ContextExpression'].get('VirtualFunctionName') or \
         st['ContextExpression'].get('StackNode')
    # sanity: alvo é mapWidget.HideMap/ShowMap (funções do widget via FinalFunction)

inserts = sorted([(off, copy.deepcopy(setactive_false)) for off in hide_sites] +
                 [(off, copy.deepcopy(setactive_true)) for off in show_sites],
                 key=lambda x: -x[0])
for off, node in inserts:
    stmts.insert(old_index[off] + 1, node)
print('edit 2 ok: 8 SetActive statements inserted')

# ---------- edit 3+4: strings ----------
n_str = 0
def fix_strings(e):
    global n_str
    if isinstance(e, dict):
        if T(e) in ('EX_StringConst', 'EX_UnicodeStringConst'):
            if e['Value'] == 'Paks/LogicMods/Paldar.modconfig.json':
                e['Value'] = 'Paks/LogicMods/PalMiniMap.modconfig.json'
                n_str += 1
            elif e['Value'] == '=== PALDAR LOADED! THANKS FOR YOUR SUPPORT & ENJOY! :) ===':
                e['Value'] = '=== PALMINIMAP LOADED! BASED ON PALDAR BY T3R3NC3B :) ==='
                n_str += 1
        for v in e.values():
            if isinstance(v, (dict, list)):
                fix_strings(v)
    elif isinstance(e, list):
        for v in e:
            fix_strings(v)
fix_strings(stmts)
assert n_str == 2, n_str
print('edit 3/4 ok: strings replaced')

# ---------- remap ----------
new_offs, new_total = offsets()
# map: old statement offset -> new statement offset.
# stmts agora contém inserções; reconstruir correspondência: os statements originais
# mantêm identidade de objeto exceto os substituídos (mesmo objeto, Expression trocada).
inserted_ids = {id(node) for _, node in inserts}
old_to_new = {}
oi = 0
for n, st in enumerate(stmts):
    if id(st) in inserted_ids:
        continue
    old_to_new[old_offs[oi]] = new_offs[n]
    oi += 1
assert oi == len(old_offs)
old_to_new[old_total] = new_total

import bisect
sorted_old = sorted(old_to_new.keys())

def remap_interval(v):
    # statement (original) que contém v; novo = novo_início + delta interno
    k = bisect.bisect_right(sorted_old, v) - 1
    start = sorted_old[k]
    return old_to_new[start] + (v - start)

remapped = 0
for holder, key, exact in iter_absolute_refs(stmts):
    v = holder[key]
    if exact:
        assert v in old_to_new, (T(holder), key, v)
        holder[key] = old_to_new[v]
    else:
        holder[key] = remap_interval(v)
    remapped += 1
for p in iter_stub_entries():
    p['Value'] = old_to_new[p['Value']]
    remapped += 1
print(f'remapped {remapped} absolute refs; size {old_total} -> {new_total}')

ug['ScriptBytecodeSize'] = new_total

# ---------- final validation ----------
final_offs, final_total = offsets()
final_boundaries = set(final_offs) | {final_total}
bad = []
for holder, key, exact in iter_absolute_refs(stmts):
    v = holder[key]
    if exact and v not in final_boundaries:
        bad.append((T(holder), key, v))
    if not exact and not (0 <= v <= final_total):
        bad.append((T(holder), key, v, 'out of range'))
for p in iter_stub_entries():
    if p['Value'] not in final_boundaries:
        bad.append(('stub', 'Value', p['Value']))
assert not bad, bad
print('final validation OK')

# ---------- NameMap ----------
nm = data['NameMap']
for n in ('Add', 'Subtract'):
    if n not in nm:
        nm.append(n)
print('NameMap ok')

json.dump(data, open(DST, 'w', encoding='utf-8'), indent=2)
print('wrote', DST)
