#
#
#           The Nim Compiler
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Injects destructor calls into Nim code as well as
## an optimizer that optimizes copies to moves. This is implemented as an
## AST to AST transformation so that every backend benefits from it.

## See doc/destructors.rst for a spec of the implemented rewrite rules

import
  intsets, strtabs, ast, astalgo, msgs, renderer, magicsys, types, idents,
  strutils, options, dfa, lowerings, tables, modulegraphs, msgs,
  lineinfos, parampatterns, sighashes, liftdestructors, optimizer,
  varpartitions

from trees import exprStructuralEquivalent, getRoot

type
  Scope = object  # well we do scope-based memory management. \
    # a scope is comparable to an nkStmtListExpr like
    # (try: statements; dest = y(); finally: destructors(); dest)
    vars: seq[PSym]
    wasMoved: seq[PNode]
    final: seq[PNode] # finally section
    needsTry: bool
    parent: ptr Scope

type
  Con = object
    owner: PSym
    g: ControlFlowGraph
    graph: ModuleGraph
    otherRead: PNode
    inLoop, inSpawn, inLoopCond: int
    uninit: IntSet # set of uninit'ed vars
    uninitComputed: bool

  ProcessMode = enum
    normal
    consumed
    sinkArg

const toDebug {.strdefine.} = ""

proc hasDestructor(c: Con; t: PType): bool {.inline.} =
  result = ast.hasDestructor(t)
  when toDebug.len > 0:
    # for more effective debugging
    if not result and c.graph.config.selectedGC in {gcArc, gcOrc}:
      assert(not containsGarbageCollectedRef(t))

template dbg(body) =
  when toDebug.len > 0:
    if c.owner.name.s == toDebug or toDebug == "always":
      body

proc getTemp(c: var Con; s: var Scope; typ: PType; info: TLineInfo): PNode =
  let sym = newSym(skTemp, getIdent(c.graph.cache, ":tmpD"), c.owner, info)
  sym.typ = typ
  s.vars.add(sym)
  result = newSymNode(sym)

proc nestedScope(parent: var Scope): Scope =
  Scope(vars: @[], wasMoved: @[], final: @[], needsTry: false, parent: addr(parent))

proc p(n: PNode; c: var Con; s: var Scope; mode: ProcessMode): PNode
proc moveOrCopy(dest, ri: PNode; c: var Con; s: var Scope; isDecl = false): PNode

proc isLastRead(location: PNode; cfg: ControlFlowGraph; otherRead: var PNode; pc, until: int): int =
  var pc = pc
  while pc < cfg.len and pc < until:
    case cfg[pc].kind
    of def:
      if instrTargets(cfg[pc].n, location) == Full:
        # the path leads to a redefinition of 's' --> abandon it.
        return high(int)
      elif instrTargets(cfg[pc].n, location) == Partial:
        # only partially writes to 's' --> can't sink 's', so this def reads 's'
        otherRead = cfg[pc].n
        return -1
      inc pc
    of use:
      if instrTargets(cfg[pc].n, location) != None:
        otherRead = cfg[pc].n
        return -1
      inc pc
    of goto:
      pc += cfg[pc].dest
    of fork:
      # every branch must lead to the last read of the location:
      var variantA = pc + 1
      var variantB = pc + cfg[pc].dest
      while variantA != variantB:
        if min(variantA, variantB) < 0: return -1
        if max(variantA, variantB) >= cfg.len or min(variantA, variantB) >= until:
          break
        if variantA < variantB:
          variantA = isLastRead(location, cfg, otherRead, variantA, min(variantB, until))
        else:
          variantB = isLastRead(location, cfg, otherRead, variantB, min(variantA, until))
      pc = min(variantA, variantB)
  return pc

proc isCursor(n: PNode; c: Con): bool =
  case n.kind
  of nkSym:
    sfCursor in n.sym.flags
  of nkDotExpr:
    isCursor(n[1], c)
  of nkCheckedFieldExpr:
    isCursor(n[0], c)
  else:
    false

proc isLastRead(n: PNode; c: var Con): bool =
  # first we need to search for the instruction that belongs to 'n':
  var instr = -1
  let m = dfa.skipConvDfa(n)
  if m.kind == nkSym and sfSingleUsedTemp in m.sym.flags: return true

  for i in 0..<c.g.len:
    # This comparison is correct and MUST not be ``instrTargets``:
    if c.g[i].kind == use and c.g[i].n == m:
      if instr < 0:
        instr = i
        break

  dbg: echo "starting point for ", n, " is ", instr, " ", n.kind

  if instr < 0: return false
  # we go through all paths beginning from 'instr+1' and need to
  # ensure that we don't find another 'use X' instruction.
  if instr+1 >= c.g.len: return true

  c.otherRead = nil
  result = isLastRead(n, c.g, c.otherRead, instr+1, int.high) >= 0
  dbg: echo "ugh ", c.otherRead.isNil, " ", result

proc isFirstWrite(location: PNode; cfg: ControlFlowGraph; pc, until: int): int =
  var pc = pc
  while pc < until:
    case cfg[pc].kind
    of def:
      if instrTargets(cfg[pc].n, location) != None:
        # a definition of 's' before ours makes ours not the first write
        return -1
      inc pc
    of use:
      if instrTargets(cfg[pc].n, location) != None:
        return -1
      inc pc
    of goto:
      pc += cfg[pc].dest
    of fork:
      # every branch must not contain a def/use of our location:
      var variantA = pc + 1
      var variantB = pc + cfg[pc].dest
      while variantA != variantB:
        if min(variantA, variantB) < 0: return -1
        if max(variantA, variantB) > until:
          break
        if variantA < variantB:
          variantA = isFirstWrite(location, cfg, variantA, min(variantB, until))
        else:
          variantB = isFirstWrite(location, cfg, variantB, min(variantA, until))
      pc = min(variantA, variantB)
  return pc

