# DuoPhone V5.5.1 — Build Fix

Fixes the compiler error:

`use of undeclared identifier 'DPV55ApplyDetachedMapsSplit'`

Only change:
- adds a forward declaration for `DPV55ApplyDetachedMapsSplit(UIWindowScene *ws)`

The V5.5 detach-split architecture is unchanged.
