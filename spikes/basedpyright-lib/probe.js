// Spike 1 probe: drive basedpyright's Program + TypeEvaluator directly, no
// language server, and print STRUCTURE for each fixture target.
//
// Run from this directory:  node probe.js
// Requires: src/ = basedpyright checkout at v1.40.1, pyright-internal built
// with `pnpm exec tsc` (output under src/packages/pyright-internal/out).

const path = require('path');
const fs = require('fs');

const INTERNAL = path.resolve(__dirname, 'src/packages/pyright-internal');
// typeshed-fallback is located relative to this global (see realFileSystem.ts)
global.__rootDirectory = INTERNAL;
const OUT = path.join(INTERNAL, 'out/packages/pyright-internal/src');
const req = (m) => require(path.join(OUT, m));

const { ImportResolver } = req('analyzer/importResolver');
const { Program } = req('analyzer/program');
const { ConfigOptions } = req('common/configOptions');
const { NullConsole } = req('common/console');
const { FullAccessHost } = req('common/fullAccessHost');
const { RealTempFile, createFromRealFileSystem } = req('common/realFileSystem');
const { createServiceProvider } = req('common/serviceProviderExtensions');
const { Uri } = req('common/uri/uri');
const { UriEx } = req('common/uri/uriUtils');
const { convertOffsetToPosition } = req('common/positionUtils');
const ParseTreeUtils = req('analyzer/parseTreeUtils');
const Types = req('analyzer/types');
const TypeUtils = req('analyzer/typeUtils');
const { ClassType, FunctionType, OverloadedType } = Types;

// ---------------------------------------------------------------- program
const fixtureDir = path.resolve(__dirname, 'fixture');
const fixturePath = path.join(fixtureDir, 'probe_fixture.py');
const source = fs.readFileSync(fixturePath, 'utf8');

const t0 = Date.now();
const tempFile = new RealTempFile();
const realFs = createFromRealFileSystem(tempFile);
const sp = createServiceProvider(realFs, new NullConsole(), tempFile);
const config = new ConfigOptions(Uri.file(fixtureDir, sp));
config.projectRoot = Uri.file(fixtureDir, sp);
const importResolver = new ImportResolver(sp, config, new FullAccessHost(sp));
const program = new Program(importResolver, config, sp);
const fileUri = UriEx.file(fixturePath);
program.setTrackedFiles([fileUri]);
while (program.analyze()) {
  /* drain */
}
const evaluator = program.evaluator;
const parseResults = program.getParseResults(fileUri);
const lines = parseResults.tokenizerOutput.lines;
console.log(`program ready in ${Date.now() - t0} ms; rss ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB\n`);

// ---------------------------------------------------------------- helpers
const printType = (t) => (t ? evaluator.printType(t) : '<none>');

function offsetOf(needle, nth = 0) {
  let idx = -1;
  for (let i = 0; i <= nth; i++) {
    idx = source.indexOf(needle, idx + 1);
    if (idx < 0) throw new Error(`needle not found: ${needle}`);
  }
  return idx;
}

function nameOf(t) {
  if (Types.isClass(t)) return t.shared.name;
  if (Types.isFunction(t)) return t.shared.name;
  return printType(t);
}

function declLoc(t) {
  const d = Types.isClass(t) || Types.isFunction(t) ? t.shared.declaration : undefined;
  if (!d || !d.uri) return '';
  const p = d.range ? `${d.range.start.line + 1}:${d.range.start.character}` : '?';
  return ` @ ${path.basename(d.uri.key || String(d.uri))}:${p}`;
}

// Members of a class, own first then MRO order, each with the type already
// specialized against the class's type args (getTypeOfMember does that).
function describeClass(cls, indent = '  ') {
  const out = [];
  const flags = [];
  if (ClassType.isDataClass(cls)) flags.push('dataclass');
  if (ClassType.isEnumClass(cls)) flags.push('enum');
  if (ClassType.isTypedDictClass(cls)) flags.push('typeddict');
  if (ClassType.isProtocolClass(cls)) flags.push('protocol');
  const typeArgs = cls.priv.typeArgs ? cls.priv.typeArgs.map(printType) : [];
  const typeParams = cls.shared.typeParams.map((tp) => tp.shared.name);
  out.push(
    `${indent}class ${cls.shared.name}${typeParams.length ? `[${typeParams.join(', ')}]` : ''}` +
      `${typeArgs.length ? ` specialized [${typeArgs.join(', ')}]` : ''}` +
      `${flags.length ? ` (${flags.join(', ')})` : ''}${declLoc(cls)}`
  );
  const bases = cls.shared.baseClasses.filter(Types.isClass).map((b) => b.shared.name);
  if (bases.length) out.push(`${indent}  bases: ${bases.join(', ')}`);

  const seen = new Set();
  for (const mroClass of cls.shared.mro) {
    if (!Types.isInstantiableClass(mroClass)) continue;
    if (ClassType.isBuiltIn(mroClass, 'object')) continue;
    const origin = mroClass.shared.name === cls.shared.name ? '' : ` ↑${mroClass.shared.name}`;
    ClassType.getSymbolTable(mroClass).forEach((symbol, name) => {
      if (seen.has(name)) return;
      if (name.startsWith('__') || symbol.isIgnoredForProtocolMatch()) return;
      if (!symbol.isClassMember() && !symbol.isInstanceMember()) return;
      seen.add(name);
      const member = TypeUtils.lookUpClassMember(cls, name);
      if (!member) return;
      const mt = evaluator.getTypeOfMember(member);
      const tags = [];
      if (member.isInstanceMember) tags.push('instance');
      if (member.isClassVar) tags.push('ClassVar');
      if (member.isReadOnly) tags.push('readonly');
      if (!symbol.hasTypedDeclarations()) tags.push('inferred');
      let shown;
      if (Types.isClassInstance(mt) && ClassType.isPropertyClass(mt)) {
        const fget = mt.priv.fgetInfo && mt.priv.fgetInfo.methodType;
        const rt = fget ? FunctionType.getEffectiveReturnType(fget) || evaluator.getInferredReturnType(fget) : undefined;
        tags.push('property');
        shown = printType(rt);
      } else if (Types.isClassInstance(mt) && mt.priv.literalValue !== undefined && ClassType.isEnumClass(cls)) {
        tags.push('enum member');
        const lit = mt.priv.literalValue;
        shown = `= ${lit.itemType ? printType(lit.itemType) : ''} ${JSON.stringify(lit.itemName ?? lit)}`;
      } else if (Types.isFunction(mt) || Types.isOverloaded(mt)) {
        tags.push('method');
        shown = printType(mt);
      } else {
        shown = printType(mt);
      }
      out.push(`${indent}  · ${name}${origin}  ${shown}${tags.length ? `   [${tags.join(', ')}]` : ''}`);
    });
  }
  return out.join('\n');
}

