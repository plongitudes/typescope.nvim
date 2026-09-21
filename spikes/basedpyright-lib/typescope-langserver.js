#!/usr/bin/env node
// Spike 2 addendum: basedpyright's own language server, started in THIS
// process, with one extra request registered on the same connection:
//
//   typescope/structure  { textDocument: { uri }, position: { line, character } }
//     -> { kind, name, printed, members?: [...], params?: [...], returns? }
//
// No fork, no second process, no second analysis: the handler runs against
// the same Program every hover already uses. Everything basedpyright does
// (hover, definition, completion, diagnostics) is unchanged.
//
//   node typescope-langserver.js --stdio

const path = require('path');
const INTERNAL = path.resolve(__dirname, 'src/packages/pyright-internal');
global.__rootDirectory = INTERNAL;
const OUT = path.join(INTERNAL, 'out/packages/pyright-internal/src');
const req = (m) => require(path.join(OUT, m));

const { PyrightServer } = req('server');
const { run } = req('nodeServer');
const { BackgroundAnalysisRunner } = req('backgroundAnalysis');
const { ServiceProvider } = req('common/serviceProvider');
const { convertPositionToOffset } = req('common/positionUtils');
const ParseTreeUtils = req('analyzer/parseTreeUtils');
const Types = req('analyzer/types');
const TypeUtils = req('analyzer/typeUtils');
const { ClassType, FunctionType, OverloadedType } = Types;

// ---- the structure walk (probe.js, trimmed to a JSON shape) -------------
function structure(program, uri, position) {
  const evaluator = program.evaluator;
  const parseResults = program.getParseResults(uri);
  if (!parseResults) return null;
  const offset = convertPositionToOffset(position, parseResults.tokenizerOutput.lines);
  const node = ParseTreeUtils.findNodeByOffset(parseResults.parserOutput.parseTree, offset);
  if (!node) return null;
  let t = evaluator.getType(node);
  if (!t && node.parent) {
    if (node.parent.nodeType === 31) t = evaluator.getTypeOfFunction(node.parent)?.decoratedType;
    else if (node.parent.nodeType === 10) t = evaluator.getTypeOfClass(node.parent)?.decoratedType;
  }
  if (!t) return null;
  const p = (x) => (x ? evaluator.printType(x) : null);

  function loc(x) {
    const d = x.shared && x.shared.declaration;
    return d && d.uri ? { uri: String(d.uri), line: d.range.start.line } : undefined;
  }
  function cls(c, depth) {
    const members = [];
    const seen = new Set();
    for (const mro of c.shared.mro) {
      if (!Types.isInstantiableClass(mro) || ClassType.isBuiltIn(mro, 'object')) continue;
      const origin = mro.shared.name === c.shared.name ? undefined : mro.shared.name;
      ClassType.getSymbolTable(mro).forEach((symbol, name) => {
        if (seen.has(name) || name.startsWith('_')) return;
        if (!symbol.isClassMember() && !symbol.isInstanceMember()) return;
        seen.add(name);
        const m = TypeUtils.lookUpClassMember(c, name);
        if (!m) return;
        const mt = evaluator.getTypeOfMember(m);
        let kind = 'field';
        let shown = mt;
        if (Types.isClassInstance(mt) && ClassType.isPropertyClass(mt)) {
          kind = 'property';
          const fget = mt.priv.fgetInfo && mt.priv.fgetInfo.methodType;
          shown = fget ? FunctionType.getEffectiveReturnType(fget) || evaluator.getInferredReturnType(fget) : undefined;
        } else if (Types.isClassInstance(mt) && mt.priv.literalValue !== undefined && ClassType.isEnumClass(c)) {
          kind = 'enum_member';
        } else if (Types.isFunction(mt) || Types.isOverloaded(mt)) {
          kind = 'method';
        }
        members.push({
          name,
          kind,
          origin,
          type: p(shown),
          inferred: !symbol.hasTypedDeclarations() || undefined,
          // one level of nesting for the spike; a real oracle takes depth from the request
          children: depth > 0 && shown && Types.isClassInstance(shown) && !ClassType.isBuiltIn(shown) ? cls(shown, depth - 1).members : undefined,
        });
      });
    }
    return {
      kind: Types.isClassInstance(c) ? 'instance' : 'class',
      name: c.shared.name,
      printed: p(c),
      category: ClassType.isDataClass(c) ? 'dataclass' : ClassType.isEnumClass(c) ? 'enum' : ClassType.isTypedDictClass(c) ? 'typeddict' : ClassType.isProtocolClass(c) ? 'protocol' : 'class',
      typeArgs: c.priv.typeArgs ? c.priv.typeArgs.map(p) : undefined,
      location: loc(c),
      members,
    };
  }
  function fn(f) {
    const params = [];
    f.shared.parameters.forEach((prm, i) => {
      if (!prm.name) return;
      params.push({
        name: prm.name,
        type: p(FunctionType.getParamType(f, i)),
        default: p(FunctionType.getParamDefaultType(f, i)) || undefined,
        declared: (prm.flags & Types.FunctionParamFlags.TypeDeclared) !== 0,
      });
    });
    const declared = f.shared.declaredReturnType;
    return {
      kind: 'function',
      name: f.shared.name,
      printed: p(f),
      location: loc(f),
      params,
      returns: p(declared || evaluator.getInferredReturnType(f)),
      returnsInferred: !declared || undefined,
    };
  }
  function any(x) {
    if (Types.isUnion(x)) return { kind: 'union', printed: p(x), members: x.priv.subtypes.map(any) };
    if (Types.isClass(x)) return cls(x, 1);
    if (Types.isOverloaded(x)) return { kind: 'overloaded', printed: p(x), overloads: OverloadedType.getOverloads(x).map(fn) };
    if (Types.isFunction(x)) return fn(x);
    return { kind: 'other', printed: p(x) };
  }
  return any(t);
}

// ---- the server: basedpyright + one request ---------------------------
class TypeScopeServer extends PyrightServer {
  setupConnection(supportedCommands, supportedCodeActions) {
    super.setupConnection(supportedCommands, supportedCodeActions);
    this.connection.onRequest('typescope/structure', async (params, token) => {
      const uri = this.convertLspUriStringToUri(params.textDocument.uri);
      const workspace = await this.getWorkspaceForFile(uri);
      return workspace.service.run((program) => structure(program, uri, params.position), token);
    });
  }
}

run(
  (conn) => new TypeScopeServer(conn, /* maxWorkers */ 0),
  () => {
    const runner = new BackgroundAnalysisRunner(new ServiceProvider());
    runner.start();
  }
);
