# DuoPhone V5.5 — Maps Platter Detach Split (Experimental)

The V5.4.1 log proves the geometry code itself is working:

- Maps scene found: `Car[2-3]:com.apple.Maps:dashboard`
- Dashboard frame changes with the divider
- Maps `_UIScenePresentationView` frame changes with the divider
- Maps host container follows the new frame

But the photo still shows App Grid over the whole Main area.

Reason:
The Maps presentation is still inside its original `DBDashboardPlatterView`
container. Resizing the inner `_UIScenePresentationView` only moves/resizes it
inside that platter; it does not promote the Maps surface to an independent
visible pane.

V5.5 changes that architecture.

It finds the nearest `DBDashboardPlatterView` ancestor of the live Maps scene,
removes that platter from its old dashboard hierarchy, and mounts the entire
live platter directly under `DBDashboardRootViewController.view`.

Then:
- Dashboard Home is the left pane.
- The real live Maps platter is the right pane.
- Divider position drives both pane frames.
- `_UIScenePresentationView` fills the detached Maps platter.
- The existing live scene host/context remains intact.

This is intentionally experimental because the whole Maps platter is moved,
not cloned.

Critical markers:
- `V5.5 DETACH MAPS PLATTER`
- `V5.5 newSuper=UIView`
- `V5.5 SPLIT`
- `V5.5 platterNow=... presentationNow=...`
