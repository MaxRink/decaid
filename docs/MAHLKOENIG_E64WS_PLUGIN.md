# Mahlkönig E64 WS local plugin

This branch contains the first native Decaid implementation for a local
Mahlkönig E64 WS integration. It uses the grinder's local TLS WebSocket
interface only; it has no Mahlkönig cloud client and no cloud credentials.

## Files

- `lib/src/plugins/plugin_grinder_bridge.dart` defines the host-owned typed
  capability boundary.
- `lib/src/plugins/e64ws_plugin_bridge.dart` implements one-shot WSS requests
  with response correlation, certificate policy, action allowlisting, and
  timeouts.
- `lib/src/plugins/plugin_manager.dart` exposes the bridge to JavaScript only
  through the manifest permissions `device.grinder.read` and
  `device.grinder.actuate`.
- `assets/plugins/mahlkoenig-e64ws.reaplugin/` is the installable plugin.

The bundled JavaScript also contains a revisioned, pure normal-input GBS model
for `GbS1` through `GbS4`, the `DdEff` measurement sequence, and the decoded
E64/E65/E80 dial-in rows. It is used for local recommendations and persisted
in-memory state; it is not allowed to move the grinder automatically.

The bridge opens one WSS connection per operation. This is deliberate for the
initial implementation: it avoids a long-lived credential-bearing session
inside the plugin runtime and makes unload/cancellation deterministic. A
future native device manager can replace it without changing the plugin
operation names.

This is a development reference, not the production credential owner. The
production loader deliberately leaves the raw E64 bridge unset. The Python
simulator can exercise REST/WSS/OpenScale fixtures; Decaid app tests must
explicitly inject a test bridge or use a future native adapter.

## Configuration

Configure the bundled plugin in Decaid's plugin settings:

- `Host`: the E64 hostname or LAN address;
- `Port`: normally `9997` for the recovered WSS endpoint;
- `Token`: the owner-provided local token, marked secure in the manifest;
- `AllowInsecureTls`: off by default; only enable it on an isolated LAN when
  the grinder's certificate is self-signed;
- `EnableActuation`: off by default;
- `TargetBrewTimeSeconds` and `Flavor`: inputs to the conservative,
  recommendation-only helper.

The token is passed to the host bridge only to establish the WSS connection.
It is not included in logs, error context, plugin events, or HTTP responses.
The current generic plugin settings UI still supplies the secure setting to
plugin JavaScript, so this is credential minimization rather than a complete
secret-isolation boundary. Moving the credential to Decaid's credential store
is a follow-up hardening task.

## Operations

The host accepts only these named operations:

| Operation | Wire request | Capability | Default |
| --- | --- | --- | --- |
| `driver_state` | `RequestDriverState` | `device.grinder.read` | enabled |
| `driver_config` | `RequestDriverConfig` | `device.grinder.read` | enabled |
| `gbs_report` | `GrinderAction` + `GbsCreateReport` | `device.grinder.read` | enabled |
| `action` | allowlisted `GrinderAction` suffix | `device.grinder.actuate` | disabled by setting |

The model endpoint is:

```text
POST /api/v1/plugins/mahlkoenig-e64ws.reaplugin/gbsAdjust
```

It accepts the recovered algorithm name and explicit finite inputs such as
`actualBrewTimeMs`, `targetBrewTimeMs`, `estimatedDdDum`, `setpointDdDum`, and
`toleranceMs`. Unknown algorithm names follow the firmware's V1 fallback. The
implementation preserves the known thresholds, history lengths, regression
orientation, blend weights, state gates, and DdEff six/six/six sequence for
the analyzed build. It deliberately does not claim that a numeric DD
increase means physically finer or coarser on every grinder.

Actions must be in the recovered suffix allowlist. Physical and maintenance
actions additionally require `confirmed: true`. This is a host-side check as
well as a plugin UI check. The plugin does not invent a physical dial range or
pretend that a DD sensor value is a universal dial position.

The HTTP endpoints are exposed through the normal plugin API:

```text
GET/POST /api/v1/plugins/mahlkoenig-e64ws.reaplugin/status
GET/POST /api/v1/plugins/mahlkoenig-e64ws.reaplugin/gbsReport
POST     /api/v1/plugins/mahlkoenig-e64ws.reaplugin/recommend
POST     /api/v1/plugins/mahlkoenig-e64ws.reaplugin/action
WS       /ws/v1/plugins/mahlkoenig-e64ws.reaplugin/state
```

`shotStored` events trigger a local Decaid shot lookup and a recommendation
when enough timestamp data is available. The recommendation is intentionally
not presented as recovered Mahlkönig GBS logic: it is a transparent,
conservative Decaid helper using brew duration and sensory words. No automatic
physical movement or `AddBrewEvent` injection is performed.

## Known limitations

The integration is usable as a local read/recommendation plugin, but it is not
yet a complete native Decaid grinder device. The firmware work still needs
owner-controlled runtime validation for response schemas, physical DD
direction/range, GBS event units, scale timing, and cross-version behavior.
The current plugin therefore does not claim automatic dial adjustment is safe.

Before enabling actuation on a real grinder, validate the exact firmware
revision, certificate behavior, DD bounds, action payload, and stop/recovery
behavior on an isolated setup. Keep a hardware stop path available.
