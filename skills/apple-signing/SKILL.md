---
name: apple-signing
description: Apple developer account, certificates, keys and portal setup for any of our iOS/macOS apps — which credential lives where (1Password apple-developer item, secrets-run), the one-time portal steps for a new app (App Group, App IDs, Push, App Store Connect record), headless device signing, APNs, TestFlight, the shared Apple slot (one lock for every xcodebuild), and the Mac release recipe outside the store (Developer ID signing, notarization, Sparkle appcast and its missing Team ID pin, GitHub release from the mini or a hosted runner, formula versus cask, notification permission and the time-sensitive entitlement). Use before creating, signing or releasing a new Apple app, or when xcodebuild, codesign or notarytool fails on provisioning, entitlements, App Groups, Push, the signing keychain or a notary verdict.
---

# Apple signing

The reference is `~/SourceRoot/dotfiles/docs/apple-signing.md`: read it first. It holds the credential map, the new-app portal checklist, the Apple slot, the Mac release recipe, the traps and how to prove an entitlement on a device.

Rules that decide behaviour:

- Credentials come from `secrets-run read op://mini/apple-developer/<field>` on the mini, never `op`. Never print a key, token or the team id into a tracked file or log.
- A provisioning error naming `application-groups` or `aps-environment` is a missing portal capability on an App ID: ask the owner for the portal step (it is the Account Holder's and takes minutes), never strip the key from the tracked entitlements. The owner needs exact click paths: use the checklist in the reference.
- New app: ask for the portal steps **up front**, in one message, before the first device build; do not discover them one failing build at a time.
- Every xcodebuild / devicectl / archive / release runs through the shared Apple slot: the repo's `scripts/apple-slot.sh` (lock `/tmp/iris-apple.lock`, then a factory slot). A new app copies it from `~/SourceRoot/ntfy-mac/scripts/apple-slot.sh`; steps in the reference.
- Mac release outside the store: the pipeline in the reference ("Mac release"), implemented in iris `scripts/mac-release.sh`. Notarization `--wait` exits 0 on Invalid: read the status. Sparkle keys go in by `--ed-key-file`, never the keychain (headless it hangs).
- A release may run on a hosted GitHub runner instead of the mini (the certificate as a `.p12` secret in a throwaway keychain, every secret checked before the tag): the reference's "Release on a hosted GitHub runner", proven by ntfy-mac. A new Mac app gets its own Sparkle key pair; Sparkle never pins the Team ID, so the release gate and the app do.
- Per-repo recipes (Iris: `AGENTS.md` "Device" and "Mac releases", skills `device` and `apple-dev`) stay in the repo; add new general learnings to the reference, not here.
