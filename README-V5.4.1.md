# DuoPhone V5.4.1 — Build Fix

Fixes the three compiler errors shown by GitHub Actions:

- undeclared identifier `DPV54ApplyGeometry`
- undeclared identifier `left`
- undeclared identifier `right`

No architecture change from V5.4.
The geometry fix remains the same; this patch only makes the source compile cleanly under `-Werror`.
