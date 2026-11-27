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

## Plugin runtime: global pinning differs by engine

Not a bundled plugin's logic, but it decides what every bundled plugin can trust. `flutter_js`
runs QuickJS (vendored `2026-06-04`, the same source on Android, Linux and Windows; Linux CI
loads the prebuilt `linux/shared/libquickjs_c_bridge_plugin.so` built from it) and
JavaScriptCore on macOS and iOS. A local `flutter test` on a Mac therefore never exercises the
engine Android ships.

- **Pin globals as getters, never as read-only data.** QuickJS stores global-object properties
  as variable references, and `JS_DefineProperty` updates the reference without the
  non-writable check, so `Object.defineProperty(globalThis, name, { value })` replaces a
  `writable: false, configurable: false` global (unfixed on bellard/quickjs master as of
  2026-11-23; quickjs-ng is not affected). A non-configurable accessor refuses every data or
  accessor redefinition on both engines. `__pinGlobal` in `plugin_manager.dart` creates host
  globals that way, and `__lockPluginHostBridge` converts the configurable built-ins, host
  globals and `globalThis` before the first plugin body runs.
- **Leave non-configurable data globals alone.** They cannot become accessors, and on QuickJS
  `writable: false` would not protect them anyway. Making one non-writable only breaks its
  owner: `flutter_js` declares `var __NATIVE_FLUTTER_JS__timerCount`, and pinning it froze every
  engine-level `setTimeout`/`setInterval` id. `console` (#34) is in this class and stays open.
- **Pin `globalThis` itself.** The plugin wrapper reads `globalThis.__reaprimePluginHostBridge`
  and `globalThis.__registerPlugin`; a rebound `globalThis` hands a later plugin's bridge token
  to whoever rebound it, on both engines.
