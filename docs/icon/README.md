# App icon sources

`red.icon` is the shipping master and `cobalt.icon` is an alternate. Both are
Icon Composer documents that reuse the original arrow and bars as SVG geometry.
Native fill specializations tint the bars subtly gray on the light background
and white on charcoal.

To change the icon, edit the chosen master, then copy it over
`App/Resources/AppIcon.icon`. The Xcode project compiles that folder as
`AppIcon`; no runtime bitmap override is needed. Build and signing steps are in
[`BUILD.md`](../../BUILD.md).
