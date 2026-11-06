---
description: Apple developer setup for every app of ours — what lives where (portal, 1Password, the mini), which credential does what, the order of a new app's one-time portal steps, and the traps that cost hours on Iris (App Group, Push, headless signing, tunnel, lock). Read before touching an Apple signing, provisioning, APNs, TestFlight or Sparkle problem, or before starting a new iOS/macOS app.
---

# Apple signing — one team, many apps

> - **One paid team for everything.** Team id: `op://mini/apple-developer/team-id`. Never in a tracked file.
> - **Anything an API key cannot do is the Account Holder's, once per app, in the portal:** registering an App Group,
>   attaching it to an App ID, a Developer ID certificate, the App Store Connect app record.
> - **Headless on the mini = `secrets-run` + the ASC Team key + `-allowProvisioningUpdates`.** Never `op`, never Xcode's account.
> - **A provisioning error that names an entitlement means the portal lacks that capability on that App ID**, not a code bug.

## Credentials: what, where, used for

All in the 1Password item `op://mini/apple-developer`, read on the mini with `secrets-run read` (seeded via `dotfiles-private/headless.refs`).

| Field | What it is | Used for |
|-|-|-|
| `team-id` | the paid team's id | `DEVELOPMENT_TEAM`, ExportOptions `teamID` |
| `asc-key-p8`, `asc-key-id`, `asc-issuer-id` | App Store Connect **Team** API key (Users and Access > Integrations; an individual key cannot do provisioning or notarytool) | `xcodebuild -allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID` (creates App IDs, profiles, devices), TestFlight upload, `notarytool` |
| `apns-key-p8`, `apns-key-id` | APNs **auth key** (token auth) | the server's APNs notifier (`APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_TOPIC` = bundle id). The key is not per environment (sandbox vs production is the token's host; unverified for production until the first TestFlight build). |
| Sparkle EdDSA key | Mac update signing | private key in the mini's login keychain, backup file `~/.local/state/apple-developer/sparkle-ed25519.key` (0600, outside every repo); the 1Password copy is the owner's |

Not credentials, but needed: an Apple Development identity in the mini's login keychain (cloud-managed by `-allowProvisioningUpdates`), a Developer ID Application certificate for the Mac (Account Holder creates it).

- 1Password flattens the `.p8` newlines into spaces. Rebuild real newlines and 64-character body lines before `-authenticationKeyPath` (Iris: `pem_normalize` in `scripts/device-lib.sh`; the server: `normalizePem`). Write it to a `mktemp` file, mode 0600, delete it with a `trap` on `EXIT`.
- "Certificates (0)" under Push Notifications in the portal is irrelevant: auth-key APNs needs no per-App-ID certificate.

## A new app: the one-time portal steps (Account Holder, ~5 minutes)

Do these before the first device build; the API key does the rest. Portal: developer.apple.com > Certificates, Identifiers & Profiles.

1. **App Group** (if the app shares data between app and extensions): the filter top right > App Groups > **+** > App Groups > description, identifier `group.<bundle id>`. Register it first.
2. **App IDs:** with `-allowProvisioningUpdates` the first build creates them (named `XC <bundle id>`). Then, **for each App ID that needs the group** (app and every extension that reads it): open it > App Groups > Configure/Edit > tick the group > Continue > Save.
3. **Push Notifications** only on the App ID that holds `aps-environment` (the main app; widgets and notification-service extensions do not need it).
4. **App Store Connect app record** (for TestFlight upload): My Apps > + > the bundle id.
5. **Mac outside the store:** a Developer ID Application certificate (Certificates > + > Developer ID Application; the Account Holder creates it from a CSR whose private key lives on the signing machine). Export certificate + private key as a `.p12`, back it up as a 1Password Document in vault `mini`, import it on the mini. Notarization then uses the same Team key. Recipe: *Mac release* below.

An entitlement in the tracked `*.entitlements` that the portal's App ID lacks fails the whole build with "Provisioning profile … doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" (or `aps-environment`). Fix the portal, rerun; never strip the key from the tracked file. The Personal Team fallback (free, no Push, no App Groups) strips them in derived copies only.

## Traps (all hit on Iris, 2026-11)