function describeFunction(fn, indent = '  ') {
  const out = [`${indent}def ${fn.shared.name}${declLoc(fn)}`];
  fn.shared.parameters.forEach((p, i) => {
    if (!p.name) return; // bare `*` / `/` separators
    const cat = p.category === 1 ? '*' : p.category === 2 ? '**' : '';
    const declared = (p.flags & Types.FunctionParamFlags.TypeDeclared) !== 0;
    const pt = FunctionType.getParamType(fn, i);
    const dt = FunctionType.getParamDefaultType(fn, i);
    out.push(`${indent}  · ${cat}${p.name}  ${printType(pt)}${declared ? '' : '   [inferred]'}${dt ? `  = ${printType(dt)}` : ''}`);
  });
  const declaredRet = fn.shared.declaredReturnType;
  const ret = declaredRet || evaluator.getInferredReturnType(fn);
  out.push(`${indent}  · returns  ${printType(ret)}${declaredRet ? '' : '   [inferred]'}`);
  return out.join('\n');
}

function describe(t, indent = '  ') {
  if (Types.isUnion(t)) {
    return [`${indent}union`].concat(t.priv.subtypes.map((s) => describe(s, indent + '  '))).join('\n');
  }
  if (Types.isClass(t)) {
    const inst = Types.isClassInstance(t);
    return `${indent}${inst ? 'instance of' : 'class object'}\n` + describeClass(t, indent);
  }
  if (Types.isOverloaded(t)) {
    return [`${indent}overloaded`].concat(OverloadedType.getOverloads(t).map((o) => describeFunction(o, indent + '  '))).join('\n');
  }
  if (Types.isFunction(t)) return describeFunction(t, indent);
  if (Types.isTypeVar(t)) return `${indent}typevar ${t.shared.name}`;
  return `${indent}${t.category !== undefined ? 'category ' + t.category + ' ' : ''}${printType(t)}`;
}

// ---------------------------------------------------------------- targets
const targets = [
  { label: 'def use(...) — function under cursor', needle: 'def use(', skip: 4 },
  { label: 'b: Box[ServerConfig] — generic with T substituted?', needle: 'b: Box[ServerConfig]' },
  { label: 'c: Color — enum members?', needle: 'c: Color' },
  { label: 'd: Derived — inherited fields with origin?', needle: 'd: Derived' },
  { label: 'resp = fetch("x") — unannotated local, structure not prose?', needle: 'resp = fetch' },
  { label: 'return resp — the same local at a use site', needle: 'return resp', skip: 7 },
  { label: 'n = first([1,2,3]) — TypeVar solved at the call site?', needle: 'n = first' },
  { label: 'def first — TypeVar unsolved at the def', needle: 'def first', skip: 4 },
  { label: 'maybe = fetch_maybe() — declared union, before narrowing', needle: 'maybe = fetch_maybe' },
  { label: 'narrowed = maybe — narrowing inside `if maybe is not None`', needle: 'narrowed = maybe', skip: 11 },
  { label: 'Response.ok — property', needle: 'def ok(', skip: 4 },
];

for (const tgt of targets) {
  const offset = offsetOf(tgt.needle) + (tgt.skip || 0);
  const pos = convertOffsetToPosition(offset, lines);
  const node = ParseTreeUtils.findNodeByOffset(parseResults.parserOutput.parseTree, offset);
  console.log(`== ${tgt.label}   (${pos.line + 1}:${pos.character}, node ${node ? node.nodeType : '?'})`);
  if (!node) {
    console.log('  <no node>\n');
    continue;
  }
  let t = evaluator.getType(node);
  if (!t) {
    // a `def` name or a class name is not an expression: ask via its declaration node
    const parent = node.parent;
    if (parent && parent.nodeType === 31 /* Function */) t = evaluator.getTypeOfFunction(parent)?.decoratedType;
    else if (parent && parent.nodeType === 10 /* Class */) t = evaluator.getTypeOfClass(parent)?.decoratedType;
  }
  if (!t) {
    console.log('  <no type>\n');
    continue;
  }
  console.log(`  control (printType): ${printType(t)}`);
  console.log(describe(t));
  console.log();
}
console.log(`done; rss ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB`);