proc isFirstWrite(n: PNode; c: var Con): bool =
  # first we need to search for the instruction that belongs to 'n':
  var instr = -1
  let m = dfa.skipConvDfa(n)

  for i in countdown(c.g.len-1, 0): # We search backwards here to treat loops correctly
    if c.g[i].kind == def and c.g[i].n == m:
      if instr < 0:
        instr = i
        break

  if instr < 0: return false
  # we go through all paths going to 'instr' and need to
  # ensure that we don't find another 'def/use X' instruction.
  if instr == 0: return true

  result = isFirstWrite(n, c.g, 0, instr) >= 0

proc initialized(code: ControlFlowGraph; pc: int,
                 init, uninit: var IntSet; until: int): int =
  ## Computes the set of definitely initialized variables across all code paths
  ## as an IntSet of IDs.
  var pc = pc
  while pc < code.len:
    case code[pc].kind
    of goto:
      pc += code[pc].dest
    of fork:
      var initA = initIntSet()
      var initB = initIntSet()
      var variantA = pc + 1
      var variantB = pc + code[pc].dest
      while variantA != variantB:
        if max(variantA, variantB) > until:
          break
        if variantA < variantB:
          variantA = initialized(code, variantA, initA, uninit, min(variantB, until))
        else:
          variantB = initialized(code, variantB, initB, uninit, min(variantA, until))
      pc = min(variantA, variantB)
      # we add vars if they are in both branches:
      for v in initA:
        if v in initB:
          init.incl v
    of use:
      let v = code[pc].n.sym
      if v.kind != skParam and v.id notin init:
        # attempt to read an uninit'ed variable
        uninit.incl v.id
      inc pc
    of def:
      let v = code[pc].n.sym
      init.incl v.id
      inc pc
  return pc

template isUnpackedTuple(n: PNode): bool =
  ## we move out all elements of unpacked tuples,
  ## hence unpacked tuples themselves don't need to be destroyed
  (n.kind == nkSym and n.sym.kind == skTemp and n.sym.typ.kind == tyTuple)

proc checkForErrorPragma(c: Con; t: PType; ri: PNode; opname: string) =
  var m = "'" & opname & "' is not available for type <" & typeToString(t) & ">"
  if (opname == "=" or opname == "=copy") and ri != nil:
    m.add "; requires a copy because it's not the last read of '"
    m.add renderTree(ri)
    m.add '\''
    if c.otherRead != nil:
      m.add "; another read is done here: "
      m.add c.graph.config $ c.otherRead.info
    elif ri.kind == nkSym and ri.sym.kind == skParam and not isSinkType(ri.sym.typ):
      m.add "; try to make "
      m.add renderTree(ri)
      m.add " a 'sink' parameter"
  m.add "; routine: "
  m.add c.owner.name.s
  localError(c.graph.config, ri.info, errGenerated, m)

proc makePtrType(c: Con, baseType: PType): PType =
  result = newType(tyPtr, c.owner)
  addSonSkipIntLit(result, baseType)

proc genOp(c: Con; op: PSym; dest: PNode): PNode =
  let addrExp = newNodeIT(nkHiddenAddr, dest.info, makePtrType(c, dest.typ))
  addrExp.add(dest)
  result = newTree(nkCall, newSymNode(op), addrExp)

proc genOp(c: Con; t: PType; kind: TTypeAttachedOp; dest, ri: PNode): PNode =
  var op = t.attachedOps[kind]
  if op == nil or op.ast[genericParamsPos].kind != nkEmpty:
    # give up and find the canonical type instead:
    let h = sighashes.hashType(t, {CoType, CoConsiderOwned, CoDistinct})
    let canon = c.graph.canonTypes.getOrDefault(h)
    if canon != nil:
      op = canon.attachedOps[kind]
  if op == nil:
    #echo dest.typ.id
    globalError(c.graph.config, dest.info, "internal error: '" & AttachedOpToStr[kind] &
      "' operator not found for type " & typeToString(t))
  elif op.ast[genericParamsPos].kind != nkEmpty:
    globalError(c.graph.config, dest.info, "internal error: '" & AttachedOpToStr[kind] &
      "' operator is generic")
  dbg:
    if kind == attachedDestructor:
      echo "destructor is ", op.id, " ", op.ast
  if sfError in op.flags: checkForErrorPragma(c, t, ri, AttachedOpToStr[kind])
  c.genOp(op, dest)

proc genDestroy(c: Con; dest: PNode): PNode =
  let t = dest.typ.skipTypes({tyGenericInst, tyAlias, tySink})
  result = c.genOp(t, attachedDestructor, dest, nil)

proc canBeMoved(c: Con; t: PType): bool {.inline.} =
  let t = t.skipTypes({tyGenericInst, tyAlias, tySink})
  if optOwnedRefs in c.graph.config.globalOptions:
    result = t.kind != tyRef and t.attachedOps[attachedSink] != nil
  else:
    result = t.attachedOps[attachedSink] != nil

proc isNoInit(dest: PNode): bool {.inline.} =
  result = dest.kind == nkSym and sfNoInit in dest.sym.flags

proc genSink(c: var Con; dest, ri: PNode, isDecl = false): PNode =
  if (c.inLoopCond == 0 and (isUnpackedTuple(dest) or isDecl or
      (isAnalysableFieldAccess(dest, c.owner) and isFirstWrite(dest, c)))) or
      isNoInit(dest):
    # optimize sink call into a bitwise memcopy
    result = newTree(nkFastAsgn, dest, ri)
  else:
    let t = dest.typ.skipTypes({tyGenericInst, tyAlias, tySink})
    if t.attachedOps[attachedSink] != nil:
      result = c.genOp(t, attachedSink, dest, ri)
      result.add ri
    else:
      # the default is to use combination of `=destroy(dest)` and
      # and copyMem(dest, source). This is efficient.
      result = newTree(nkStmtList, c.genDestroy(dest), newTree(nkFastAsgn, dest, ri))

