# DuoPhone V5.2 — Scene Presentation Host Probe

Built directly from V5.1.

V5.1 mapped the real DBDashboard root/children.
V5.2 searches every window in the live DBDashboard-Car scene for:

- _UIScenePresentationView
- _UISceneLayerHostContainerView
- _UIContextLayerHostView
- _UISceneLayerHostView
- CPUIPassthroughView
- CALayerHost

For each hit it logs:
- frame / superview chain
- responder chain
- layer class
- scene / sceneLayer / presentation context
- context / contextId where available
- CALayerHost subtree

Critical markers:
- V5.2 SCENE PRESENTATION HOST PROBE
- V5.2 TARGET
- _UIScenePresentationView
- _UIContextLayerHostView
- CALayerHost
- V5.2 TARGET KVC
- V5.2 LAYER KVC

Goal:
Identify the exact live CarPlay application-scene host so the next build can
attempt a real split layout rather than another blind clone/probe.
