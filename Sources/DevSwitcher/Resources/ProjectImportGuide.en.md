# Create Dev Switcher import JSON

Create UTF-8 schemaVersion 4 JSON for the environments specified by the user. The user will review it before adding new environments; import does not start anything. Ask about unspecified commands, arguments, paths, and startup policies instead of guessing. Do not read .env, .env.*, or .envrc; do not start services, install dependencies, or run database migration, reset, or seed operations.

## General rules

Use UTF-8 JSON without comments or trailing commas. Unknown keys are errors. All fields are required unless marked optional. Required arrays must be present even when empty. Omit an optional field instead of writing `null`.

Nonempty strings must contain at least one non-whitespace character. UUIDs use the 36-character hyphenated representation. UUID comparison is case-insensitive; saved UUIDs use Foundation’s uppercase representation. Name uniqueness is case-insensitive.

Directory paths are absolute file URLs, such as `file:///Users/example/GitHub/shop-web/`. Percent-encode spaces. Do not use `~`, relative paths, or unmodified sample paths. Compose file paths are the explicit relative-path exception described below.

## Document and environment

```json
{ "schemaVersion": 4, "projects": [] }
```

`schemaVersion` is `4`. `projects` may be empty in a saved document, but an import must contain at least one environment.

| Environment field | Type and rule |
| --- | --- |
| `id` | UUID, unique across registered environments |
| `name` | Nonempty string, unique across registered environments |
| `color` | `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, or `teal` |
| `workingDirectories` | Nonempty array of named working directories |
| `services` | Array of ordinary processes, possibly empty; array order is process startup order |
| `managedStacks` | Array of stacks, possibly empty; array order is stack startup order |
| `stopOrder` | Optional UUID array specifying every process exactly once; no stack IDs |
| `enabledNow` | Optional object mapping process/stack UUID strings to booleans |

The total number of processes and stacks must be at least one. Stacks start before processes and stop after them. If omitted, `stopOrder` is reverse process startup order. `enabledNow` keys must identify units in this environment; absent keys use `enabledByDefault`.

## Working directories

| Field | Type and rule |
| --- | --- |
| `id` | UUID, unique within the environment |
| `name` | Nonempty string, unique within the environment |
| `directory` | Absolute file URL; unique path within the environment |
| `serviceIDs` | Array of process UUIDs assigned to this directory; may be empty |
| `stackIDs` | Array of stack UUIDs assigned to this directory; may be empty |

Each directory must contain at least one process or stack. Every process and stack belongs to exactly one directory, with no unknown references. Directories must exist during registration/import/start. Loading saved settings checks structure without requiring all directories to remain available, so a moved repository does not make the whole configuration unreadable.

## Ordinary processes (`services`)

| Field | Type and rule |
| --- | --- |
| `id` | UUID, unique across all registered processes and stacks |
| `name` | Nonempty string, unique among processes and stacks in this environment |
| `tag` | Optional nonempty display-only string, at most 32 grapheme clusters (`String.count`) |
| `start` | Start command; working directory must match the assigned directory |
| `stop` | Optional stop command; its working directory must exist, usually the start directory |
| `ports` | Port array, possibly empty |
| `enabledByDefault` | Boolean controlling bulk-start selection |
| `failurePolicy` | `block` or `continue` |

Tags never select commands, ports, startup behavior, or stop behavior. A stop command replaces SIGTERM for normal shutdown; actual process-group observation still determines whether the process stopped.

Supabase startup is rejected as an ordinary process when either the executable basename is `supabase` with a `start` subcommand (supported preceding global options included), or an argument is `supabase`/`supabase@<version>`, immediately followed by `start`, and the preceding argument is absent or does not begin with `-`. This includes common package-manager wrappers. Use a managed Supabase stack with one of its supported command forms.

If the argument preceding `supabase` begins with `-`, show a warning instead of rejecting: it may be an option value such as `--filter supabase`, selecting a workspace package rather than the CLI. A `docker`/`docker-compose` executable also produces a warning without blocking registration because containers may survive process-group shutdown.

## Commands (`start` and `stop`)

| Field | Type and rule |
| --- | --- |
| `executable` | Nonempty command name resolved through the login shell’s PATH, or an absolute executable path |
| `arguments` | Array of nonempty strings; `[]` means no arguments |
| `workingDirectory` | Absolute file URL |

Separate executable and arguments. For example, use `"executable": "pnpm"` with `"arguments": ["dev", "--port", "3000"]`; do not put `pnpm dev` in `executable` or concatenate values into a shell command. Executable availability is checked at startup, not guaranteed by import.

## Managed stacks (`managedStacks`)

| Field | Type and rule |
| --- | --- |
| `id` | UUID, unique across registered processes and stacks |
| `name` | Nonempty string, unique among processes and stacks in this environment |
| `type` | `supabase` or `dockerCompose` |
| `supabase` | Required only for type `supabase`; prohibited otherwise |
| `dockerCompose` | Required only for type `dockerCompose`; prohibited otherwise |
| `ports` | Port array, possibly empty; display/Open metadata only |
| `enabledByDefault` | Boolean |
| `failurePolicy` | `block` or `continue` |

The driver determines stop commands; custom stack stop commands are not accepted.

### Supabase configuration

`supabase` contains a required `start` command. Supported forms are `supabase start`, `pnpm exec supabase start`, `npx supabase start`, and `pnpx supabase start`. Package names may include `@<version>`. Unsupported wrappers such as `pnpm supabase start`, `yarn supabase start`, or `bunx supabase start` must be rewritten to one of the supported forms for a managed stack.

Before `start`, only supported CLI global options are accepted: `--workdir`, `--profile`, `--network-id`, `--dns-resolver`, `--output`/`-o`, `--debug`, `--experimental`, `--yes`, and `--create-ticket`. Options requiring a value must have one. `--all` and `--no-backup` are prohibited. The command working directory must equal its assigned directory.

Read the top-level `project_id` from `supabase/config.toml` under `--workdir` (relative to command working directory when needed), or otherwise under command working directory. It must start with an alphanumeric character, contain only alphanumeric characters, `_`, `.`, and `-`, and be at most 128 characters. Missing, empty, duplicate, unreadable, or unparseable values are errors. At most one Supabase stack may be registered per environment, including excluded stacks. Its `project_id` must be unique across all registered Supabase stacks.

### Docker Compose configuration

| Field | Type and rule |
| --- | --- |
| `projectName` | Optional explicit project name, equivalent to `-p` |
| `files` | Optional nonempty array of existing relative file paths, in CLI order |
| `profiles` | Optional nonempty array of nonempty strings for startup and observation |
| `upArguments` | Optional additional arguments after `up -d`; omission means `[]` |

`files` paths are relative to the assigned working directory; `../` is allowed, absolute paths and `~` are not. If omitted, find the first basic file directly in the working directory from `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`, then its matching-family override if present, preferring `.yaml` to `.yml`. Do not search parents. All commands receive the same resolved files explicitly through `-f`.

Startup and observation use configured profiles. Stop always uses `--profile '*'`, targeting every profile with the same project name, including externally started profiles not configured in Dev Switcher.

`upArguments` uses an exact allowlist:

- Service names beginning with an alphanumeric character and containing only alphanumeric characters, `_`, `.`, and `-`.
- No-value options: `--build`, `--no-build`, `--wait`, `--force-recreate`, `--no-recreate`, `--no-deps`, `--quiet-pull`.
- `--pull=always`, `--pull=missing`, `--pull=never`, or `--pull` followed by one of those values. The next argument is consumed as the option value.
- `--wait-timeout=<positive integer>`, or `--wait-timeout` followed by a positive integer.

All other forms are rejected, including combined short options. Examples of prohibited arguments are target selectors (`-p`, `--project-name`, `-f`, `--file`, `--project-directory`), duplicated detach options, foreground/attach/watch/abort modes, `--no-start`, `--remove-orphans`, and `-V`/`--renew-anon-volumes`.

The project name resolves in this order: `projectName`; supported top-level `name:` in selected files; the directory containing the first file. Explicit names are not normalized. Only a directory-derived name is lowercased and stripped of unsupported characters. The result must start with a lowercase letter or digit and contain only lowercase letters, digits, `-`, and `_`.

`name:` supports unquoted values or quoted values without escapes. Interpolation such as `${...}`, conflicting names across files, or unparseable names require explicit `projectName`. The resolved name must be unique across all registered Compose stacks. Multiple Compose stacks per environment are allowed.

This name resolution deliberately differs from terminal Compose: Dev Switcher does not read `.env` or its `COMPOSE_PROJECT_NAME`. To adopt a terminal-started stack, explicitly specify the project name shown by `docker compose ls`.

## Ports

| Field | Type and rule |
| --- | --- |
| `id` | UUID, unique within the process or stack |
| `port` | Integer from 1 through 65535, unique within that unit |
| `primary` | Boolean; exactly one true if the port array is nonempty |
| `label` | Optional nonempty display label |
| `openUrl` | Optional `http` or `https` URL used by the Open menu |

Different units may use the same configured number. No numbers are inferred from tags or types. These values do not determine startup success or the shutdown port-release gate. There is no readiness URL setting.

## IDs, import, and migration

Generate a separate UUID for every new environment, directory, process, stack, and port. Do not reuse sample UUIDs. References in `serviceIDs`, `stackIDs`, `stopOrder`, and `enabledNow` must identify the corresponding objects. Existing saved definitions may retain their IDs and order when transferred.

Import checks duplicates within the file and against registered settings. It adds new environments only, without updating an existing environment with the same ID or name.

Old settings are read through v1 → v2 → v3 → v4. Saving always writes v4; loading alone does not rewrite the file. v1/v2 group processes by start working directory, naming directories from path basenames and disambiguating duplicate names, while preserving process IDs, order, and selection.

v3 → v4 converts Supabase services into stacks with the same ID, name, ports, startup selection, failure policy, and start command. Move their directory membership from `serviceIDs` to `stackIDs`, and remove their IDs from `stopOrder`. Other `kind` values become display-only `tag` strings; their stop commands are preserved and become active in v4. Add empty `managedStacks`/`stackIDs` arrays when necessary. Keep `enabledNow` references unchanged. Reject multiple Supabase services per environment or a Supabase service with a custom stop command.

If stacks-first startup or stacks-last shutdown changes the overall order, retain a migration notice until the converted settings are saved. Relative process order remains unchanged. Old `kind: docker` services become ordinary processes with `tag: docker` and are allowed with a warning.

## Preparing JSON with an AI assistant

Ask for environment names, named absolute directory paths, process names/executables/arguments/order/stop commands, stacks and their configuration, default selection, failure policy, and optional ports/Open URLs. Do not infer unspecified commands or policies.

You may inspect user-selected `package.json`, `supabase/config.toml`, and Compose files to substantiate settings. Do not read `.env`, `.env.*`, or `.envrc`; do not start services, install dependencies, or run database migration/reset/seed to prepare or validate JSON.

Validate JSON syntax, required and unknown keys, ID uniqueness, references, and path existence. Import alone does not prove that an executable is installed or its command will start successfully. The user reviews the import and starts services separately.