proc genCopyNoCheck(c: Con; dest, ri: PNode): PNode =
  let t = dest.typ.skipTypes({tyGenericInst, tyAlias, tySink})
  result = c.genOp(t, attachedAsgn, dest, ri)

proc genCopy(c: var Con; dest, ri: PNode): PNode =
  let t = dest.typ
  if tfHasOwned in t.flags and ri.kind != nkNilLit:
    # try to improve the error message here:
    if c.otherRead == nil: discard isLastRead(ri, c)
    c.checkForErrorPragma(t, ri, "=copy")
  result = c.genCopyNoCheck(dest, ri)

proc genDiscriminantAsgn(c: var Con; s: var Scope; n: PNode): PNode =
  # discriminator is ordinal value that doesn't need sink destroy
  # but fields within active case branch might need destruction

  # tmp to support self assignments
  let tmp = c.getTemp(s, n[1].typ, n.info)

  result = newTree(nkStmtList)
  result.add newTree(nkFastAsgn, tmp, p(n[1], c, s, consumed))
  result.add p(n[0], c, s, normal)

  let le = p(n[0], c, s, normal)
  let leDotExpr = if le.kind == nkCheckedFieldExpr: le[0] else: le
  let objType = leDotExpr[0].typ

  if hasDestructor(c, objType):
    if objType.attachedOps[attachedDestructor] != nil and
        sfOverriden in objType.attachedOps[attachedDestructor].flags:
      localError(c.graph.config, n.info, errGenerated, """Assignment to discriminant for objects with user defined destructor is not supported, object must have default destructor.
It is best to factor out piece of object that needs custom destructor into separate object or not use discriminator assignment""")
      result.add newTree(nkFastAsgn, le, tmp)
      return

    # generate: if le != tmp: `=destroy`(le)
    let branchDestructor = produceDestructorForDiscriminator(c.graph, objType, leDotExpr[1].sym, n.info)
    let cond = newNodeIT(nkInfix, n.info, getSysType(c.graph, unknownLineInfo, tyBool))
    cond.add newSymNode(getMagicEqSymForType(c.graph, le.typ, n.info))
    cond.add le
    cond.add tmp
    let notExpr = newNodeIT(nkPrefix, n.info, getSysType(c.graph, unknownLineInfo, tyBool))
    notExpr.add newSymNode(createMagic(c.graph, "not", mNot))
    notExpr.add cond
    result.add newTree(nkIfStmt, newTree(nkElifBranch, notExpr, c.genOp(branchDestructor, le)))
  result.add newTree(nkFastAsgn, le, tmp)

proc genWasMoved(c: var Con, n: PNode): PNode =
  result = newNodeI(nkCall, n.info)
  result.add(newSymNode(createMagic(c.graph, "wasMoved", mWasMoved)))
  result.add copyTree(n) #mWasMoved does not take the address
  #if n.kind != nkSym:
  #  message(c.graph.config, n.info, warnUser, "wasMoved(" & $n & ")")

proc genDefaultCall(t: PType; c: Con; info: TLineInfo): PNode =
  result = newNodeI(nkCall, info)
  result.add(newSymNode(createMagic(c.graph, "default", mDefault)))
  result.typ = t

proc destructiveMoveVar(n: PNode; c: var Con; s: var Scope): PNode =
  # generate: (let tmp = v; reset(v); tmp)
  if not hasDestructor(c, n.typ):
    assert n.kind != nkSym or not hasDestructor(c, n.sym.typ)
    result = copyTree(n)
  else:
    result = newNodeIT(nkStmtListExpr, n.info, n.typ)

    var temp = newSym(skLet, getIdent(c.graph.cache, "blitTmp"), c.owner, n.info)
    temp.typ = n.typ
    var v = newNodeI(nkLetSection, n.info)
    let tempAsNode = newSymNode(temp)

    var vpart = newNodeI(nkIdentDefs, tempAsNode.info, 3)
    vpart[0] = tempAsNode
    vpart[1] = newNodeI(nkEmpty, tempAsNode.info)
    vpart[2] = n
    v.add(vpart)

    result.add v
    let wasMovedCall = c.genWasMoved(skipConv(n))
    result.add wasMovedCall
    result.add tempAsNode

proc isCapturedVar(n: PNode): bool =
  let root = getRoot(n)
  if root != nil: result = root.name.s[0] == ':'

proc passCopyToSink(n: PNode; c: var Con; s: var Scope): PNode =
  result = newNodeIT(nkStmtListExpr, n.info, n.typ)
  let tmp = c.getTemp(s, n.typ, n.info)
  if hasDestructor(c, n.typ):
    result.add c.genWasMoved(tmp)
    var m = c.genCopy(tmp, n)
    m.add p(n, c, s, normal)
    result.add m
    if isLValue(n) and not isCapturedVar(n) and n.typ.skipTypes(abstractInst).kind != tyRef and c.inSpawn == 0:
      message(c.graph.config, n.info, hintPerformance,
        ("passing '$1' to a sink parameter introduces an implicit copy; " &
        "if possible, rearrange your program's control flow to prevent it") % $n)
  else:
    if c.graph.config.selectedGC in {gcArc, gcOrc}:
      assert(not containsManagedMemory(n.typ))
    if n.typ.skipTypes(abstractInst).kind in {tyOpenArray, tyVarargs}:
      localError(c.graph.config, n.info, "cannot create an implicit openArray copy to be passed to a sink parameter")
    result.add newTree(nkAsgn, tmp, p(n, c, s, normal))
  # Since we know somebody will take over the produced copy, there is
  # no need to destroy it.
  result.add tmp