| Trap | Fix |
|-|-|
| App Group missing: three-target build failure | portal steps 1-2 above; nothing in code or the API key helps |
| `devicectl list devices` shows the phone `disconnected` but `available (paired)` | the tunnel comes up on first use: accept `disconnected`, skip only `unavailable`; the phone must be awake/unlocked for `launch`, not for install |
| Two Apple jobs at once | every xcodebuild/devicectl/archive runs through the shared Apple slot (*The Apple slot* below); a release job (notarization up to 40 min) holds it, a 900 s wait times out |
| APNs sandbox vs production | Xcode Debug builds use the sandbox host and tokens; TestFlight/App Store builds use production: `apnsEnv` follows the channel (`#if DEBUG`) |
| `devicectl device copy from --domain-type appGroupDataContainer` refuses a file at the container root | only `Library`, `Documents`, `tmp` are readable: prove a write by a device-log line, not by the file |
| No device log access without root | the app's own telemetry relay (HyperDX, `agw otel`) is the log; add an event for anything you need to prove |
| Build number | `CFBundleVersion` from `git rev-list --count HEAD`, never committed |

## The Apple slot: one lock for every app

The mini runs one Apple job at a time across all repos: Xcode builds, archives, `devicectl`, notarization. Two repos share it today, by **one lock file, `/tmp/iris-apple.lock`** (the name is historical; renaming it in one repo splits the lock and re-opens the collision). The wrapper:

```bash
# on the mini (factory present): lock first, then a factory test slot named per repo; anywhere else (CI, MacBook): the bare command
exec lockf -t "${APPLE_LOCK_WAIT:-1800}" /tmp/iris-apple.lock factory slot run --name <repo>-apple -- "$@"
```

- Reference implementations: iris `scripts/apple-slot` (adds `--sim`: shuts every simulator down when the job ends, and `IRIS_APPLE_SLOT` re-entrancy so a make target called by another runs bare) and ntfy-mac `scripts/apple-slot.sh` (the minimal form, 17 lines). Copy the minimal one.
- Exit 75 = no lock or slot within the wait. Retry later; never remove the lock file.
- Order is lock, then slot: the factory's test slots are host-wide (default two), so the lock is what serialises Apple jobs.

**A new Mac or iOS app adopts it in three steps:**

1. Copy `scripts/apple-slot.sh` from ntfy-mac. Keep the lock path `/tmp/iris-apple.lock`; change only `--name` to `<repo>-apple`.
2. In the Makefile, prefix every `xcodebuild`, `devicectl`, archive and release target with it (`APPLE := scripts/apple-slot.sh`, then `$(APPLE) xcodebuild …`). A release script runs inside the wrapper as a whole (`$(APPLE) scripts/mac-release.sh`), not wrapping each call.
3. A bare script call from a shell: `scripts/apple-slot.sh timeout 2400 make mac-release …`. A hook or poller that starts a release wraps its whole `make` call the same way.

## Mac release: Developer ID, notarization, Sparkle, GitHub (proven on Iris, 2026-11)

One script per app (Iris: `scripts/mac-release.sh`, `make mac-release IDENTITY=development|developer-id [PUBLISH=draft|release]`). Copy its shape; the app-specific parts are the scheme, bundle name, release repo and the entitlement assertions.

**Pipeline, in order:**

1. **Preconditions:** `HEAD` is on origin (GitHub rejects a release `--target` it does not have: 422); a clean tree for `PUBLISH=release`; the Sparkle key file readable.
2. **Build number** `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)`, passed on the command line, never committed. Sparkle compares `CFBundleVersion`, so it must grow with every release.
3. **Archive** `Release` with `ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`. The last one keeps Xcode from adding `get-task-allow`, which notarization refuses.
   - `development`: `CODE_SIGN_STYLE=Automatic`, identity `Apple Development`, `-allowProvisioningUpdates` with the ASC Team key. Pipeline proof only: never notarized, `PUBLISH=draft` only (the script refuses `release`).
   - `developer-id`: `CODE_SIGN_STYLE=Manual`, identity `Developer ID Application`, no auth flags. The identity must be in a keychain on the search list.
4. **Re-sign Sparkle inside out.** Sparkle ships its helpers (`Autoupdate`, `Updater.app`, the XPC services) ad-hoc signed and Xcode only re-signs the framework; notarization rejects them ("not signed with a valid Developer ID certificate", no secure timestamp). `codesign --force --options runtime --timestamp --sign <id>` over the XPC services, `Autoupdate`, `Updater.app`, the framework, then the app last with its entitlements (`codesign -d --entitlements - --xml` first, pass them back with `--entitlements`).
5. **Check the signature** before spending notary time: `codesign --verify --deep --strict`; `TeamIdentifier` is the paid team; `flags=` contains `runtime`; a `Timestamp=` line; the entitlements the app needs are present and `app-sandbox` / `get-task-allow` are absent. Here-strings, not `printf | grep -q` (pipefail turns the early-exit SIGPIPE into a failure).
6. **Notarize** (`developer-id`): `ditto -c -k --sequesterRsrc --keepParent` to a zip, `xcrun notarytool submit --key <file> --key-id --issuer --wait --timeout 30m --output-format json`. **`--wait` exits 0 on an Invalid verdict**: read `.status` and fail unless it is `Accepted`, printing `notarytool log <id>`. Then `stapler staple` + `stapler validate` + `spctl --assess --type execute` (must say `Notarized Developer ID`).
   - The queue can take hours, first submissions especially. On a timeout the script prints the submission id; `RESUME_BUILD=<n> RESUME_NOTARY_ID=<id>` continues with the same archive via `notarytool wait`, no rebuild and no re-sign (a changed byte voids the submission).
