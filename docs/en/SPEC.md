# Dev Switcher — Product specification

Updated: 2026-11-12. [日本語](../SPEC.md) · [Architecture](ARCHITECTURE.md) · [Settings schema](SCHEMA.md) · [Roadmap](ROADMAP.md)

The Japanese specification is the canonical product specification. This English edition describes the same supported behavior. Report discrepancies rather than inferring different behavior.

## Purpose and platform

Dev Switcher starts, stops, and switches local development environments on macOS 15 or later. Before starting another environment, it verifies that the previous environment has stopped and that its observed process ports have been released. This prevents accidental connections to another environment’s processes or database.

The app uses Swift 6, SwiftUI, and AppKit where needed, with Swift Package Manager as the build definition and no external packages. App Sandbox is disabled because the app must run development commands in user-selected directories and inspect processes and ports. Directories need not be Git repositories.

## Environments, processes, and stacks

An **environment** is the unit started and stopped together. It contains named working directories, ordinary processes, managed stacks, startup selection, and ordering. The persisted type remains `ProjectDefinition`; the JSON array is `projects`.

A **working directory** has a name and an absolute path. Every process and stack belongs to exactly one directory. Duplicate paths within an environment are invalid.

A **process** is a foreground command such as `pnpm dev`, a worker, or a watcher. It has a name, an optional display-only tag, a start command, an optional stop command, optional ports, a default startup selection, and a failure policy. Tags never change runtime behavior or supply defaults. Processes are launched into their own process groups so children and grandchildren can be managed together.

A **managed stack** is a group of resources that outlives its startup command. Only the built-in Supabase and Docker Compose drivers are supported. User-defined observation or stack-stop commands are not supported. A stack has a name, type-specific configuration, optional ports, startup selection, and failure policy.

Registering `docker` or `docker-compose` as an ordinary process produces a warning without blocking registration: stopping the command’s process group may leave containers running. Use a managed Docker Compose stack to manage containers. Recognizable Supabase startup commands must be registered as managed stacks; see the schema for exact detection and warning rules.

`enabledByDefault` and `enabledNow` select what a bulk start launches. An excluded unit is not a failure. A separately started process is included in subsequent stop and switch operations, but its saved bulk-start selection is unchanged.

`failurePolicy: block` aborts startup and rolls back units started by this operation. `continue` allows subsequent units to start and displays the environment as partially stopped. Adoption, pre-start confirmation, stop failures, and the port-release gate do not use this policy.

Stacks start in registration order, then processes start in their configured order. Processes stop in explicit stop order, or reverse startup order by default; stacks then stop in reverse registration order.

## Exclusive switching

At most one development environment may run. Switching from A to B proceeds as follows:

1. Before changes, observe B’s target stacks and obtain any required approval for adoption, recovery, or stopping conflicting stacks.
2. Stop all processes actually launched or adopted in A.
3. Stop A’s managed stacks and observe `notRunning` for each.
4. Verify release of every port actually observed on A’s ordinary processes.
5. Revalidate approvals and current observations, then handle and start B’s stacks.
6. Start B’s processes in order.

If steps 2–4 fail, nothing in B starts. The gate uses observed ports, including ports held by processes with `continue` policy. It does not use configured ports. Stack shutdown is confirmed by the driver’s `notRunning` observation, not by Docker proxy port ownership.

B’s configured ports are not checked in advance. The OS decides which process binds a port. A process that exits because it cannot bind fails under its ordinary failure policy; one that chooses another port and stays alive may succeed. Configured ports are only display and Open URL metadata.

Switch cancellation is accepted only before the target startup phase begins. It finishes stopping A and does not start B. Already-issued stop operations are never undone.

## Everyday operations

Bulk start applies the stack confirmation flow before changing either environment. An ordinary process passes its startup check if it stays alive during the default three-second observation window and remains managed at its end. **Started** does not promise an HTTP response. No HTTP readiness checks are performed.

On blocking startup failure, only units started by the current operation are stopped in reverse order. Adopted stacks are not rolled back. Previously stopped environments or conflicting stacks are never automatically restarted.

Stop targets observed managed resources, including processes without ports, rather than merely the configured list. A managed stack may be stopped while its observation is `unknown`; failure to confirm `notRunning` leaves it shown as remaining. This differs from startup/adoption, where `unknown` blocks changes.

A running environment can start one excluded or stopped ordinary process for the current session. It can also restart one running ordinary process. Restart stops only that process, verifies release of its observed ports, then starts it. Failures do not stop other processes or stacks. Runtime hints must be saved before these operations; post-start save failure stops only the newly started process. Any remaining resources retain a recovery path.