proc isDangerousSeq(t: PType): bool {.inline.} =
  let t = t.skipTypes(abstractInst)
  result = t.kind == tySequence and tfHasOwned notin t[0].flags

proc containsConstSeq(n: PNode): bool =
  if n.kind == nkBracket and n.len > 0 and n.typ != nil and isDangerousSeq(n.typ):
    return true
  result = false
  case n.kind
  of nkExprEqExpr, nkExprColonExpr, nkHiddenStdConv, nkHiddenSubConv:
    result = containsConstSeq(n[1])
  of nkObjConstr, nkClosure:
    for i in 1..<n.len:
      if containsConstSeq(n[i]): return true
  of nkCurly, nkBracket, nkPar, nkTupleConstr:
    for son in n:
      if containsConstSeq(son): return true
  else: discard

proc ensureDestruction(arg, orig: PNode; c: var Con; s: var Scope): PNode =
  # it can happen that we need to destroy expression contructors
  # like [], (), closures explicitly in order to not leak them.
  if arg.typ != nil and hasDestructor(c, arg.typ):
    # produce temp creation for (fn, env). But we need to move 'env'?
    # This was already done in the sink parameter handling logic.
    result = newNodeIT(nkStmtListExpr, arg.info, arg.typ)
    let tmp = c.getTemp(s, arg.typ, arg.info)
    result.add c.genSink(tmp, arg, isDecl = true)
    result.add tmp
    s.final.add c.genDestroy(tmp)
  else:
    result = arg

proc cycleCheck(n: PNode; c: var Con) =
  if c.graph.config.selectedGC != gcArc: return
  var value = n[1]
  if value.kind == nkClosure:
    value = value[1]
  if value.kind == nkNilLit: return
  let destTyp = n[0].typ.skipTypes(abstractInst)
  if destTyp.kind != tyRef and not (destTyp.kind == tyProc and destTyp.callConv == ccClosure):
    return

  var x = n[0]
  var field: PNode = nil
  while true:
    if x.kind == nkDotExpr:
      field = x[1]
      if field.kind == nkSym and sfCursor in field.sym.flags: return
      x = x[0]
    elif x.kind in {nkBracketExpr, nkCheckedFieldExpr, nkDerefExpr, nkHiddenDeref}:
      x = x[0]
    else:
      break
    if exprStructuralEquivalent(x, value, strictSymEquality = true):
      let msg =
        if field != nil:
          "'$#' creates an uncollectable ref cycle; annotate '$#' with .cursor" % [$n, $field]
        else:
          "'$#' creates an uncollectable ref cycle" % [$n]
      message(c.graph.config, n.info, warnCycleCreated, msg)
      break

proc pVarTopLevel(v: PNode; c: var Con; s: var Scope; ri, res: PNode) =
  # move the variable declaration to the top of the frame:
  s.vars.add v.sym
  if isUnpackedTuple(v):
    if c.inLoop > 0:
      # unpacked tuple needs reset at every loop iteration
      res.add newTree(nkFastAsgn, v, genDefaultCall(v.typ, c, v.info))
  elif sfThread notin v.sym.flags:
    # do not destroy thread vars for now at all for consistency.
    if sfGlobal in v.sym.flags and s.parent == nil: #XXX: Rethink this logic (see tarcmisc.test2)
      c.graph.globalDestructors.add c.genDestroy(v)
    else:
      s.final.add c.genDestroy(v)
  if ri.kind == nkEmpty and c.inLoop > 0:
    res.add moveOrCopy(v, genDefaultCall(v.typ, c, v.info), c, s, isDecl = true)
  elif ri.kind != nkEmpty:
    res.add moveOrCopy(v, ri, c, s, isDecl = true)

proc processScope(c: var Con; s: var Scope; ret: PNode): PNode =
  result = newNodeI(nkStmtList, ret.info)
  if s.vars.len > 0:
    let varSection = newNodeI(nkVarSection, ret.info)
    for tmp in s.vars:
      varSection.add newTree(nkIdentDefs, newSymNode(tmp), newNodeI(nkEmpty, ret.info),
                                                           newNodeI(nkEmpty, ret.info))
    result.add varSection
  if s.wasMoved.len > 0 or s.final.len > 0:
    let finSection = newNodeI(nkStmtList, ret.info)
    for m in s.wasMoved: finSection.add m
    for i in countdown(s.final.high, 0): finSection.add s.final[i]
    if s.needsTry:
      result.add newTryFinally(ret, finSection)
    else:
      result.add ret
      result.add finSection
  else:
    result.add ret

  if s.parent != nil: s.parent[].needsTry = s.parent[].needsTry or s.needsTry

template processScopeExpr(c: var Con; s: var Scope; ret: PNode, processCall: untyped): PNode =
  assert not ret.typ.isEmptyType
  var result = newNodeI(nkStmtListExpr, ret.info)
  # There is a possibility to do this check: s.wasMoved.len > 0 or s.final.len > 0
  # later and use it to eliminate the temporary when theres no need for it, but its
  # tricky because you would have to intercept moveOrCopy at a certain point
  let tmp = c.getTemp(s.parent[], ret.typ, ret.info)
  tmp.sym.flags.incl sfSingleUsedTemp
  let cpy = if hasDestructor(c, ret.typ):
              moveOrCopy(tmp, ret, c, s, isDecl = true)
            else:
              newTree(nkFastAsgn, tmp, p(ret, c, s, normal))

  if s.vars.len > 0:
    let varSection = newNodeI(nkVarSection, ret.info)
    for tmp in s.vars:
      varSection.add newTree(nkIdentDefs, newSymNode(tmp), newNodeI(nkEmpty, ret.info),
                                                           newNodeI(nkEmpty, ret.info))
    result.add varSection
  let finSection = newNodeI(nkStmtList, ret.info)
  for m in s.wasMoved: finSection.add m
  for i in countdown(s.final.high, 0): finSection.add s.final[i]
  if s.needsTry:
    result.add newTryFinally(newTree(nkStmtListExpr, cpy, processCall(tmp, s.parent[])), finSection)
  else:
    result.add cpy
    result.add finSection
    result.add processCall(tmp, s.parent[])

  if s.parent != nil: s.parent[].needsTry = s.parent[].needsTry or s.needsTry

  result

