// Spike 2, sidecar side: a resident Program + TypeEvaluator over the SAME
// project and file as measure_langserver.lua, answering the same ten
// queries, with physical footprint sampled at the same points.
//
//   node measure_sidecar.js            (from this directory)
//
// Memory is read with footprint(1), not process.memoryUsage().rss: under
// memory pressure macOS compresses idle pages and rss stops counting them.

const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');

const t_process = Date.now();
const INTERNAL = path.resolve(__dirname, 'src/packages/pyright-internal');
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
const ParseTreeUtils = req('analyzer/parseTreeUtils');
const Types = req('analyzer/types');
const TypeUtils = req('analyzer/typeUtils');
const { ClassType } = Types;

const spec = JSON.parse(fs.readFileSync(path.join(__dirname, 'targets.json'), 'utf8'));
const root = spec.project_root;
const filePath = path.join(root, spec.file);
const source = fs.readFileSync(filePath, 'utf8');
const lines = source.split('\n');

function footprint() {
  const out = execFileSync('footprint', ['-p', String(process.pid)], { encoding: 'utf8' });
  const cur = Number((out.match(/phys_footprint:\s*([\d.]+)\s*MB/) || [])[1] || 0);
  const peak = Number((out.match(/phys_footprint_peak:\s*([\d.]+)\s*MB/) || [])[1] || 0);
  return { cur: Math.round(cur), peak: Math.round(peak) };
}
const log = (...a) => console.error('[sc]', ...a);

// ------------------------------------------------------------ program
const t0 = Date.now();
const tempFile = new RealTempFile();
const realFs = createFromRealFileSystem(tempFile);
const sp = createServiceProvider(realFs, new NullConsole(), tempFile);
const host = new FullAccessHost(sp);
const rootUri = Uri.file(root, sp);
const config = new ConfigOptions(rootUri);
config.projectRoot = rootUri;
// the project's own pyrightconfig.json: venvPath/venv, pythonVersion, include
const cfgJson = JSON.parse(fs.readFileSync(path.join(root, 'pyrightconfig.json'), 'utf8'));
config.initializeFromJson(cfgJson, rootUri, sp, host);
config.ensureDefaultPythonVersion(host, new NullConsole());
config.ensureDefaultPythonPlatform(host, new NullConsole());
const importResolver = new ImportResolver(sp, config, host);
const program = new Program(importResolver, config, sp);

// what a hover-serving process does: open the ONE file the user is in;
// imports are resolved and bound lazily as queries touch them
const fileUri = UriEx.file(filePath);
program.setFileOpened(fileUri, 1, source);
const sourceFile = program.getBoundSourceFile(fileUri);
const parseResults = sourceFile.getParseResults();
const evaluator = program.evaluator;
const t_ready = Date.now();
const fp_ready = footprint();
log(`program ready ${t_ready - t0} ms (${t_ready - t_process} ms from process start), footprint ${fp_ready.cur} MB`);

// ------------------------------------------------------------ queries
function offsetOf(t) {
  const lineText = lines[t.line - 1];
  const idx = lineText.indexOf(t.needle);
  if (idx < 0) throw new Error(`needle not on line ${t.line}: ${t.needle}`);
  let off = idx + (t.skip || 0);
  for (let i = 0; i < t.line - 1; i++) off += lines[i].length + 1;
  return off;
}

function memberCount(cls) {
  let n = 0;
  const seen = new Set();
  for (const mro of cls.shared.mro) {
    if (!Types.isInstantiableClass(mro) || ClassType.isBuiltIn(mro, 'object')) continue;
    ClassType.getSymbolTable(mro).forEach((symbol, name) => {
      if (seen.has(name) || name.startsWith('_')) return;
      if (!symbol.isClassMember() && !symbol.isInstanceMember()) return;
      seen.add(name);
      const m = TypeUtils.lookUpClassMember(cls, name);
      if (m) {
        evaluator.getTypeOfMember(m); // force the evaluation a real answer would need
        n++;
      }
    });
  }
  return n;
}

function summarize(t) {
  if (!t) return '<no type>';
  if (Types.isUnion(t)) return `union[${t.priv.subtypes.map(summarize).join(' | ')}]`;
  if (Types.isClass(t)) return `${Types.isClassInstance(t) ? 'instance' : 'class'} ${t.shared.name}: ${memberCount(t)} members`;
  if (Types.isOverloaded(t)) return `overloaded x${Types.OverloadedType.getOverloads(t).length}`;
  if (Types.isFunction(t)) return `function ${t.shared.name}: ${t.shared.parameters.filter((p) => p.name).length} params -> ${evaluator.printType(Types.FunctionType.getEffectiveReturnType(t) || evaluator.getInferredReturnType(t))}`;
  return evaluator.printType(t);
}

const timings = [];
spec.targets.forEach((t, i) => {
  const q0 = Date.now();
  const node = ParseTreeUtils.findNodeByOffset(parseResults.parserOutput.parseTree, offsetOf(t));
  let ty = node && evaluator.getType(node);
  if (!ty && node && node.parent) {
    if (node.parent.nodeType === 31) ty = evaluator.getTypeOfFunction(node.parent)?.decoratedType;
    else if (node.parent.nodeType === 10) ty = evaluator.getTypeOfClass(node.parent)?.decoratedType;
  }
  const summary = summarize(ty);
  const ms = Date.now() - q0;
  timings.push(ms);
  log(`query ${i + 1} ${ms} ms: ${summary}`);
});
const fp_after_first = null; // footprint sampled after the loop; the first query dominates
const fp_10 = footprint();
log(`after 10 queries: footprint ${fp_10.cur} MB (peak ${fp_10.peak})`);

// what "typeCheckingMode: off" skips: the checker pass over the open file.
// Measured separately so the sidecar can decide whether to ever run it.
const c0 = Date.now();
while (program.analyze()) {
  /* drain */
}
const fp_checked = footprint();
log(`checker drain ${Date.now() - c0} ms: footprint ${fp_checked.cur} MB (peak ${fp_checked.peak})`);

setTimeout(() => {
  const fp_idle = footprint();
  const result = {
    side: 'sidecar',
    metric: 'phys_footprint via footprint(1)',
    node: process.version,
    ready_ms: t_ready - t0,
    ready_from_process_start_ms: t_ready - t_process,
    first_query_ms: timings[0],
    query_ms: timings,
    footprint_mb: {
      ready: fp_ready.cur,
      after_10_queries: fp_10.cur,
      after_checker_drain: fp_checked.cur,
      after_10s_idle: fp_idle.cur,
      peak: fp_idle.peak,
    },
  };
  console.log(JSON.stringify(result));
  process.exit(0);
}, 10000);