Individual process stop, directory-level operations, and individual stack start/restart/stop are not offered. Stack startup is part of bulk startup. An Open URL may be opened in the browser for a running environment; working directories can be revealed in Finder.

## Managed stack contract

Identity, observed state, and authority to stop are separate concepts. IDs are unique across all registered environments **within the same stack type**. Supabase allows at most one stack per environment, including excluded stacks. Compose has no such limit.

| Observed state | Meaning |
| --- | --- |
| `notRunning` | Resources for the target identity are confirmed not running |
| `running` | The driver’s normal-running criteria are confirmed |
| `degraded` | Some resources are running, missing, stopped, or unhealthy |
| `unknown` | Observation failed or its output cannot be interpreted |

`unknown` is never converted to stopped or free. Authority to stop is established separately by `launched`, `adopted`, or `restored`. An observed running stack alone grants no authority. Observing `notRunning` revokes authority and removes its hint, preventing a later externally started stack with the same ID from inheriting stale authority.

At startup, a stopped target starts normally; a running target requires adoption approval and is not started again; a degraded target requires approval to stop, confirm shutdown, and restart. Supabase additionally requires approval to stop other local Supabase identities in its machine-wide conflict scope. Compose has no conflict scope beyond its own identity.

All required actions are combined in one confirmation sheet. Every row shows type and identity, registration details when known, or Unregistered otherwise. Cancellation is the default and changes nothing. Approval is checked again against observed identities, states, and configuration fingerprints immediately before changes. Any difference produces a new confirmation instead of acting on stale approval.

Stops are identity-limited and sequential. Failure stops the operation and records stopped, failed, and unprocessed identities. The scope is observed again before startup or adoption. A target must be observed as stopped immediately before its start command. It becomes `launched` only after both command success and observed `running`.

If startup fails and subsequent observation is `notRunning`, apply the target’s failure policy. If it is `running`, `degraded`, or `unknown`, stop the operation without claiming ownership or automatically stopping the resources: they may have been started externally.

Adopted stacks are excluded from rollback. If a later blocking failure leaves an adopted stack running, the environment shows remaining resources and retains an explicit stop action.

Stacks are observed at app startup, foreground activation, and before lifecycle operations, without periodic stack polling. Startup and activation only restore previously justified management and update display. They do not prompt, adopt, or stop external stacks. External-stack confirmation occurs only when the user starts or switches an environment.

### Supabase

Identity is the top-level `project_id` from `supabase/config.toml`, resolved relative to `--workdir` when specified, otherwise the configured working directory. Missing, unreadable, empty, duplicated, invalid, or unsupported values fail validation; no directory-name or port fallback is used. The CLI environment removes `SUPABASE_WORKDIR`.

Supported start forms are `supabase start`, `pnpm exec supabase start`, `npx supabase start`, and `pnpx supabase start`, including supported version suffixes and CLI global options. Status and identity-limited stop commands are derived from the same invocation and configuration directory. `--all` and `--no-backup` are prohibited both when constructing and executing commands.

Read-only Docker inventory uses the `com.supabase.cli.project` label. No containers means `notRunning`; a running, healthy database container means `running`, additionally requiring successful `supabase status` for a known configuration directory. Missing, stopped, or unhealthy database containers with remaining containers mean `degraded`. Docker errors, ambiguous/missing labels, duplicate database candidates, health `starting`, unsupported states, or failed status despite a healthy database mean `unknown`.

This does not guarantee all HTTP endpoints or that current startup exclusions match the existing stack. Commands have a 300-second limit; successful start/stop commands are followed by at most 60 seconds of observation for `running`/`notRunning`. The conflict scope includes all local Supabase stacks. Backup volumes left by stop do not count as running resources.

### Docker Compose

Only the `docker compose` subcommand is supported as a managed stack. All lifecycle commands explicitly use the same project name (`-p`) and resolved files (`-f`, in order).

Explicit files are nonempty relative paths. Otherwise, search directly in the working directory in this order: `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`. Select the first basic file and the first matching-family override, preferring `.yaml` to `.yml`. Never search parent directories. Missing files are validation errors.

The project name comes from explicit `projectName`, then supported top-level `name:` values in the selected files, then the directory containing the first Compose file. Only the directory-derived name is lowercased and stripped of invalid characters. Conflicting, interpolated, escaped, or unparseable `name:` values require explicit `projectName`. Names must start with a lowercase letter or digit and contain only lowercase letters, digits, hyphens, and underscores.