7. **Zip the stapled app** (`ditto`, stapling changed bytes), then **appcast** with the pinned Sparkle tools: `generate_appcast --ed-key-file <file> --download-url-prefix https://github.com/<owner>/<repo>/releases/download/<tag>/ <dir>`. Verify: `sparkle:edSignature` present, `sparkle:version` equals the build, `sign_update --verify --ed-key-file <file> <zip> <sig>`. Tools live in `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin`.
8. **Publish:** `gh release create mac-v<version>-<build> <zip> appcast.xml --target <sha>` (+ `--draft`). Nothing is written back to the repo.

**Facts that cost time:**

- **Sparkle key as a file, never the keychain.** Headless, `sign_update` and `generate_appcast` hang on the keychain's access prompt. Use `--ed-key-file`; the key is exported once (`generate_keys -x <file>`) to `~/.local/state/apple-developer/sparkle-ed25519.key` (0600, outside every repo). The app's `SUPublicEDKey` is the public half of that key. Iris's key is the only one so far; whether a second app reuses it or gets its own is the owner's call (unverified: `generate_keys --account`). The 1Password copy is a Document in vault `mini`, owner-managed.
- **Feed URL = `releases/latest/download/appcast.xml`** (`SUFeedURL`). `latest` never serves a draft, so a draft is safe, but **any** published release on that repo becomes the feed: a repo that also ships non-Mac releases needs a different feed host.
- **Developer ID in a dedicated keychain.** Put the identity in its own keychain on the user search list with `security set-key-partition-list -S apple-tool:,codesign: -s -k <pass> <keychain>`; a reboot leaves it locked, so the script runs `security unlock-keychain -p` from a 0600 password file outside every repo (`~/.local/state/apple-developer/`). `errSecInternalComponent` from `codesign` means that keychain is locked or the partition list lacks `codesign:`. The unlock password is the one secret that touches argv (`-p` takes nothing else); keep the keychain used for nothing else.
- **ASC key file:** mktemp, 0600, `trap … EXIT` (see the credentials section). `notarytool` takes `--key` as a file path, same as xcodebuild.
- **Quarantined installs do not self-update.** A zip downloaded by a browser carries `com.apple.quarantine`; the app then runs from an `AppTranslocation` path and Sparkle's silent update never starts. An install without the flag updates fine: staged while the app runs, `Autoupdate` swaps it right after a quit, no admin prompt. Until the release ships as a DMG (or the interactive "Check for Updates…" alert is proven), tell the owner to `xattr -d com.apple.quarantine <app>` after install; it cannot be done over ssh (App Management).
- **Not sandboxed.** A Developer ID app that Sparkle swaps in place is not sandboxed; moving off the sandbox moves data from the container to `~/Library/Application Support/<app>` and the old signature's Keychain items may be unreadable. Check first launch.
- **A poller or hook that triggers releases:** after its first run, ticks may log "starting detached" with no job; run the release script by hand once to unstick it.
- **Prove it** on a second machine: `spctl -a -vv <app>` says `source=Notarized Developer ID`, `stapler validate` works offline, a quarantined first launch needs no "Open Anyway", release N to N+1 updates.

## Proving an entitlement on the phone

```bash
codesign -d --entitlements :- <Iris.app or .appex> | plutil -convert json -o - -     # the group, aps-environment, keychain groups
```

then an app event that reads `containerURL(forSecurityApplicationGroupIdentifier:)` (Iris: `widget.container`, `available=true`) and one that shows a real write (`widget.snapshot saved=true`).

## Where the details live

Per-repo recipes stay in the repo (Iris: `AGENTS.md` "Device" and "Mac releases", skills `device`, `apple-dev`, `scripts/mac-release.sh` as the reference implementation, `docs/research/2026-11-04-apple-paid-team.md` for the design). This file is what holds for every app, so a new Mac app follows it without reading Iris. The global skill `apple-signing` points here.