template handleNestedTempl(n, processCall: untyped, willProduceStmt = false) =
  template maybeVoid(child, s): untyped =
    if isEmptyType(child.typ): p(child, c, s, normal)
    else: processCall(child, s)

  case n.kind
  of nkStmtList, nkStmtListExpr:
    # a statement list does not open a new scope
    if n.len == 0: return n
    result = copyNode(n)
    for i in 0..<n.len-1:
      result.add p(n[i], c, s, normal)
    result.add maybeVoid(n[^1], s)

  of nkCaseStmt:
    result = copyNode(n)
    result.add p(n[0], c, s, normal)
    for i in 1..<n.len:
      let it = n[i]
      assert it.kind in {nkOfBranch, nkElse}

      var branch = shallowCopy(it)
      for j in 0 ..< it.len-1:
        branch[j] = copyTree(it[j])
      var ofScope = nestedScope(s)
      branch[^1] = if it[^1].typ.isEmptyType or willProduceStmt:
                     processScope(c, ofScope, maybeVoid(it[^1], ofScope))
                   else:
                     processScopeExpr(c, ofScope, it[^1], processCall)
      result.add branch

  of nkWhileStmt:
    inc c.inLoop
    inc c.inLoopCond
    result = copyNode(n)
    result.add p(n[0], c, s, normal)
    dec c.inLoopCond
    var bodyScope = nestedScope(s)
    let bodyResult = p(n[1], c, bodyScope, normal)
    result.add processScope(c, bodyScope, bodyResult)
    dec c.inLoop

  of nkParForStmt:
    inc c.inLoop
    result = shallowCopy(n)
    let last = n.len-1
    for i in 0..<last-1:
      result[i] = n[i]
    result[last-1] = p(n[last-1], c, s, normal)
    var bodyScope = nestedScope(s)
    let bodyResult = p(n[last], c, bodyScope, normal)
    result[last] = processScope(c, bodyScope, bodyResult)
    dec c.inLoop

  of nkBlockStmt, nkBlockExpr:
    result = copyNode(n)
    result.add n[0]
    var bodyScope = nestedScope(s)
    result.add if n[1].typ.isEmptyType or willProduceStmt:
                 processScope(c, bodyScope, processCall(n[1], bodyScope))
               else:
                 processScopeExpr(c, bodyScope, n[1], processCall)

  of nkIfStmt, nkIfExpr:
    result = copyNode(n)
    for i in 0..<n.len:
      let it = n[i]
      var branch = shallowCopy(it)
      var branchScope = nestedScope(s)
      if it.kind in {nkElifBranch, nkElifExpr}:
        #Condition needs to be destroyed outside of the condition/branch scope
        branch[0] = p(it[0], c, s, normal)

      branch[^1] = if it[^1].typ.isEmptyType or willProduceStmt:
                     processScope(c, branchScope, maybeVoid(it[^1], branchScope))
                   else:
                     processScopeExpr(c, branchScope, it[^1], processCall)
      result.add branch

  of nkTryStmt:
    result = copyNode(n)
    var tryScope = nestedScope(s)
    result.add if n[0].typ.isEmptyType or willProduceStmt:
                 processScope(c, tryScope, maybeVoid(n[0], tryScope))
               else:
                 processScopeExpr(c, tryScope, n[0], maybeVoid)

    for i in 1..<n.len:
      let it = n[i]
      var branch = copyTree(it)
      var branchScope = nestedScope(s)
      branch[^1] = if it[^1].typ.isEmptyType or willProduceStmt or it.kind == nkFinally:
                     processScope(c, branchScope, if it.kind == nkFinally: p(it[^1], c, branchScope, normal)
                                                  else: maybeVoid(it[^1], branchScope))
                   else:
                     processScopeExpr(c, branchScope, it[^1], processCall)
      result.add branch

  of nkWhen: # This should be a "when nimvm" node.
    result = copyTree(n)
    result[1][0] = processCall(n[1][0], s)
  else: assert(false)

proc pRaiseStmt(n: PNode, c: var Con; s: var Scope): PNode =
  if optOwnedRefs in c.graph.config.globalOptions and n[0].kind != nkEmpty:
    if n[0].kind in nkCallKinds:
      let call = p(n[0], c, s, normal)
      result = copyNode(n)
      result.add call
    else:
      let tmp = c.getTemp(s, n[0].typ, n.info)
      var m = c.genCopyNoCheck(tmp, n[0])
      m.add p(n[0], c, s, normal)
      result = newTree(nkStmtList, c.genWasMoved(tmp), m)
      var toDisarm = n[0]
      if toDisarm.kind == nkStmtListExpr: toDisarm = toDisarm.lastSon
      if toDisarm.kind == nkSym and toDisarm.sym.owner == c.owner:
        result.add c.genWasMoved(toDisarm)
      result.add newTree(nkRaiseStmt, tmp)
  else:
    result = copyNode(n)
    if n[0].kind != nkEmpty:
      result.add p(n[0], c, s, sinkArg)
    else:
      result.add copyNode(n[0])
  s.needsTry = true

