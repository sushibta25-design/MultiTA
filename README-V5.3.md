# DuoPhone V5.3 — Experimental Live Maps Host Split

V5.2 proved the real CarPlay scene-host chain is present:
`_UIScenePresentationView -> _UISceneLayerHostContainerView -> _UIContextLayerHostView -> CALayerHost`.

This build stops being probe-only.

It searches the live `DBDashboard-Car[...]` window tree for an
`_UIScenePresentationView` whose scene is `com.apple.Maps`.

When found it directly constrains:
- `DBDashboardHomeViewController.view` to the left pane
- the live Maps `_UIScenePresentationView` to the right pane
- the existing host container to that presentation's bounds

No CALayerHost clone, no copied context ID, no extra full-screen DuoPhone window.

This is intentionally experimental. A visual glitch or restart is possible.

Critical markers:
- V5.3 MAPS HOST FOUND
- V5.3 LIVE SPLIT APPLIED
- V5.3 waiting maps=...
