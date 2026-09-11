# DuoPhone V5.1 — Dashboard Host Probe

Built directly from the uploaded DuoPhone V5 baseline.

V5.0 proved the live CarPlay dashboard hierarchy:
- DBDashboardRootViewController
- DBDashboardHomeViewController / DBAnimationView
- CPUIPassthroughView
- DBDashboard-Car[2-3] scene
- DuoPhone divider overlay

V5.1 now probes the dashboard root/child controller runtime and recursively
inspects view classes whose names suggest Scene/Host/Presentation/Context.

Goal: identify the exact CarPlay-owned application-scene host/container before
attempting split layout. This avoids reusing or cloning a context blindly.

Critical log markers:
V5.1 DASHBOARD HOST PROBE
V5.1 DASH ROOT
V5.1 DASH CHILD
V5.1 HOSTVIEW
V5.1 RUNTIME DASH_ROOT
METHOD / IVAR lines containing scene, host, presentation, context, application
