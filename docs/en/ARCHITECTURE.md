# Dev Switcher — Architecture

Updated: 2026-11-12. [日本語](../ARCHITECTURE.md) · [Product behavior](SPEC.md) · [Schema](SCHEMA.md)

Swift 6, SwiftUI, Foundation, and limited AppKit implement the macOS application. Swift Package Manager is the build definition. No external packages are required. The Japanese architecture document retains the detailed migration history and type sketches; this edition describes the resulting responsibilities.

## Targets and ownership

| Target | Responsibility |
| --- | --- |
| `DevSwitcherCore` | Definitions and validation, process/stack runtime, switching transactions, persistence, structured message templates |
| `DevSwitcherApp` | Main-actor `AppState`, exclusive activity tokens, views, logs, language selection and translation resources |
| `DevSwitcherMain` | Executable entry point |

`ProjectDefinition` contains working directories, ordinary `ServiceDefinition` processes, and `ManagedStackDefinition` stacks. `LaunchUnit` gives the switch transaction a common ordered view. Startup is stacks then processes; shutdown is processes then stacks. Display tags do not select runtime behavior.

## Managed stacks

`ManagedStackType` defines built-in type policy: per-environment limits, conflict scope, and adoption support. `ManagedStackIdentity` combines type and validated identity. Configuration resolves file-backed identity and a value-based fingerprint before commands are created. Identity resolution is read-only and does not execute CLI commands.

Supabase owns its config parser, project ID, supported CLI invocation forms, labels, inventory classification, and prohibited options. Compose owns file selection, limited top-level name parsing, project-name normalization, argument allowlists, `ps` parsing, and lifecycle command construction. These details do not belong in the switch transaction.

`ManagedStackDriver` observes, starts, and stops one supported stack type. `ManagedStackSupervisor` retains a resolved stack, its management relationship, latest observation, and events. Running and occupying resources are distinct: degraded/unknown managed resources retain a stop path. `RuntimeRegistry` owns supervisors and injected drivers and observes only relevant types.

Snapshots distinguish a failed type-wide observation from an empty inventory. Unknown is never inferred as stopped. The confirmation plan combines target actions, conflicting-stop actions, observations, and configuration fingerprints. Approval is revalidated before the first change. Management and state remain separate; adoption is not creation and is excluded from rollback.

## Ordinary processes and shutdown

Supervisors distinguish launched child processes, adopted processes, and residual groups without a live leader. PID alone is insufficient identity. Process anchors combine PID with boot-relative start time, and group evidence includes the boot session. Observation and signals repeatedly validate identity; unobservable ownership does not authorize a signal.

`ProcessStopMethod` selects signal shutdown or a structured stop command. Custom stop commands run in independently managed process groups and use the original unit’s log destination. Timeout sends SIGTERM, never automatic SIGKILL. A surviving stop-command group remains tracked separately, blocks unsafe restart, and is included in shutdown/recovery for its parent.

The registry’s port snapshots distinguish observed empty ports from unavailable observation. Only observed ordinary-process ports enter the release gate. Stack shutdown uses driver observations instead of proxy-port ownership.

## Switching and concurrency

`SwitchCoordinator` resolves all registered stack identities, refreshes observations, performs preflight validation, constructs and revalidates confirmation plans, stops the source, passes the port gate, and then starts the target. Only units launched in the current transaction are rollback targets. Stopped external stacks are never automatically restarted.

`AppState` serializes mutating lifecycle operations, settings changes, adoption decisions, and revalidation using an exclusive activity token. Rejection occurs at the state API boundary, before side effects. Process management and switching use actors. Main-actor state drives the UI. Read-only progress synchronization must continue during operations. Cancellation ends before the target startup phase.

`ServicePhase` and `ProjectPhase` are typed lifecycle states. The historical `.healthy` process phase means that initial process-liveness observation passed, not HTTP readiness. Failure facts explicitly describe both source and target. Logs do not determine lifecycle state.

## Validation, discovery, and persistence

Validation separates structural checks, filesystem checks, and stack identity resolution. All registered stack identities must resolve before uniqueness is claimed. Warnings are distinct from errors and do not block saving.

`DefinitionDiscovery` performs read-only discovery of direct-directory package scripts and Compose candidates. It retains source evidence for comparison immediately before form insertion. The form validates directory identity, selection, source changes, and name conflicts before applying the entire addition. Saving uses the existing build/validate/store path.

`ProjectsDocument` writes schema v4 atomically. Dedicated old-schema types read prior versions; unknown keys are rejected. Loading does not rewrite settings. Migration preserves IDs, process-relative order, and selection, and reports overall order changes until saved.

Runtime hints are separate from settings and are evidence for revalidation, never trusted running state. The v7 stack hints contain type, identity, fingerprint, and relationship; historical formats remain readable. Missing required current-version fields fail decoding. Stop-command hints include both `stopCommandFor` and `stopCommand`, or neither, and reject self-references or partial data. Relaunch compares them with current stop-command configuration.

## Japanese and English presentation

`LocalizedMessage` retains a template key and separate interpolation arguments. `L10n.text` renders that value through the application’s renderer. Core’s typed errors and state enums retain their identity and control-flow meaning; translated text is not used as a lifecycle decision input. When used without the app renderer, Core exposes the Japanese source wording for standalone diagnostics and existing tests.

`AppLocalization` chooses Japanese or English from the Mac/app preferences at startup, loads the exact language resource, and installs the renderer before creating `AppState`. No runtime language picker or mid-operation language switch is provided. Already formatted reasons and stored user names do not get reinterpreted. `L10n.override` is task-local for isolated tests; production configuration is installed once.

The canonical translation catalog is `Localization/Localizable.xcstrings`. `python3 scripts/localization.py` generates committed `ja.lproj/Localizable.strings` and `en.lproj/Localizable.strings` inside the app’s existing resource bundle. This supports the command-line SwiftPM build as well as catalog editing in Xcode. CI runs `--check` to reject missing translations, mismatched placeholders, and stale generated files. Application loading rejects missing language resources; rendering rejects missing keys or arguments.

Templates use numbered placeholders so English can reorder arguments. Substitution is a single pass: user values containing placeholders, percent signs, Japanese text, or commands remain literal. External CLI output and logs are never translated. The JSON schema is independent of language. `ProjectImportModel` chooses the corresponding bundled guide; its sample JSON retains identical keys and values.

Translate complete sentences rather than concatenated fragments, allowing language-specific word order and spacing. UI messages and the copied guide share the language selected at startup. Resource generation validates all translation and guide inputs before writing any output, so invalid inputs cannot leave one language updated and the other unchanged.

The distributed app declares both languages in `Info.plist` and includes the existing resource bundle. A relocated `.app` must load only its own resources, never a development-machine build directory.

## Verification and known limitation

Run catalog validation, `swift build`, and `swift test`. Swift Testing covers parsing, validation, migrations, state classification, prohibited commands, switching, process identity, port gates, custom shutdown, and recovery. Drivers and command runners are injectable so stack tests do not mutate real Docker resources. Do not weaken or skip tests when a runner forbids listening or observing real processes.

Localization tests cover preference ordering, region variants and unsupported languages, both catalog resources, placeholder reordering and literal user data, nested errors, state labels, confirmation content, both import guides, unchanged serialized settings, relocated bundles, and failure on missing resources. Render long English text at the minimum window size and inspect it.

Known lifecycle limitation: bulk operations save hints around the transaction, leaving a possible gap if the app is forcibly terminated after an early process starts but before the next save. Whether this loses process tracking requires dedicated verification and a separate priority decision; localization does not change that behavior.
