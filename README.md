# DuoPhone V3.9.11 — Car Display Source Graph

V3.9.10 reached SpringBoard's live display-monitor path and proved Car[2-3]
is connected, but it did not directly locate the external display scene manager.

V3.9.11 pivots to the live display source map:
- find FBSDisplayMonitor
- inspect `_lock_sourcesByDisplay`
- identify the CarPlay entry
- dump the mapped source object
- inspect display/scene/manager/provider/owner relationships

This build is read-only.

Critical markers:
- V3.9.11 CAR DISPLAY SOURCE GRAPH
- V3.9.11 displayMonitor FOUND
- V3.9.11 DISPLAY MAP
- V3.9.11 CAR DISPLAY SOURCE FOUND
- V3.9.11 carSource=
- V3.9.11 capturedCarDisplaySource=

Build/install/respring, connect CarPlay, open Maps once, then send the full trace.
