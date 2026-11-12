# Dev Switcher — Roadmap

Updated: 2026-11-12. [日本語](../ROADMAP.md) · [Specification](SPEC.md)

## Implemented baseline

- Phase A: generalized managed-stack identities, observations, drivers, supervisors, confirmation plans, and runtime hints; Supabase uses the common path.
- Phase C: schema v4, migration with order-change notices, display-only tags, separate processes and stacks, custom ordinary-process stop commands, editor and JSON import.
- Phase B: Docker Compose resolution, observation, startup, adoption, recovery, and all-profile shutdown. Real Compose v5.5.0 checks were confirmed on 2026-11-12.
- Direct-directory discovery: package.json scripts and Compose candidates, explicit selection, manager evidence, source-change revalidation, and atomic form insertion. Recursive workspace discovery and Procfile remain out of scope.

## Japanese and English: implemented, native verification pending

The selected policy preserves Japanese and chooses Japanese or English from Mac/app language preferences. Translate interface text, application errors, confirmations, and the copied import guide. Keep user data, JSON keys, commands, and external logs unchanged. English product, architecture, and schema documents accompany the Japanese originals. See the Japanese roadmap for the latest verification status.

Implemented on 2026-11-12 with 757 translated messages after consolidating sentence fragments and removing unused keys, bundled resources, an English import guide, and CI validation. Build and catalog validation passed. All nine new localization tests passed; the complete run had 574 passing tests and the same 29 failures as the pre-change baseline, involving real-process identity and handoff. The runner required SwiftPM's `--disable-sandbox` option and a temporary scratch directory. English detail text and confirmation content were inspected in supplemental renders. Full native UI inspection (including AppKit fields and logs) and changing the app language through macOS settings remain unverified. No real Docker/Supabase lifecycle operations or distribution were performed for this change.

The same-day review also reused the placeholder pattern, shared startup language selection with the guide, and separated resource validation from writing. Missing English translations, mismatched placeholders, and a missing guide section were verified to leave generated files unchanged; stale-resource checking was also verified as read-only. Temporary rendering code and session build files, images, extraction scripts, and logs were removed after recording the results. Layout assertions remain in the test suite.

## Deferred readiness

Readiness was deferred by the PM on 2026-11-12. No concrete problem has yet justified the burden of configuring a confirmation URL. The tentative display-only implementation was withdrawn. Ordinary startup still uses the default three-second liveness check. Revisit readiness when “started but not responding” causes an actual workflow problem.

## Later candidates

Public distribution requires decisions about a public repository, license, README, and public download URLs before Homebrew cask support. Existing private-release instructions cover Developer ID signing and notarization; automatic updates are not currently planned.

Menu-bar status/switching and a global hotkey may improve switching speed. They require consistent operation locking and progress across two interfaces, and a hotkey path for machines where the notch hides menu-bar items.

Other demand-driven candidates include Compose one-shot service classification, runtime-hint persistence during forced app termination, Expo QR/LAN/tunnel controls, combined process logs, and individual stack start/stop. Do not implement them as part of localization.