proc p(n: PNode; c: var Con; s: var Scope; mode: ProcessMode): PNode =
  if n.kind in {nkStmtList, nkStmtListExpr, nkBlockStmt, nkBlockExpr, nkIfStmt,
                nkIfExpr, nkCaseStmt, nkWhen, nkWhileStmt, nkParForStmt, nkTryStmt}:
    template process(child, s): untyped = p(child, c, s, mode)
    handleNestedTempl(n, process)
  elif mode == sinkArg:
    if n.containsConstSeq:
      # const sequences are not mutable and so we need to pass a copy to the
      # sink parameter (bug #11524). Note that the string implementation is
      # different and can deal with 'const string sunk into var'.
      result = passCopyToSink(n, c, s)
    elif n.kind in {nkBracket, nkObjConstr, nkTupleConstr, nkClosure, nkNilLit} +
         nkCallKinds + nkLiterals:
      result = p(n, c, s, consumed)
    elif ((n.kind == nkSym and isSinkParam(n.sym)) or isAnalysableFieldAccess(n, c.owner)) and
        isLastRead(n, c) and not (n.kind == nkSym and isCursor(n, c)):
      # Sinked params can be consumed only once. We need to reset the memory
      # to disable the destructor which we have not elided
      result = destructiveMoveVar(n, c, s)
    elif n.kind in {nkHiddenSubConv, nkHiddenStdConv, nkConv}:
      result = copyTree(n)
      if n.typ.skipTypes(abstractInst-{tyOwned}).kind != tyOwned and
          n[1].typ.skipTypes(abstractInst-{tyOwned}).kind == tyOwned:
        # allow conversions from owned to unowned via this little hack:
        let nTyp = n[1].typ
        n[1].typ = n.typ
        result[1] = p(n[1], c, s, sinkArg)
        result[1].typ = nTyp
      else:
        result[1] = p(n[1], c, s, sinkArg)
    elif n.kind in {nkObjDownConv, nkObjUpConv}:
      result = copyTree(n)
      result[0] = p(n[0], c, s, sinkArg)
    elif n.typ == nil:
      # 'raise X' can be part of a 'case' expression. Deal with it here:
      result = p(n, c, s, normal)
    else:
      # copy objects that are not temporary but passed to a 'sink' parameter
      result = passCopyToSink(n, c, s)
  else:
    case n.kind
    of nkBracket, nkObjConstr, nkTupleConstr, nkClosure, nkCurly:
      # Let C(x) be the construction, 'x' the vector of arguments.
      # C(x) either owns 'x' or it doesn't.
      # If C(x) owns its data, we must consume C(x).
      # If it doesn't own the data, it's harmful to destroy it (double frees etc).
      # We have the freedom to choose whether it owns it or not so we are smart about it
      # and we say, "if passed to a sink we demand C(x) to own its data"
      # otherwise we say "C(x) is just some temporary storage, it doesn't own anything,
      # don't destroy it"
      # but if C(x) is a ref it MUST own its data since we must destroy it
      # so then we have no choice but to use 'sinkArg'.
      let isRefConstr = n.kind == nkObjConstr and n.typ.skipTypes(abstractInst).kind == tyRef
      let m = if isRefConstr: sinkArg
              elif mode == normal: normal
              else: sinkArg

      result = copyTree(n)
      for i in ord(n.kind in {nkObjConstr, nkClosure})..<n.len:
        if n[i].kind == nkExprColonExpr:
          result[i][1] = p(n[i][1], c, s, m)
        elif n[i].kind == nkRange:
          result[i][0] = p(n[i][0], c, s, m)
          result[i][1] = p(n[i][1], c, s, m)
        else:
          result[i] = p(n[i], c, s, m)
      if mode == normal and isRefConstr:
        result = ensureDestruction(result, n, c, s)
    of nkCallKinds:
      let inSpawn = c.inSpawn
      if n[0].kind == nkSym and n[0].sym.magic == mSpawn:
        c.inSpawn.inc
      elif c.inSpawn > 0:
        c.inSpawn.dec

      let parameters = n[0].typ
      let L = if parameters != nil: parameters.len else: 0

      when false:
        var isDangerous = false
        if n[0].kind == nkSym and n[0].sym.magic in {mOr, mAnd}:
          inc c.inDangerousBranch
          isDangerous = true

      result = shallowCopy(n)
      for i in 1..<n.len:
        if i < L and isCompileTimeOnly(parameters[i]):
          result[i] = n[i]
        elif i < L and (isSinkTypeForParam(parameters[i]) or inSpawn > 0):
          result[i] = p(n[i], c, s, sinkArg)
        else:
          result[i] = p(n[i], c, s, normal)

      when false:
        if isDangerous:
          dec c.inDangerousBranch

      if n[0].kind == nkSym and n[0].sym.magic in {mNew, mNewFinalize}:
        result[0] = copyTree(n[0])
        if c.graph.config.selectedGC in {gcHooks, gcArc, gcOrc}:
          let destroyOld = c.genDestroy(result[1])
          result = newTree(nkStmtList, destroyOld, result)
      else:
        result[0] = p(n[0], c, s, normal)
      if canRaise(n[0]): s.needsTry = true
      if mode == normal:
        result = ensureDestruction(result, n, c, s)
    of nkDiscardStmt: # Small optimization
      result = shallowCopy(n)
      if n[0].kind != nkEmpty:
        result[0] = p(n[0], c, s, normal)
      else:
        result[0] = copyNode(n[0])
    of nkVarSection, nkLetSection:
      # transform; var x = y to  var x; x op y  where op is a move or copy
      result = newNodeI(nkStmtList, n.info)
      for it in n:
        var ri = it[^1]
        if it.kind == nkVarTuple and hasDestructor(c, ri.typ):
          let x = lowerTupleUnpacking(c.graph, it, c.owner)
          result.add p(x, c, s, consumed)
        elif it.kind == nkIdentDefs and hasDestructor(c, it[0].typ) and not isCursor(it[0], c):
          for j in 0..<it.len-2:
            let v = it[j]
            if v.kind == nkSym:
              if sfCompileTime in v.sym.flags: continue
              pVarTopLevel(v, c, s, ri, result)
            else:
              if ri.kind == nkEmpty and c.inLoop > 0:
                ri = genDefaultCall(v.typ, c, v.info)
              if ri.kind != nkEmpty:
                result.add moveOrCopy(v, ri, c, s, isDecl = false)
        else: # keep the var but transform 'ri':
          var v = copyNode(n)
          var itCopy = copyNode(it)
          for j in 0..<it.len-1:
            itCopy.add it[j]
          itCopy.add p(it[^1], c, s, normal)
          v.add itCopy
          result.add v
    of nkAsgn, nkFastAsgn:
      if hasDestructor(c, n[0].typ) and n[1].kind notin {nkProcDef, nkDo, nkLambda} and
          not isCursor(n[0], c):
        if n[0].kind in {nkDotExpr, nkCheckedFieldExpr}:
          cycleCheck(n, c)
        assert n[1].kind notin {nkAsgn, nkFastAsgn}
        result = moveOrCopy(p(n[0], c, s, mode), n[1], c, s)
      elif isDiscriminantField(n[0]):
        result = c.genDiscriminantAsgn(s, n)
      else:
        result = copyNode(n)
        result.add p(n[0], c, s, mode)
        result.add p(n[1], c, s, consumed)
    of nkRaiseStmt:
      result = pRaiseStmt(n, c, s)
    of nkWhileStmt:
      internalError(c.graph.config, n.info, "nkWhileStmt should have been handled earlier")
      result = n
    of nkNone..nkNilLit, nkTypeSection, nkProcDef, nkConverterDef,
       nkMethodDef, nkIteratorDef, nkMacroDef, nkTemplateDef, nkLambda, nkDo,
       nkFuncDef, nkConstSection, nkConstDef, nkIncludeStmt, nkImportStmt,
       nkExportStmt, nkPragma, nkCommentStmt, nkBreakState,
       nkTypeOfExpr, nkMixinStmt, nkBindStmt:
      result = n

    of nkStringToCString, nkCStringToString, nkChckRangeF, nkChckRange64, nkChckRange, nkPragmaBlock:
      result = shallowCopy(n)
      for i in 0 ..< n.len:
        result[i] = p(n[i], c, s, normal)
      if n.typ != nil and hasDestructor(c, n.typ):
        if mode == normal:
          result = ensureDestruction(result, n, c, s)

    of nkHiddenSubConv, nkHiddenStdConv, nkConv:
      # we have an "ownership invariance" for all constructors C(x).
      # See the comment for nkBracket construction. If the caller wants
      # to own 'C(x)', it really wants to own 'x' too. If it doesn't,
      # we need to destroy 'x' but the function call handling ensures that
      # already.
      result = copyTree(n)
      if n.typ.skipTypes(abstractInst-{tyOwned}).kind != tyOwned and
          n[1].typ.skipTypes(abstractInst-{tyOwned}).kind == tyOwned:
        # allow conversions from owned to unowned via this little hack:
        let nTyp = n[1].typ
        n[1].typ = n.typ
        result[1] = p(n[1], c, s, mode)
        result[1].typ = nTyp
      else:
        result[1] = p(n[1], c, s, mode)

    of nkObjDownConv, nkObjUpConv:
      result = copyTree(n)
      result[0] = p(n[0], c, s, mode)

    of nkDotExpr:
      result = shallowCopy(n)
      result[0] = p(n[0], c, s, normal)
      for i in 1 ..< n.len:
        result[i] = n[i]
      if mode == sinkArg and hasDestructor(c, n.typ):
        if isAnalysableFieldAccess(n, c.owner) and isLastRead(n, c):
          s.wasMoved.add c.genWasMoved(n)
        else:
          result = passCopyToSink(result, c, s)

    of nkBracketExpr, nkAddr, nkHiddenAddr, nkDerefExpr, nkHiddenDeref:
      result = shallowCopy(n)
      for i in 0 ..< n.len:
        result[i] = p(n[i], c, s, normal)
      if mode == sinkArg and hasDestructor(c, n.typ):
        if isAnalysableFieldAccess(n, c.owner) and isLastRead(n, c):
          # consider 'a[(g; destroy(g); 3)]', we want to say 'wasMoved(a[3])'
          # without the junk, hence 'c.genWasMoved(n)'
          # and not 'c.genWasMoved(result)':
          s.wasMoved.add c.genWasMoved(n)
        else:
          result = passCopyToSink(result, c, s)

    of nkDefer, nkRange:
      result = shallowCopy(n)
      for i in 0 ..< n.len:
        result[i] = p(n[i], c, s, normal)

    of nkBreakStmt:
      s.needsTry = true
      result = n
    of nkReturnStmt:
      result = shallowCopy(n)
      for i in 0..<n.len:
        result[i] = p(n[i], c, s, mode)
      s.needsTry = true
    of nkCast:
      result = shallowCopy(n)
      result[0] = n[0]
      result[1] = p(n[1], c, s, mode)
    of nkCheckedFieldExpr:
      result = shallowCopy(n)
      result[0] = p(n[0], c, s, mode)
      for i in 1..<n.len:
        result[i] = n[i]
    of nkGotoState, nkState, nkAsmStmt:
      result = n
    else:
      internalError(c.graph.config, n.info, "cannot inject destructors to node kind: " & $n.kind)

