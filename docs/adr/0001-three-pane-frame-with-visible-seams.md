# The float is a frame of three panes with visible seams

The K float is three windows (header, outline, loupe) placed together by one routine on a side of the cursor chosen at open, with every seam drawn as a full bottom border followed by a full top border, two rows, in the user's border style. This reverses typescope.nvim-930, which joined two windows (outline + inspector) with a `├─┤` separator and moved the docstring into a one-line footer: that saved rows but meant the signature scrolled away with the outline and the outline and docstring could never be read together. The header now has to stay put while the outline scrolls, and the docstring has to sit beside the outline, so a third window was unavoidable; the seams are deliberately separate-looking because the panes do separate jobs, and the extra row per seam is the accepted cost.

## Considered options

- **Signature in the top-border title.** Costs no rows, but a border title can't wrap and gets cut at the corner, which fails exactly the long overloaded signatures the header is for.
- **Three windows joined by `├─┤`.** One row per seam instead of two, but reads as one box; rejected for the look, not the mechanics.
- **Three independently placed boxes.** Same look as chosen, but three placements to keep aligned when the frame flips sides. Floats can't share a border, and nvim's fit-on-screen nudge moves one window without the others (930's notes), so the panes are placed together and the boxes are an appearance only.

## Consequences

- The help view is not a pane: it is an overlay drawn over the frame, so opening it never resizes the panes under it.
- Frame growth (docstring view, help) always moves away from the line of code at the cursor, never over it.
