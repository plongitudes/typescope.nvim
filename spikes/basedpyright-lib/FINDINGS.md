# Spike 1 — basedpyright as a library

**Bead:** typescope.nvim-b69 · **Date:** 2026-09-17 · **Verdict: PASS.** All ten fixture targets answered with structure (members, params, type args), not prose. Full output in `probe_output.txt`.

## Versions

- basedpyright **1.40.1** (tracks pyright 1.1.414), tag `v1.40.1`
- node v26.8.2, pnpm 11.21.0 (the workspace's pinned manager), TypeScript ~6.0.3
- Machine: the 8GB M1 Air

## Route that worked

The published npm package is **not** importable: `dist/pyright.js` and `dist/pyright-langserver.js` are self-running rspack IIFEs with no `module.exports`. `@zzzen/pyright-internal` (an unbundled mirror on npm) tracks Microsoft's pyright, not basedpyright, and last moved 2025-12-07 — not a route.

What worked: build `packages/pyright-internal` from a shallow clone of the tag.

```sh
git clone --depth 1 --branch v1.40.1 https://github.com/DetachHead/basedpyright.git src   # 2.5 s
cd src && pnpm install --frozen-lockfile --filter pyright-internal...                       # 10 s
cd packages/pyright-internal && pnpm exec tsc                                              # 10 s, clean
```

Output lands in `out/packages/pyright-internal/src/` (the tsconfig's `rootDir` is the repo root): 625 `.js` files, 18 MB, plain CommonJS, `require`-able by path. `global.__rootDirectory` must point at `packages/pyright-internal` so `typeshed-fallback/` is found (see `common/realFileSystem.ts`).

A sidecar would ship this `out/` tree plus `typeshed-fallback/` plus the runtime deps pnpm installed — the same thing the langserver bundle contains, unbundled. Pinning is by git tag.

## Type Server Protocol: looked at, not the route

The checkout has a `typeServer/` subsystem and `packages/pyright-typeserver` — Microsoft's in-progress **Type Server Protocol (TSP)**, a JSON-RPC protocol for type queries separate from LSP. It is the right idea and worth watching, but as of 1.1.414:

- only three type queries exist (`getComputedType`, `getDeclaredType`, `getExpectedType`), each returning one `Type`
- the wire `ClassType` carries a declaration location and `typeArgs` but **no member list**; the wire `FunctionType` carries `returnType` but no parameters (the doc for `SpecializedFunctionTypes` refers to a `parameters` array that is not in the protocol)
- `pyright-typeserver` is excluded from basedpyright's pnpm workspace ("not supported in basedpyright") and is not in the npm package

`typeServer/typeServerConversionUtils.ts` is a useful reference for how pyright renders internal types to a wire shape, when TypeScope designs its own JSON.

## API names used (basedpyright 1.40.1 — these shift between versions)

Construction, copied from `src/tests/testUtils.ts`'s `createProgram`:

- `common/realFileSystem`: `RealTempFile`, `createFromRealFileSystem`
- `common/serviceProviderExtensions`: `createServiceProvider(fs, console, tempFile)`
- `common/configOptions`: `ConfigOptions(uri)`, set `projectRoot`
- `analyzer/importResolver`: `ImportResolver(sp, config, FullAccessHost(sp))`
- `analyzer/program`: `Program(importResolver, config, sp)`, `.setTrackedFiles([uri])`, `while (program.analyze()) {}`, `.evaluator`, `.getParseResults(uri)`

Query:

- `analyzer/parseTreeUtils.findNodeByOffset(parseTree, offset)`; `common/positionUtils.convertOffsetToPosition`
- `evaluator.getType(exprNode)`; for a `def`/`class` name (not an expression) `evaluator.getTypeOfFunction(node.parent).decoratedType` / `getTypeOfClass(...)`
- `evaluator.printType(t)` — the control; this is what hover renders
- `analyzer/types`: `isClass`, `isClassInstance`, `isInstantiableClass`, `isFunction`, `isOverloaded`, `isUnion`, `isTypeVar`; `ClassType.{isDataClass,isEnumClass,isTypedDictClass,isProtocolClass,isPropertyClass,getSymbolTable,isBuiltIn}`; `FunctionType.{getParamType,getParamDefaultType,getEffectiveReturnType}`; `OverloadedType.getOverloads`; `FunctionParamFlags.TypeDeclared`
- Class internals: `cls.shared.{name,mro,baseClasses,typeParams,declaration}`, `cls.priv.{typeArgs,literalValue,fgetInfo}`; function: `fn.shared.{parameters,declaredReturnType}`; union: `t.priv.subtypes`
- `analyzer/typeUtils.lookUpClassMember(cls, name)` → `ClassMember` with `isInstanceMember`/`isClassVar`/`isReadOnly`; `evaluator.getTypeOfMember(member)` **already specializes against the class's type args** (it calls `partiallySpecializeType` internally) — that is what made `Box[ServerConfig].item` come back as `ServerConfig` with no extra work
- `evaluator.getInferredReturnType(fn)` for unannotated returns; `symbol.hasTypedDeclarations()` distinguishes declared from inferred members
- Symbol filters: `symbol.isClassMember()`, `isInstanceMember()`, `isIgnoredForProtocolMatch()`

## What each target answered (abridged; see probe_output.txt)

| Target | Today (syntax resolver) | Evaluator |
| --- | --- | --- |
| `b: Box[ServerConfig]` | `item T`, ServerConfig as an unrelated sibling variant | `item ServerConfig`, `count int`; class reported as `Box[T] specialized [ServerConfig]` |
| `c: Color` (Enum) | bare leaf, no members | `RED = 1`, `GREEN = 2` tagged enum member; `name`/`value` as properties; Enum internals under `_`-names (filter policy) |
| `d: Derived` | works | `debug`; `host ↑ServerConfig`, `port ↑ServerConfig` |
| `resp = fetch("x")` (unannotated local) | draws the **enclosing function** | `Response` with `status int`, `body bytes`, `parsed dict[str, int] [inferred]`, `ok bool [property]` |
| `return resp` (use site) | enclosing function | same structure as above |
| `n = first([1,2,3])` | n/a | `int` — TypeVar solved at the call site |
| `def first` | `T` | `xs list[T@first] -> T@first` (unsolved at the def, correctly) |
| `maybe = fetch_maybe()` | n/a | union: `Response {…}` and `NoneType` |
| `narrowed = maybe` inside `if maybe is not None` | n/a | `Response` — narrowed |
| `Response.ok` in the class walk | not collected | `ok bool [property]` via `fgetInfo.methodType` |

Gotcha met on the way: the first narrowing fixture was `maybe: Response | None = None`; pyright narrows on the assignment itself, so inside `if maybe is not None:` the type was `Never`. Pyright was right. Use a call with a union return to test narrowing.

## Cost, first numbers (one-file project; spike 2 measures a real one)

- Program construction + full analysis of the fixture (which pulls `builtins.pyi`, `enum.pyi`, `dataclasses.pyi`, `typing.pyi`): **176–191 ms**
- RSS after analysis: **155–159 MB**; ten queries added ~1 MB
- Whole probe wall time: 0.9 s including node startup

## Implications for the design

- The closed-vocabulary claim holds: `describe()` in the probe is ~80 lines and handles class / function / overloaded / union / typevar, and every gap in the review (enum, generics, locals, properties, narrowing, inferred members) fell out of it without a special case.
- `evaluator.getType(node)` on a **use site** gives the narrowed type; on a **declaration** the declared one. The oracle's `structure(file, line, col)` maps straight onto this.
- Enum internals and `object`'s members need a filter policy (`_`-prefix, MRO cut at `object`/`Enum`). That is presentation, and belongs in the oracle or the Lua client, not in pyright.
- Nothing here needed the language server, a workspace, or LSP document sync. A real sidecar will need file-change tracking (`Program.setFileOpened(uri, version, contents)` / `setFileClosed` exist) so unsaved buffers are analysed — not probed here.

## Open for spike 2

RSS and cold start on a real project, alongside a running `basedpyright-langserver`. The 155 MB floor is mostly node + typeshed builtins; the question is how it scales with a site-packages-heavy project.