Dev Switcher does not read `.env` or use `COMPOSE_PROJECT_NAME` to select its target. Explicitly set the name used by terminal Compose commands when adopting an existing stack. The execution environment removes `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, and `COMPOSE_PROFILES`. Compose itself may read `.env`; its variable interpolation and image pulls/builds remain Compose behavior. Explicit `-p`/`-f` fix the target. If profiles are omitted for startup/observation, Compose’s handling of `.env` profiles is left to Compose.

Start uses configured profiles and `up -d` plus allowlisted arguments. Stop **always uses `--profile '*' stop`**, including externally started profiles with the same project name. Editing, detail, and confirmation views explain this scope. `down`, `rm`, `kill`, volume/image/orphan deletion, and anonymous-volume renewal are never executed. Stopped containers and volumes are preserved.

Observation uses `ps --all --format json`, accepting JSON Lines or an array. Container classification is:

| Classification | State |
| --- | --- |
| Normal | `running` without healthcheck, or with `healthy` |
| Abnormal | `running` with `unhealthy`, `restarting`, or `paused` |
| Stopped | `exited`, `created`, or `dead` |
| Indeterminate | Health `starting`, `removing`, or any unsupported value |

Failed observation or any indeterminate container makes the stack `unknown`. No normal or abnormal containers makes it `notRunning`. Otherwise any abnormal or stopped container makes it `degraded`; all normal makes it `running`. The inventory is not compared with every service declaration. Consequently, completed one-shot services currently cause `degraded`.

Start/stop commands have a 300-second limit, followed by at most 60 seconds of state confirmation. Observation commands have a 60-second limit. Other Compose project names are neither observed nor stopped. Different profiles’ visibility in `ps` and all-profile stop behavior must be verified on real Docker; this was confirmed with Compose v5.5.0 on 2026-11-12.

## Ordinary process shutdown

Without a stop command, send SIGTERM to the owned process group and allow 10 seconds for exit. Remaining processes are reported; SIGKILL is never automatic.

With a stop command, observe the group first and skip the command if it is already gone. Run the command in its own process group, with the login-shell environment and structured executable/arguments. Wait up to 30 seconds for the command, then up to 10 seconds for the target group. Command failure or timeout is included in logs and results, but actual group observation determines shutdown success.

A timed-out stop command receives SIGTERM and a 10-second grace period. If it remains, retain its own identity, ports, hints, and stop path, even if the original process has exited. It cannot be adopted as a normal running service after relaunch.

Force Stop requires an explicit user action and confirmation. Revalidate identity immediately before SIGKILL, including recorded process anchors and group membership. Do not signal a mismatching or unobservable group. Only launched or safely adopted ordinary process groups can be force-stopped; stacks cannot.

## Display, ports, and logs

Distinguish Excluded, Stopped, Starting, Started, Partially stopped, Stopping, Switching, Failed, and Resources remain. Use text as well as color. Stack views additionally show observed state and management relationship. Logs never determine process state. Notifications are limited to operation failures and unexpected ordinary-process exits after successful startup.

Ports are optional, never inferred from tags or stack types. A nonempty port list requires exactly one primary port, with no duplicates within the unit. Different units may configure the same number. The sidebar shows the primary port and additional count; detail shows all ports. A blocked release gate identifies the port, PID, command, and ownership category. External, system, and other-user processes are never signalled by Dev Switcher.

Each unit has its own chronological stdout/stderr log. Both streams use normal text color; stderr counts are supplementary, not error badges. Follow the latest output by default, pausing while reading history. Preserve logs after stop; reset them at the next start attempt. Stack logs contain commands run by Dev Switcher. Combined logs are not supported.

## Quit, relaunch, and persistence

Quitting the app leaves processes and stacks running. Save definitions and revalidation hints, never a trusted running state. Use atomic writes in Application Support. Unreadable settings block new starts and modifications but retain recovery stop actions.

Process hints include PID, process group, identity anchors, executable, working directory, and observed ports. Relaunch revalidates identity and offers adoption or stopping; unsafe residual candidates offer Leave Running instead of adoption. Definitely stale hints can be removed automatically; indeterminate hints remain with an explanation. PID reuse must not lead to adoption or signals.

Stack hints include type, identity, configuration fingerprint, and management relationship. Restore only when all match current settings. Observe matching stacks: `running` restores running management; `degraded` restores management with remaining-resource status; `notRunning` discards the hint; `unknown` retains it without changing resources. Missing or mismatching settings do not trigger observation or stop commands. Users may explicitly discard hints known not to match current configuration.

Settings use schema version 4. Older versions migrate through v1 → v2 → v3 → v4 while preserving IDs, process-relative order, and startup selection. Supabase becomes a separate stack. If stacks-first startup or stacks-last shutdown changes the overall order, notify the user until the converted settings are saved. Loading alone does not rewrite files.

## Registration and import

One form handles creation and editing. It supports named directories, process ordering, commands, tags, ports, selection, failure policy, stacks, and type-specific settings. Preserve fields the form does not edit, including explicit stop order. Running environments cannot be edited at either the UI or state API boundary. Unregistering requires confirmation and never removes repository files.

Validation checks required values, unknown keys, IDs, names, paths, membership, commands, port ranges, primary-port rules, stack configuration, identities, and limits. File-system validation reads configuration files only; it never executes Docker or another CLI. Resolve all registered stack identities again before a new start or switch. Resolution failures and duplicates block startup while retaining stop recovery.

JSON import adds new environments only. Show directories, order, commands, stacks, selection, warnings, and full settings for review. Revalidate immediately before saving. Invalid input, duplicates, or save failure add nothing. Import does not start processes or overwrite existing environments. Export, cloud sync, CSV, and bulk updates are not supported.

The form can discover candidates from `package.json` scripts and Compose files directly in a selected directory. It does not search parents, children, workspaces, or Procfiles. Scripts are displayed in name order, initially unselected; the registered command is the chosen manager’s `run <script>`, without reparsing shell syntax. Associated pre/post scripts may run when the user later starts the command.

Detect managers from lockfile names only: pnpm, npm, yarn, or bun. A single manager is suggested with evidence; missing, conflicting, or unreadable evidence requires selection. `packageManager` is informative only. No installation or version switching occurs. Compose produces one candidate with explicit resolved files and project name; services, profiles, and ports are not inferred.

Discovery reads only readable regular files, each at most 1 MiB. It refuses `.env`, `.env.*`, `.envrc`, and symlinks to them. Source errors remain distinct from no candidates. Re-read sources before applying selections; changes or duplicate names abort the whole addition. Preserve existing inputs and order, removing only an untouched placeholder row. Saving remains a separate validated action.

## Interface and language

The main window defaults to 880 × 544 pt and has a 720 × 460 pt minimum. The sidebar groups the active environment separately from registered environments. Row clicks select; explicit buttons execute. Logs and metadata appear in the detail pane. Single-environment start/stop uses inline progress; switching, failures, adoption, and configuration use sheets when a decision is needed.

Japanese and English are supported. At launch, choose the first supported language in the Mac/app language preferences; use English if none matches. Changing language requires relaunch. Buttons, state labels, confirmations, errors, accessibility/help text, and the copied import guide use the chosen language. User names, paths, commands, external logs, and raw tool output are preserved. Missing translation resources or keys are errors rather than silent language fallback.

Use the system accent and semantic green/orange/red/gray colors, system label hierarchy, monospaced ports/PIDs/logs, and the existing design tokens. English text must remain readable at minimum window size; wrap or scroll detailed explanations. No menu-bar UI or global hotkey is currently provided.

## Safety and acceptance

All mutating lifecycle operations, configuration changes, adoption decisions, and revalidation use an exclusive activity token at the state API boundary. UI disabling alone is insufficient. Failure sheets state the actual current state of both source and target. Destructive choices are never defaults. Never guess missing mandatory values, trust saved runtime state, signal external processes, read project environment files, run database migration/reset/seed, or automatically install/update dependencies.

Acceptance includes settings round-trips and migrations, unknown-key rejection, startup/stop ordering, exclusive gates, failure policies, per-process restart isolation, hints and PID reuse, custom stop-command failures, stack classifications, revalidation of approval, prohibited-command rejection, and preservation of stop paths after observation failure. Discovery must not execute commands or partially apply invalid candidates.

Language acceptance requires complete Japanese/English catalogs, matching interpolation arguments, preservation of user data, localized nested errors and confirmations, correct OS language selection, both import guides producing valid v4 JSON, and resources working from a relocated app bundle. Lifecycle decisions and serialized configuration must be identical across languages.

Run `python3 scripts/localization.py --check`, `swift build`, and `swift test`. Do not weaken or skip real-process tests to accommodate a restricted runner. Report failures and unverified behavior. Real Docker/Supabase startup, adoption, and shutdown checks require explicit user approval.

HTTP readiness, concurrent environments, automatic port assignment, custom stack drivers, additional stack types, individual stack operations, shared Supabase stacks, combined logs, app auto-update, and Windows/Linux support remain out of scope.