proc moveOrCopy(dest, ri: PNode; c: var Con; s: var Scope, isDecl = false): PNode =
  case ri.kind
  of nkCallKinds:
    result = c.genSink(dest, p(ri, c, s, consumed), isDecl)
  of nkBracketExpr:
    if isUnpackedTuple(ri[0]):
      # unpacking of tuple: take over the elements
      result = c.genSink(dest, p(ri, c, s, consumed), isDecl)
    elif isAnalysableFieldAccess(ri, c.owner) and isLastRead(ri, c) and
        not aliases(dest, ri):
      # Rule 3: `=sink`(x, z); wasMoved(z)
      var snk = c.genSink(dest, ri, isDecl)
      result = newTree(nkStmtList, snk, c.genWasMoved(ri))
    else:
      result = c.genCopy(dest, ri)
      result.add p(ri, c, s, consumed)
  of nkBracket:
    # array constructor
    if ri.len > 0 and isDangerousSeq(ri.typ):
      result = c.genCopy(dest, ri)
      result.add p(ri, c, s, consumed)
    else:
      result = c.genSink(dest, p(ri, c, s, consumed), isDecl)
  of nkObjConstr, nkTupleConstr, nkClosure, nkCharLit..nkNilLit:
    result = c.genSink(dest, p(ri, c, s, consumed), isDecl)
  of nkSym:            
    if dest.kind == nkSym and dest.sym == ri.sym:
      # rule (self-assignment-removal):
      result = newNodeI(nkEmpty, dest.info)
    elif isSinkParam(ri.sym) and isLastRead(ri, c):
      # Rule 3: `=sink`(x, z); wasMoved(z)
      let snk = c.genSink(dest, ri, isDecl)
      result = newTree(nkStmtList, snk, c.genWasMoved(ri))
    elif ri.sym.kind != skParam and ri.sym.owner == c.owner and
        isLastRead(ri, c) and canBeMoved(c, dest.typ) and not isCursor(ri, c):
      # Rule 3: `=sink`(x, z); wasMoved(z)
      let snk = c.genSink(dest, ri, isDecl)
      result = newTree(nkStmtList, snk, c.genWasMoved(ri))
    else:
      result = c.genCopy(dest, ri)
      result.add p(ri, c, s, consumed)
  of nkHiddenSubConv, nkHiddenStdConv, nkConv, nkObjDownConv, nkObjUpConv:
    result = c.genSink(dest, p(ri, c, s, sinkArg), isDecl)
  of nkStmtListExpr, nkBlockExpr, nkIfExpr, nkCaseStmt, nkTryStmt:
    template process(child, s): untyped = moveOrCopy(dest, child, c, s, isDecl)
    # We know the result will be a stmt so we use that fact to optimize
    handleNestedTempl(ri, process, willProduceStmt = true)
  of nkRaiseStmt:
    result = pRaiseStmt(ri, c, s)
  else:
    if isAnalysableFieldAccess(ri, c.owner) and isLastRead(ri, c) and
        canBeMoved(c, dest.typ):
      # Rule 3: `=sink`(x, z); wasMoved(z)
      let snk = c.genSink(dest, ri, isDecl)
      result = newTree(nkStmtList, snk, c.genWasMoved(ri))
    else:
      result = c.genCopy(dest, ri)
      result.add p(ri, c, s, consumed)

