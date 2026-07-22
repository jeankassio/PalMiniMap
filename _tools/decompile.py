import json, sys

def T(e):
    return e['$type'].split('.')[-1].split(',')[0] if isinstance(e, dict) and '$type' in e else None

def prop(p):
    if p is None: return '?'
    new = p.get('New')
    if new: return '.'.join(new.get('Path', ['?']))
    return str(p.get('Old', '?'))

def objref(v, imports, exports):
    # FPackageIndex: negative => import, positive => export
    if isinstance(v, int):
        if v < 0:
            imp = imports[-v-1]
            return imp['ObjectName']
        elif v > 0:
            return exports[v-1].get('ObjectName', f'exp{v}')
        return 'null'
    if isinstance(v, dict):
        return str(v.get('ObjectName', v))
    return str(v)

class Sizer:
    def __init__(self, imports, exports):
        self.imports = imports
        self.exports = exports

    def size(self, e):
        t = T(e)
        f = getattr(self, t, None)
        if f is None:
            raise Exception(f'no size for {t}')
        return f(e)

    def EX_LocalVariable(self, e): return 1 + 8
    def EX_InstanceVariable(self, e): return 1 + 8
    def EX_LocalOutVariable(self, e): return 1 + 8
    def EX_DefaultVariable(self, e): return 1 + 8
    def EX_IntConst(self, e): return 1 + 4
    def EX_Int64Const(self, e): return 1 + 8
    def EX_FloatConst(self, e): return 1 + 4
    def EX_DoubleConst(self, e): return 1 + 8
    def EX_ByteConst(self, e): return 1 + 1
    def EX_IntConstByte(self, e): return 1 + 1
    def EX_True(self, e): return 1
    def EX_False(self, e): return 1
    def EX_Self(self, e): return 1
    def EX_Nothing(self, e): return 1
    def EX_NoObject(self, e): return 1
    def EX_NoInterface(self, e): return 1
    def EX_EndOfScript(self, e): return 1
    def EX_EndFunctionParms(self, e): return 1
    def EX_IntZero(self, e): return 1
    def EX_IntOne(self, e): return 1
    def EX_NameConst(self, e): return 1 + 12
    def EX_StringConst(self, e): return 1 + len(e['Value']) + 1
    def EX_UnicodeStringConst(self, e): return 1 + 2*(len(e['Value']) + 1)
    def EX_ObjectConst(self, e): return 1 + 8
    def EX_VectorConst(self, e): return 1 + 24
    def EX_RotationConst(self, e): return 1 + 24
    def EX_TransformConst(self, e): return 1 + 80
    def EX_SoftObjectConst(self, e): return 1 + self.size(e['Value'])
    def EX_Jump(self, e): return 1 + 4
    def EX_JumpIfNot(self, e): return 1 + 4 + self.size(e['BooleanExpression'])
    def EX_ComputedJump(self, e): return 1 + self.size(e['CodeOffsetExpression'])
    def EX_PushExecutionFlow(self, e): return 1 + 4
    def EX_PopExecutionFlow(self, e): return 1
    def EX_PopExecutionFlowIfNot(self, e): return 1 + self.size(e['BooleanExpression'])
    def EX_Return(self, e): return 1 + self.size(e['ReturnExpression'])
    def EX_Let(self, e): return 1 + 8 + self.size(e['Variable']) + self.size(e['Expression'])
    def EX_LetBool(self, e): return 1 + self.size(e['VariableExpression']) + self.size(e['AssignmentExpression'])
    def EX_LetObj(self, e): return 1 + self.size(e['VariableExpression']) + self.size(e['AssignmentExpression'])
    def EX_LetWeakObjPtr(self, e): return 1 + self.size(e['VariableExpression']) + self.size(e['AssignmentExpression'])
    def EX_LetDelegate(self, e): return 1 + self.size(e['VariableExpression']) + self.size(e['AssignmentExpression'])
    def EX_LetMulticastDelegate(self, e): return 1 + self.size(e['VariableExpression']) + self.size(e['AssignmentExpression'])
    def EX_LetValueOnPersistentFrame(self, e): return 1 + 8 + self.size(e['AssignmentExpression'])
    def _call_final(self, e):
        return 1 + 8 + sum(self.size(p) for p in e['Parameters']) + 1
    EX_LocalFinalFunction = _call_final
    EX_FinalFunction = _call_final
    EX_CallMath = _call_final
    def _call_virtual(self, e):
        return 1 + 12 + sum(self.size(p) for p in e['Parameters']) + 1
    EX_LocalVirtualFunction = _call_virtual
    EX_VirtualFunction = _call_virtual
    def EX_Context(self, e):
        return 1 + self.size(e['ObjectExpression']) + 4 + 8 + self.size(e['ContextExpression'])
    EX_Context_FailSilent = EX_Context
    EX_ClassContext = EX_Context
    def EX_InterfaceContext(self, e): return 1 + self.size(e['InterfaceValue'])
    def EX_StructMemberContext(self, e): return 1 + 8 + self.size(e['StructExpression'])
    def EX_SwitchValue(self, e):
        s = 1 + 2 + 4 + self.size(e['IndexTerm'])
        for c in e['Cases']:
            s += self.size(c['CaseIndexValueTerm']) + 4 + self.size(c['CaseTerm'])
        s += self.size(e['DefaultTerm'])
        return s
    def EX_PrimitiveCast(self, e): return 1 + 1 + self.size(e['Target'])
    def EX_SkipOffsetConst(self, e): return 1 + 4
    def EX_InstanceDelegate(self, e): return 1 + 12
    def EX_FieldPathConst(self, e): return 1 + self.size(e['Value'])
    def _cast(self, e): return 1 + 8 + self.size(e['Target'])
    EX_MetaCast = _cast
    EX_DynamicCast = _cast
    EX_ObjToInterfaceCast = _cast
    EX_CrossInterfaceCast = _cast
    EX_InterfaceToObjCast = _cast
    def EX_ArrayConst(self, e):
        return 1 + 8 + 4 + sum(self.size(v) for v in e['Elements']) + 1
    def EX_SetArray(self, e):
        return 1 + self.size(e['AssigningProperty']) + sum(self.size(v) for v in e['Elements']) + 1
    def EX_StructConst(self, e):
        return 1 + 8 + 4 + sum(self.size(v) for v in e['Value']) + 1
    def EX_MapConst(self, e):
        return 1 + 8 + 8 + 4 + sum(self.size(v) for v in e['Elements']) + 1
    def EX_CallMulticastDelegate(self, e):
        return 1 + 8 + self.size(e['Delegate']) + sum(self.size(p) for p in e['Parameters']) + 1
    def EX_AddMulticastDelegate(self, e):
        return 1 + self.size(e['Delegate']) + self.size(e['DelegateToAdd'])
    def EX_RemoveMulticastDelegate(self, e):
        return 1 + self.size(e['Delegate']) + self.size(e['DelegateToAdd'])
    def EX_ClearMulticastDelegate(self, e):
        return 1 + self.size(e['DelegateToClear'])
    def EX_BindDelegate(self, e):
        return 1 + 12 + self.size(e['Delegate']) + self.size(e['ObjectTerm'])
    def EX_ArrayGetByRef(self, e):
        return 1 + self.size(e['ArrayVariable']) + self.size(e['ArrayIndex'])
    def EX_TextConst(self, e):
        v = e['Value']; s = 1 + 1
        tt = v.get('TextLiteralType')
        def strsize(x):
            if x is None: return 1 + 4
            t2 = T(x)
            if t2: return self.size(x)
            return 0
        for k in ('SourceString','KeyString','Namespace','TableIdString','KeyString2'):
            if k in v and v[k] is not None:
                s += self.size(v[k])
        return s

