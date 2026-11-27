# AI Plugins Notes

Read this for behavior specific to a bundled plugin's own logic (not the plugin host
API/permissions — that's `doc/Plugins.md`).

## Visualizer: grinder burrs folded into `grinder_model`

`assets/plugins/visualizer.reaplugin/plugin.js`. Visualizer's Decent JSON parser reads only
`grinder_model` / `grinder_setting` from `app.data.settings` and has no field for a grinder's
burrs (decentespresso/dye2#9), so `uploadGrinderModel` folds them in as `"<model> (<burrs>)"`
via `combineModelAndBurrs`. Invariants to preserve when changing this:

- **Upload from the shot, not from the grinder record.** Both halves come from
  `context.grinderModel` and `context.grinderBurrs`. An upload is often a replay of old
  history (a manual re-upload, a re-upload after fixing credentials) while the grinder record
  is live metadata, so a lookup would let a later rename or burr swap rewrite what earlier
  shots claim. A shot with no `grinderBurrs` uploads the plain model.
- **Resolve the snapshot on every store, not only when absent.**
  `PersistenceController.persistShot` reads the linked grinder whenever the context has a
  `grinderId`, because Repeat (`history_feature`) loads a recorded workflow back into the
  active one and a fill-in-if-absent would let a new shot inherit another shot's burrs. A
  missing grinder, empty burrs or a failed lookup clears the field instead of keeping an
  unverifiable claim; a context with no `grinderId` is left alone. `WorkflowContext.grinderBurrs`
  rides in `workflowJson`, so no schema change is involved.
- **Match burr tokens on word boundaries.** `combineModelAndBurrs` skips the fold only when
  every whitespace/punctuation-split token of `burrs` is already a token of the model text. A
  substring check reads "EK43" as already containing burr "4", or "Kinu M47" as containing
  "M", and drops the real burr.
- **Suppress only our own echo, by normalized equality.** Visualizer echoes the combined
  string back on every back-synced shot, so `shouldSkipBackSyncedGrinderModel` compares the
  remote value against the string this plugin uploaded, kept per Visualizer id in
  `state.uploadedGrinderModels`. `normalizeGrinderModelText` trims, lower-cases and collapses
  inner whitespace, so a round trip differing only in case or spacing still counts as ours;
  anything else is a real edit and has to apply. With no recorded upload string (an older
  install, or a mapping rediscovered by `refreshLocalShotMap`) the guard recomputes from the
  local shot's own context and compares the same way; with nothing to compare against, apply
  the remote value rather than dropping it on a guess.
- **A remote model edit takes ownership of the field.** When back-sync applies one it sends
  `grinderBurrs: null` with it and calls `forgetUploadedGrinderModel`: keeping the snapshot
  would re-append the burrs on the next upload, and keeping the upload string would make the
  guard suppress a later revert to that value. Only a remote value that names a model counts
  as an edit — an absent or empty `grinder_model` is the generic null-ing `mapRemoteToLocal`
  already does, and leaves both alone.
- **Only send the note when Visualizer actually sent one.** `mapRemoteToLocal` null-s every
  field it does not find, which is harmless for fields nothing falls back on. The note is
  different: the host now persists an explicit `espressoNotes: null` as `''`
  (`doc/AI_API_NOTES.md`), so a rating-only back-sync of a response without `espresso_notes`
  would clear a workflow-only note for every client that honours the empty string. The
  mapping therefore omits `espressoNotes` unless the remote response carries the key; a
  present `null` or `''` is a real remote clear and still maps to `null`.
- **Keep the `storageRead` layering.** The reply for `uploadedGrinderModels` layers under
  whatever the session has already recorded, because that read can land after an upload has
  remembered its string.

## Plugin runtime: one realm per plugin

Not a bundled plugin's logic, but it decides what every plugin can trust.
`PluginManager` creates one `JavascriptRuntime` per loaded plugin (`_PluginRealm`) and
disposes it when the plugin unloads, reloads or the manager is disposed. Invariants to
preserve when changing this:

- **Route by realm, never by a plugin-supplied id.** Each realm's `sendMessage` channels are
  registered with closures bound to that realm, and `_pluginIdForBridgeMessage` rejects a
  message unless the realm is still the plugin's current one, the bridge token is that
  realm's token, and any `pluginId`/`generation` field matches the realm. Every Dart-to-JS
  call (`__handleFetchResponse`, `__handleTransportReply`, `__handleDeviceReply`,
  `__fireTimer`, `__dispatchToPlugin`, ...) goes through `_realmOf(pluginId, generation)`.
  Do not add a manager-wide runtime or a global registry again: that is what let one plugin
  hook another plugin's built-ins and read its bridge token. Fork-only bridges follow the
  same rule: `host.discovery` rides the `host` channel and completes through the realm,
  the machine-control grant is looked up for the realm's plugin id (`_PendingOp.pluginId`),
  and storage, notifications and surface HTTP requests dispatch with `_realmOf`.
- **Console is per realm and attributed host-side (#34).** `flutter_js` gives every runtime
  its own `console` that posts to a `ConsoleLog` channel and `print`s it unattributed.
  `_bootstrapRealm` replaces that channel handler with one bound to the realm, so console
  lines are written through `_writePluginLog` (redaction, rate limit, `log` permission) as
  `[JS:<realm's plugin id>] console.<level>: ...` at FINE. Nothing in the line or the
  message can change the id. Host error reports must not use `console` (it is the
  plugin's own, log-gated output): `__dispatchToPlugin` and `__dispatchTransportEvent`
  return the caught exception text to Dart, which writes it via `_logPluginError` at
  WARNING whatever the plugin's permissions, with its own limiter. Tests that wrap a runtime (`_CountingRuntime`) keep the
  default `print` handler, because `channelFunctions` is the wrapper's own map.
- **Ids are per realm, so key host maps by generation and check identity.** Timer ids and
  fetch ids restart at 1 in every realm, and a retired generation's work can still finish
  after a reload (a fetch still in `openUrl` cannot be aborted). Host-side maps are keyed by
  plugin id and generation (`_timers` by `(pluginId, generation, id)`, `_PendingOp.keyFor`),
  and completion removes an entry only if it is still the same object (`_completeOp`,
  `_fireTimer`). Transport handles and device invocation ids are host-generated and unique.
- **Keep the realm until cleanup is done.** `_unloadPlugin` runs `onUnload`, rejects pending
  work and runs device disconnect cleanup inside the old realm, and only disposes it in its
  `finally`. A new generation's realm is created after the old one is disposed.
- **Engines differ, so test on both.** `flutter_js` runs QuickJS (vendored `2026-06-04` in
  dart_js, the same source on Android, Linux and Windows; Linux CI loads the prebuilt
  `linux/shared/libquickjs_c_bridge_plugin.so`) and JavaScriptCore on macOS and iOS, so a
  plain `flutter test` on a Mac never exercises the engine Android ships. Build the bridge
  from dart_js's `linux/shared/CMakeLists.txt` on macOS and run
  `LIBQUICKJSC_PATH=<path>/libquickjs_c_bridge_plugin.dylib flutter test
  test/plugins/plugin_realm_isolation_test.dart` to run the isolation suite on QuickJS too.
- **The in-realm lock is defence in depth, not the boundary.** QuickJS stores global-object
  properties as variable references and `JS_DefineProperty` updates them without the
  non-writable check, so `Object.defineProperty(globalThis, name, { value })` replaces a
  `writable: false, configurable: false` global (unfixed on bellard/quickjs master as of
  2026-11-23). `__pinGlobal` therefore pins the host's globals and `globalThis` as
  non-configurable getters, which both engines honour, and the host shims call built-ins
  captured at bootstrap. Built-ins and their prototypes are deliberately not frozen: inside a
  single-plugin realm that would only stop a plugin changing its own realm, and it breaks
  ordinary code through the override mistake (`o.toString = ...` or `arr.push = ...` ignored
  in sloppy code and throwing in strict code, subclasses of `Array`/`Map`/`Promise`).
  `__NATIVE_FLUTTER_JS__*` stays unpinned because `flutter_js` must keep it writable or every
  engine-level timer id repeats.
- **Realm creation can fail.** `_createRealm` turns a throwing `createJsRuntime` or a realm
  that cannot evaluate into a failed load of that plugin only. A `NULL` from QuickJS's
  `JS_NewRuntime`/`JS_NewContext` is not checked inside dart_js's native bridge
  (`jsNewRuntime`), so that case needs a dart_js fix. A per-realm `memoryLimit` (supported
  by `QuickJsRuntime2`) is now cheap to add and would bound each plugin separately.
- **Cost.** One engine instance per loaded plugin. Measured on macOS arm64 with 40 trivial
  plugins: QuickJS about 0.4 MiB RSS and 3 ms per load (the QuickJS heap of a bootstrapped,
  locked realm is about 0.33 MiB, `qjs -d`), JavaScriptCore about 2 MiB and 3.6 ms, against
  about 0.2 MiB and 0.7 ms per plugin in the former shared runtime. The cost scales with the
  number of loaded plugins, not with reloads, because a reload disposes the old realm first.
- **Test seam.** `debugPrepareRealm` runs in a new realm after the host bootstrap and before
  the lock, where tests stub `__timerSet`, `__fetchFor` or `fetch`; `jsRealmOf(pluginId)`
  returns a plugin's runtime for assertions.