proc computeUninit(c: var Con) =
  if not c.uninitComputed:
    c.uninitComputed = true
    c.uninit = initIntSet()
    var init = initIntSet()
    discard initialized(c.g, pc = 0, init, c.uninit, int.high)

proc injectDefaultCalls(n: PNode, c: var Con) =
  case n.kind
  of nkVarSection, nkLetSection:
    for it in n:
      if it.kind == nkIdentDefs and it[^1].kind == nkEmpty:
        computeUninit(c)
        for j in 0..<it.len-2:
          let v = it[j]
          doAssert v.kind == nkSym
          if c.uninit.contains(v.sym.id):
            it[^1] = genDefaultCall(v.sym.typ, c, v.info)
            break
  of nkNone..nkNilLit, nkTypeSection, nkProcDef, nkConverterDef, nkMethodDef,
      nkIteratorDef, nkMacroDef, nkTemplateDef, nkLambda, nkDo, nkFuncDef:
    discard
  else:
    for i in 0..<n.safeLen:
      injectDefaultCalls(n[i], c)

proc injectDestructorCalls*(g: ModuleGraph; owner: PSym; n: PNode): PNode =
  if sfGeneratedOp in owner.flags or (owner.kind == skIterator and isInlineIterator(owner.typ)):
    return n
  var c = Con(owner: owner, graph: g, g: constructCfg(owner, n))
  dbg:
    echo "\n### ", owner.name.s, ":\nCFG:"
    echoCfg(c.g)
    echo n

  if optCursorInference in g.config.options:
    computeCursors(owner, n, g.config)

  var scope: Scope
  let body = p(n, c, scope, normal)

  if owner.kind in {skProc, skFunc, skMethod, skIterator, skConverter}:
    let params = owner.typ.n
    for i in 1..<params.len:
      let t = params[i].sym.typ
      if isSinkTypeForParam(t) and hasDestructor(c, t.skipTypes({tySink})):
        scope.final.add c.genDestroy(params[i])
  #if optNimV2 in c.graph.config.globalOptions:
  #  injectDefaultCalls(n, c)
  result = optimize processScope(c, scope, body)
  dbg:
    echo ">---------transformed-to--------->"
    echo renderTree(result, {renderIds})

  if g.config.arcToExpand.hasKey(owner.name.s):
    echo "--expandArc: ", owner.name.s
    echo renderTree(result, {renderIr, renderNoComments})
    echo "-- end of expandArc ------------------------"
