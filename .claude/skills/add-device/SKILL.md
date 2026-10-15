---
name: add-device
description: Add support for a new LED controller or strip layout (DevicePreset). Use when a user reports an unsupported controller or wiring.
---
# Add a device

1. Read `docs/PROTOCOL.md` and `Sources/BezelightCore/DeviceCatalog.swift`.
2. Add a `DevicePreset` to `DeviceCatalog.presets` with the LED count of each side in wiring order.
3. If the controller identifies itself, add its identity to `DeviceIdentity.swift` and a test with the recorded reply.
4. Verify on hardware with `swift run bezelight-probe <port>` and the app's "Test layout"; never claim support without a hardware check.
5. Mention the product and the verification in the PR; add a `CHANGELOG.md` line.