class Printer:
    def __init__(self, imports, exports):
        self.imports = imports
        self.exports = exports

    def p(self, e):
        t = T(e)
        if t is None: return '?'
        m = {
            'EX_True':'true','EX_False':'false','EX_Self':'self','EX_Nothing':'∅',
            'EX_NoObject':'null','EX_EndOfScript':'END','EX_PopExecutionFlow':'POP_FLOW',
        }
        if t in m: return m[t]
        if t in ('EX_LocalVariable','EX_InstanceVariable','EX_LocalOutVariable','EX_DefaultVariable'):
            return prop(e['Variable'])
        if t in ('EX_IntConst','EX_Int64Const','EX_FloatConst','EX_DoubleConst','EX_ByteConst','EX_IntConstByte'):
            return str(e['Value'])
        if t == 'EX_NameConst': return f"N'{e['Value']}'"
        if t in ('EX_StringConst','EX_UnicodeStringConst'): return f"\"{e['Value']}\""
        if t == 'EX_ObjectConst': return f"Obj({objref(e['Value'], self.imports, self.exports)})"
        if t == 'EX_VectorConst': v=e['Value']; return f"Vec({v.get('X')},{v.get('Y')},{v.get('Z')})"
        if t in ('EX_LocalFinalFunction','EX_FinalFunction','EX_CallMath'):
            fn = objref(e['StackNode'], self.imports, self.exports)
            return f"{fn}({', '.join(self.p(a) for a in e['Parameters'])})"
        if t in ('EX_LocalVirtualFunction','EX_VirtualFunction'):
            return f"{e['VirtualFunctionName']}({', '.join(self.p(a) for a in e['Parameters'])})"
        if t in ('EX_Context','EX_Context_FailSilent','EX_ClassContext'):
            return f"{self.p(e['ObjectExpression'])}.{self.p(e['ContextExpression'])}"
        if t == 'EX_InterfaceContext': return self.p(e['InterfaceValue'])
        if t == 'EX_StructMemberContext':
            return f"{self.p(e['StructExpression'])}.{prop(e['StructMemberExpression'])}"
        if t == 'EX_SwitchValue':
            cases = '; '.join(f"{self.p(c['CaseIndexValueTerm'])}=>{self.p(c['CaseTerm'])}" for c in e['Cases'])
            return f"switch({self.p(e['IndexTerm'])}){{{cases}; default=>{self.p(e['DefaultTerm'])}}}"
        if t == 'EX_PrimitiveCast': return f"cast<{e.get('ConversionType')}>({self.p(e['Target'])})"
        if t == 'EX_SkipOffsetConst': return f"skip({e.get('Value')})"
        if t == 'EX_InstanceDelegate': return f"Delegate({e.get('FunctionName')})"
        if t in ('EX_DynamicCast','EX_MetaCast','EX_ObjToInterfaceCast','EX_CrossInterfaceCast','EX_InterfaceToObjCast'):
            return f"Cast<{objref(e['ClassPtr'], self.imports, self.exports)}>({self.p(e['Target'])})"
        if t == 'EX_SetArray':
            return f"{self.p(e['AssigningProperty'])} = [{', '.join(self.p(v) for v in e['Elements'])}]"
        if t == 'EX_ArrayConst':
            return f"[{', '.join(self.p(v) for v in e['Elements'])}]"
        if t == 'EX_StructConst':
            return f"Struct{{{', '.join(self.p(v) for v in e['Value'])}}}"
        if t == 'EX_TextConst': return 'Text(...)'
        if t == 'EX_ArrayGetByRef': return f"{self.p(e['ArrayVariable'])}[{self.p(e['ArrayIndex'])}]"
        if t == 'EX_BindDelegate': return f"BindDelegate({e.get('FunctionName')})"
        if t == 'EX_AddMulticastDelegate': return f"AddDelegate({self.p(e['Delegate'])}, {self.p(e['DelegateToAdd'])})"
        if t == 'EX_RemoveMulticastDelegate': return f"RemoveDelegate({self.p(e['Delegate'])}, {self.p(e['DelegateToAdd'])})"
        if t == 'EX_CallMulticastDelegate':
            return f"CallDelegate({self.p(e['Delegate'])}, {', '.join(self.p(a) for a in e['Parameters'])})"
        return t

    def stmt(self, e):
        t = T(e)
        if t == 'EX_Let': return f"{self.p(e['Variable'])} = {self.p(e['Expression'])}"
        if t in ('EX_LetBool','EX_LetObj','EX_LetWeakObjPtr','EX_LetDelegate','EX_LetMulticastDelegate'):
            return f"{self.p(e['VariableExpression'])} = {self.p(e['AssignmentExpression'])}"
        if t == 'EX_LetValueOnPersistentFrame':
            return f"frame.{prop(e['DestinationProperty'])} = {self.p(e['AssignmentExpression'])}"
        if t == 'EX_Jump': return f"goto L{e['CodeOffset']}"
        if t == 'EX_JumpIfNot': return f"if !({self.p(e['BooleanExpression'])}) goto L{e['CodeOffset']}"
        if t == 'EX_ComputedJump': return f"goto *({self.p(e['CodeOffsetExpression'])})"
        if t == 'EX_PushExecutionFlow': return f"PUSH_FLOW L{e['PushingAddress']}"
        if t == 'EX_PopExecutionFlowIfNot': return f"if !({self.p(e['BooleanExpression'])}) POP_FLOW"
        if t == 'EX_Return': return f"return {self.p(e['ReturnExpression'])}"
        return self.p(e)

def decompile(jsonfile, outfile):
    data = json.load(open(jsonfile, encoding='utf-8-sig'))
    imports = data['Imports']
    exports = data['Exports']
    sz = Sizer(imports, exports)
    pr = Printer(imports, exports)
    out = []
    for ex in exports:
        bc = ex.get('ScriptBytecode')
        if not bc: continue
        out.append(f"\n========== {ex.get('ObjectName')} ==========")
        off = 0
        for e in bc:
            line = pr.stmt(e)
            out.append(f"L{off}: {line}")
            off += sz.size(e)
    open(outfile, 'w', encoding='utf-8').write('\n'.join(out))
    print(f'wrote {outfile}')

if __name__ == '__main__':
    decompile(sys.argv[1], sys.argv[2])
