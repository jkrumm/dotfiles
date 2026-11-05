---
name: apple-signing
description: Apple developer account, certificates, keys and portal setup for any of our iOS/macOS apps — which credential lives where (1Password apple-developer item, secrets-run), the one-time portal steps for a new app (App Group, App IDs, Push, App Store Connect record), headless device signing, APNs, TestFlight, notarization, and the provisioning errors that mean a portal capability is missing. Use before creating or signing a new Apple app, or when xcodebuild fails on provisioning, entitlements, App Groups or Push.
---

# Apple signing

The reference is `~/SourceRoot/dotfiles/docs/apple-signing.md`: read it first. It holds the credential map, the new-app portal checklist, the traps and how to prove an entitlement on a device.

Rules that decide behaviour:

- Credentials come from `secrets-run read op://mini/apple-developer/<field>` on the mini, never `op`. Never print a key, token or the team id into a tracked file or log.
- A provisioning error naming `application-groups` or `aps-environment` is a missing portal capability on an App ID: ask the owner for the portal step (it is the Account Holder's and takes minutes), never strip the key from the tracked entitlements. The owner needs exact click paths: use the checklist in the reference.
- New app: ask for the portal steps **up front**, in one message, before the first device build; do not discover them one failing build at a time.
- Every xcodebuild / devicectl / archive runs under `lockf -t 1800 /tmp/iris-apple.lock timeout 1500 …`.
- Per-repo recipes (Iris: `AGENTS.md` "Device", skills `device` and `apple-dev`) stay in the repo; add new general learnings to the reference, not here.
