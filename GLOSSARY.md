# typescope

typescope opens a float that breaks a callable's signature down into its parameters, fields, and return type, so you can read a type without leaving the call site.

## The float

**Frame**:
The stacked panes that make up the float, placed together on one side of the cursor. The side is fixed when the float opens.
_Avoid_: window, box

**Pane**:
One window in the frame: the header, the outline, or the loupe.
_Avoid_: section, box

**Seam**:
The two-row border pair (a pane's bottom border, the next pane's top border) between two panes.
_Avoid_: separator, divider

**Loupe**:
The bottom pane of the frame. It shows the inspector or the docstring view; the help view is drawn over the frame, not in it.
_Avoid_: slot, detail pane, panel

**Header**:
The signature at the top of the float, for the overload group the cursor is in, wrapped to fit. It stays put while the outline scrolls, and its height is fixed at the tallest group's so the outline never shifts.
_Avoid_: title, signature line

**Outline**:
The expandable rows that break the callable down into its parameters, fields, members, and return type.
_Avoid_: ledger, tree, rows

**Inspector**:
The view in the loupe that shows the outline row under the cursor in full.
_Avoid_: panel, detail panel, row detail

**Docstring view**:
The callable's full docstring, shown in the loupe in place of the inspector while the outline stays visible.
_Avoid_: doc overlay, doc mode

**Help view**:
The list of float keys, titled `typescope help`, drawn over the float rather than in place of a pane. It grows away from the line of code being worked on, and the panes under it keep their sizes.
_Avoid_: help overlay

## Overloads

**Overload group**:
One overload of an overloaded callable, together with its parameters, counted as `[i/n]`.
_Avoid_: signature, variant

**Matched overload**:
The overload group the call at the cursor actually resolves to. Marked `✓` beside the header's `[i/n]`.
_Avoid_: active signature, selected overload
