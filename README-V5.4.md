# DuoPhone V5.4 — Live Split Geometry Fix

V5.3 succeeded in finding and resizing the real Maps dashboard scene:

`Car[2-3]:com.apple.Maps:dashboard`

The log proves:
- `_UIScenePresentationView` found
- `_UISceneLayerHostContainerView` found
- live split applied

V5.4 fixes the visual geometry to follow the actual draggable divider window
instead of recomputing from ratio alone.

Behavior:
- left pane = Dashboard Home
- right pane = live Maps dashboard scene
- divider position is the single source of truth
- Maps host container follows its presentation bounds
- no context cloning

Critical markers:
- `V5.3 MAPS HOST FOUND`
- `V5.4 original`
- `V5.4 GEOMETRY`
- `V5.4 dashNow=... mapsNow=...`
