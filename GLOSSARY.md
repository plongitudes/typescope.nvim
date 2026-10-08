# typescope

typescope opens a float that breaks a callable's signature down into its parameters, fields, and return type, so you can read a type without leaving the call site.

## The float

**Header**:
The signature at the top of the float, for the overload group the cursor is in. It stays put while the outline scrolls.
_Avoid_: title, signature line

**Outline**:
The expandable rows that break the callable down into its parameters, fields, members, and return type.
_Avoid_: ledger, tree, rows

**Inspector**:
The section below the outline that shows the outline row under the cursor in full.
_Avoid_: panel, detail panel, row detail

**Docstring view**:
The callable's full docstring, shown in place of the inspector while the outline stays visible.
_Avoid_: doc overlay, doc mode

**Help view**:
The list of float keys, shown in place of the inspector.
_Avoid_: help overlay

## Overloads

**Overload group**:
One overload of an overloaded callable, together with its parameters, counted as `[i/n]`.
_Avoid_: signature, variant

**Matched overload**:
The overload group the call at the cursor actually resolves to.
_Avoid_: active signature, selected overload
