---
description: Apple developer setup for every app of ours — what lives where (portal, 1Password, the mini), which credential does what, the order of a new app's one-time portal steps, the traps that cost hours on Iris (App Group, Push, headless signing, tunnel, lock), and the Mac release outside the store on the mini or a hosted GitHub runner (Developer ID, notarization, Sparkle, formula versus cask), and a Tauri app's release (bundled CLI, notarization outside `tauri build`, update key and feed). Read before touching an Apple signing, provisioning, APNs, TestFlight, notarization or Sparkle problem, or before starting a new iOS/macOS app.
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
| Sparkle EdDSA key | Mac update signing, **one key pair per app** | Iris: private key in the mini's login keychain, backup file `~/.local/state/apple-developer/sparkle-ed25519.key`. ntfy-mac: its own pair, file `sparkle-ntfy-mac-ed25519.key` in the same directory, and the repo secret `SPARKLE_ED_PRIVATE_KEY` for CI. 0600, outside every repo; the 1Password copy is the owner's |
| Tauri update key (minisign) | the Tauri updater's signing key, **one pair per app**; the app accepts only an archive this key signed | shutterflow: private half the file `~/.local/state/apple-developer/shutterflow-updater.key` (0600, no password, outside every repo), public half compiled into the app as `plugins.updater.pubkey`; the 1Password Document in vault `mini` is the owner's copy, the one that outlives the mini. Losing it strands every installed copy: *A Tauri app*, below |

Not credentials, but needed: an Apple Development identity in the mini's login keychain (cloud-managed by `-allowProvisioningUpdates`), a Developer ID Application certificate for the Mac (Account Holder creates it).

- 1Password flattens the `.p8` newlines of a concealed field into spaces, and a CI secret can arrive with a literal `\n`. Rebuild real newlines and 64-character body lines before `-authenticationKeyPath` or `notarytool --key`. Copy ntfy-mac's `pem_normalize` (`scripts/apple-credentials.sh`): it takes either shape, keeps the BEGIN/END label and folds the body at 64. Iris has `pem_normalize` in `scripts/device-lib.sh`, the server `normalizePem`. Write the result to a `mktemp` file, mode 0600, delete it with a `trap` on `EXIT`.
- "Certificates (0)" under Push Notifications in the portal is irrelevant: auth-key APNs needs no per-App-ID certificate.

## A new app: the one-time portal steps (Account Holder, ~5 minutes)

Do these before the first device build; the API key does the rest. Portal: developer.apple.com > Certificates, Identifiers & Profiles.

1. **App Group** (if the app shares data between app and extensions): the filter top right > App Groups > **+** > App Groups > description, identifier `group.<bundle id>`. Register it first.
2. **App IDs:** with `-allowProvisioningUpdates` the first build creates them (named `XC <bundle id>`). Then, **for each App ID that needs the group** (app and every extension that reads it): open it > App Groups > Configure/Edit > tick the group > Continue > Save.
3. **Push Notifications** only on the App ID that holds `aps-environment` (the main app; widgets and notification-service extensions do not need it).
4. **App Store Connect app record** (for TestFlight upload): My Apps > + > the bundle id.
5. **Mac outside the store:** a Developer ID Application certificate (Certificates > + > Developer ID Application; the Account Holder creates it from a CSR whose private key lives on the signing machine). Export certificate + private key as a `.p12`, back it up as a 1Password Document in vault `mini`, import it on the mini. Headless, `security export` waits on a GUI approval that nobody answers (`set-key-partition-list` does not lift it): build the `.p12` with `openssl pkcs12 -export` from the private key and the certificate PEM kept in `~/.local/state/apple-developer/`, and prove it by importing into a throwaway keychain (ntfy-mac `AGENTS.md` "Release process"). Notarization then uses the same Team key. Recipe: *Mac release* below.

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
| Build number | `CFBundleVersion` from `git rev-list --count HEAD`, never committed. A repo whose releases carry a semantic-release version can stamp that `x.y.z` instead (ntfy-mac `scripts/stamp-version.sh`, working tree only): Sparkle needs only a value that grows |

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
4. **Re-sign Sparkle inside out.** Sparkle ships its helpers (`Autoupdate`, `Updater.app`, the XPC services) ad-hoc signed and Xcode only re-signs the framework; notarization rejects them ("not signed with a valid Developer ID certificate", no secure timestamp). `codesign --force --options runtime --timestamp --sign <id>` over the XPC services, `Autoupdate`, `Updater.app`, the framework, then the app last with its entitlements (`codesign -d --entitlements - --xml` first, pass them back with `--entitlements`). Anything else executable in the bundle (a bundled CLI in `Contents/MacOS`) is signed before the app, never with `--deep`: see *A SwiftPM package with an xcodegen app* below.
5. **Check the signature** before spending notary time: `codesign --verify --deep --strict`; `TeamIdentifier` is the paid team; `flags=` contains `runtime`; a `Timestamp=` line; the entitlements the app needs are present and `app-sandbox` / `get-task-allow` are absent. Here-strings, not `printf | grep -q` (pipefail turns the early-exit SIGPIPE into a failure). Run the check on every piece that ships, not on the app alone: ntfy-mac `scripts/verify-signature.sh` loops over the app, the bundled CLI, the framework and each helper, and its `--release` mode adds the staple and Gatekeeper checks of step 6.
6. **Notarize** (`developer-id`): `ditto -c -k --sequesterRsrc --keepParent` to a zip, `xcrun notarytool submit --key <file> --key-id --issuer --wait --timeout 30m --output-format json`. **`--wait` exits 0 on an Invalid verdict**: read `.status` and fail unless it is `Accepted`, printing `notarytool log <id>`. Then `stapler staple` + `stapler validate` + `spctl --assess --type execute` (must say `Notarized Developer ID`). The ticket can lag the `Accepted` verdict: retry `stapler staple` a few times, ten seconds apart (ntfy-mac `scripts/sign.sh`, five tries).
   - The queue can take hours, first submissions especially. On a timeout the script prints the submission id; `RESUME_BUILD=<n> RESUME_NOTARY_ID=<id>` continues with the same archive via `notarytool wait`, no rebuild and no re-sign (a changed byte voids the submission).
7. **Zip the stapled app** (`ditto`, stapling changed bytes), then **appcast** with the pinned Sparkle tools: `generate_appcast --ed-key-file <file> --download-url-prefix https://github.com/<owner>/<repo>/releases/download/<tag>/ <dir>`. Verify: `sparkle:edSignature` present, `sparkle:version` equals the build, `sign_update --verify --ed-key-file <file> <zip> <sig>`. Tools live in `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin`.
8. **Publish:** `gh release create mac-v<version>-<build> <zip> appcast.xml --target <sha>` (+ `--draft`). Nothing is written back to the repo.

**Facts that cost time:**

- **Sparkle key as a file, never the keychain.** Headless, `sign_update` and `generate_appcast` hang on the keychain's access prompt. Use `--ed-key-file`; the key is exported once (`generate_keys -x <file>`) to `~/.local/state/apple-developer/sparkle-ed25519.key` (0600, outside every repo). The app's `SUPublicEDKey` is the public half of that key. **One key pair per app**: ntfy-mac has its own (`sparkle-ntfy-mac-ed25519.key`), so a leaked or rotated key costs one app. A new app generates its pair and names the file after the repo. The 1Password copy is a Document in vault `mini`, owner-managed.
- **Feed URL = `releases/latest/download/appcast.xml`** (`SUFeedURL`), the appcast a release asset next to the zip. `latest` never serves a draft, so a draft is safe, but **any** published release on that repo becomes the feed: a repo that also ships non-Mac releases needs a different feed host. Before the first release carrying an appcast the URL answers 404 and "Check for Updates…" shows an update error: expected, not a defect (ntfy-mac `docs/waves/PLAN.md` Wave 7). Create the release as a draft, upload every asset, then publish, so the feed never points at a missing file (ntfy-mac `AGENTS.md` "Release process" step 3).
- **The appcast script (copy ntfy-mac `scripts/appcast.sh`).** `generate_appcast` scans the whole directory and merges a stale `appcast.xml`: copy only the release zip into a fresh temp directory. The zip is a `ditto` of the stapled app alone. `--download-url-prefix https://github.com/<owner>/<repo>/releases/download/<tag>/`. Before succeeding the script checks the item: `sparkle:edSignature` present, `sparkle:version` equals the build, the enclosure URL names the asset, `sign_update --verify` accepts the zip. In CI the key arrives as a secret and is written to a 0600 temp file for `--ed-key-file`.
- **Developer ID in a dedicated keychain.** Put the identity in its own keychain on the user search list with `security set-key-partition-list -S apple-tool:,codesign: -s -k <pass> <keychain>`; a reboot leaves it locked, so the script runs `security unlock-keychain -p` from a 0600 password file outside every repo (`~/.local/state/apple-developer/`). `errSecInternalComponent` from `codesign` means that keychain is locked or the partition list lacks `codesign:`. The unlock password is the one secret that touches argv (`-p` takes nothing else); keep the keychain used for nothing else.
- **ASC key file:** mktemp, 0600, `trap … EXIT` (see the credentials section). `notarytool` takes `--key` as a file path, same as xcodebuild.
- **Quarantined installs do not self-update.** A zip downloaded by a browser carries `com.apple.quarantine`; the app then runs from an `AppTranslocation` path and Sparkle's silent update never starts. An install without the flag updates fine: staged while the app runs, `Autoupdate` swaps it right after a quit, no admin prompt. **Proven live on ntfy-mac, 2026-11-14:** 2.0.0 (the published tarball, checked on the mini, `quarantine=0`) to 2.0.1 through the published appcast, Sparkle's prompt, relaunch, same bundle id, config and history kept, Gatekeeper still `Notarized Developer ID`, the team pin matching (`docs/waves/PLAN.md` Wave 7, Issue 1045). Not yet seen there: Sparkle's own scheduled check finding an update, and an update of a quarantined install. Until the release ships as a DMG (or the interactive "Check for Updates…" alert is proven), tell the owner to `xattr -d com.apple.quarantine <app>` after install; it cannot be done over ssh (App Management).
- **Not sandboxed.** A Developer ID app that Sparkle swaps in place is not sandboxed; moving off the sandbox moves data from the container to `~/Library/Application Support/<app>` and the old signature's Keychain items may be unreadable. Check first launch.
- **A poller or hook that triggers releases:** after its first run, ticks may log "starting detached" with no job; run the release script by hand once to unstick it.
- **Prove it** on a second machine: `spctl -a -vv <app>` says `source=Notarized Developer ID`, `stapler validate` works offline, a quarantined first launch needs no "Open Anyway", release N to N+1 updates.

## A SwiftPM package with an xcodegen app (ntfy-mac shape)

Iris archives an Xcode project. A Mac app built as a SwiftPM package plus an xcodegen app target, with a CLI bundled inside the app, signs after the build instead. The single entry point is ntfy-mac `scripts/sign.sh <app>`:

- **Default is ad-hoc** (`codesign --force --deep --sign -`), so the gate, snapshots and CI need no certificate. `SIGN_IDENTITY=developer-id` switches to the real identity; `NOTARIZE=1` with an ad-hoc app is refused, because an ad-hoc app cannot be notarized.
- **Inside out, never `--deep`**, on the Developer ID path. Order: the Sparkle XPC services, `Autoupdate`, `Updater.app`, the framework, the bundled CLI at `Contents/MacOS/<cli>`, the app last.
  - Every piece gets `--options runtime --timestamp`; the XPC services also get `--preserve-metadata=entitlements`.
  - A missing helper fails the script (Sparkle's layout changed) instead of being skipped.
- **Every run ends in `scripts/verify-signature.sh`**; a failed check is a non-zero exit, so a half-signed bundle never reaches notarization or `package.sh`.
- The app holds no entitlements and is not sandboxed. A Developer ID app needs none to be notarized.
- A resumed notarization (`RESUME_NOTARY_ID`, step 6) skips the signing step entirely: re-signing would change bytes and void the submission.

## Release on a hosted GitHub runner (ntfy-mac, proven 2026-11-13)

**Public repos only:** the VPS runner our private repos use cannot build a Mac app, and a hosted macOS minute costs about ten times a Linux minute (shutterflow `docs/decisions/0060-distribution-and-updates.md` "Why", *The mini, not a hosted runner*). A private Mac app releases on the mini, as Iris does; the decision for a Tauri app is *A Tauri app (shutterflow shape)*, below. For a public repo, a release does not have to run on the mini. ntfy-mac's `.github/workflows/release.yml` (`workflow_dispatch`, runner `macos-26`) builds, signs, notarizes, uploads and updates the tap with no Apple slot and no signing identity installed beforehand; the first run succeeded end to end.

**Repository secrets** (set each with `printf '%s' "$value" | gh secret set <NAME>`: `secrets-run read` ends with a newline and a trailing newline stays in the secret):

| Secret | Holds |
|-|-|
| `APPLE_TEAM_ID` | the team id, for the identity lookup and the signature check |
| `APPLE_DEVELOPER_ID_P12_BASE64`, `APPLE_DEVELOPER_ID_P12_PASSWORD` | the Developer ID Application certificate with its private key as a `.p12` (built with `openssl pkcs12 -export`, see the portal steps), base64, and its password |
| `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | the App Store Connect Team key for `notarytool` |
| `SPARKLE_ED_PRIVATE_KEY` | the content of the app's Sparkle key file |

**Steps, in order:**

1. **Check every secret before anything is tagged.** semantic-release tags first, so a missing secret found later leaves a tag with no release. A step that lists the names and fails with `::error::missing repository secrets: …` goes before the release step.
2. **Select Xcode** with `xcode-select -s /Applications/Xcode_<version>.app`: the image's default can differ from the one the app builds with. Give the job a long `timeout-minutes` (ntfy-mac: 120) and `NOTARY_TIMEOUT` below it (90m). A first notarization can queue for hours; when it outlasts the timeout the script prints the submission id, and a rerun with `RESUME_NOTARY_ID` continues it (step 6 above).
3. **Import the certificate into a throwaway keychain.** In order:
   - decode the `.p12` into `$RUNNER_TEMP`;
   - `security create-keychain` with a `uuidgen` password, masked with `::add-mask::`;
   - `set-keychain-settings -lut 21600`, then `unlock-keychain`;
   - `security import … -P <password> -A -t cert -f pkcs12`, then delete the `.p12`;
   - `set-key-partition-list -S apple-tool:,apple: -s -k <password>`;
   - put the keychain first on the user search list, so `security find-identity` and `codesign` see it.
4. **Run the release step** with `SIGN_IDENTITY=developer-id NOTARIZE=1` and the credential secrets as environment: `scripts/sign.sh` reads them from the environment first and from `secrets-run` second, so the same script runs on the mini and in CI.
5. **Remove the keychain** in an `if: always()` step (`security delete-keychain`), so a failed run leaves nothing on a reused runner.

**Recovery:** if the tag exists but the GitHub release or an asset upload failed, a re-run does not publish. Delete the tag and the draft release, then re-run (ntfy-mac `AGENTS.md` "Release process").

The CI keychain differs from the mini's: a throwaway keychain with the `apple:` partition, against a dedicated keychain with the `codesign:` partition opened from a password file. Both are proven; keep them apart.

## A Tauri app (shutterflow shape)

Shutterflow is a Tauri 2 desktop app in a private repository, released from the mini with Tauri's own updater instead of Sparkle. What follows is what ran there, not what its plan said. Proof, from `~/SourceRoot/shutterflow`:

- `make mac-release` for `0.1.1064`: the app and the dmg `Accepted`, stapled, `spctl` says `Notarized Developer ID`.
- `PUBLISH=draft`, then `make release-promote` for `0.1.1129` against the real feed on 2026-11-16.
- `make update-proof REAL_FEED=1`: 11 of 11 checks, `0.1.1128` updated itself to `0.1.1129`.
- The owner's MacBook installed `0.1.1129` from the download URL and updated in the app to `0.1.1134`.

Source files below are shutterflow's. `0060` is `docs/decisions/0060-distribution-and-updates.md` (its sections *Proven*, *Published* and *On the owner's MacBook* hold the runs), `tauri.md` is `docs/engineering/tauri.md` §9.

**Pipeline** (`scripts/mac-release.sh`, run whole inside the Apple slot, `scripts/apple-slot.sh`, slot name `shutterflow-apple`: `0060` §2). Credentials and the keychain come from `scripts/apple-credentials.sh`, the ntfy-mac helper (`pem_normalize` included), unchanged in shape. The steps differ from the Xcode shapes above:

1. **Version.** `0.<workspace minor>.$(git rev-list --count HEAD)`, never committed. It reaches the bundle through `tauri build --config '{"version":…}'` and every binary through one env var read with `option_env!` (`mac-release.sh`; `0060` *Proven (row mac-release-signed)*, "One version mechanism"). The script runs the bundled CLI and requires `--version` to equal `CFBundleShortVersionString`.
2. **Credential preflight.** One read-only `notarytool history` call before the build. A run with a wrong `asc-key-id` stopped at it with `HTTP status code: 401`, nothing built (`0060` *Proven (row mac-release-signed)*).
3. **Build ad hoc.** `tauri build --ci --bundles app` with `signingIdentity: "-"` in `tauri.release.conf.json`. The bundler signs nothing real and builds no dmg.
4. **Sign afterwards, inside out.** The CLI at `Contents/MacOS/shutterflow`, then the app: `codesign --force --options runtime --timestamp`, no entitlements file, never `--deep` (`mac-release.sh` `sign_one`). The notary accepted the bundle with no entitlements file.
5. **Check before notary time.** `scripts/verify-signature.sh` walks every Mach-O in the bundle (`find`, not a fixed list, so an executable a bundler adds later is held to the same facts) and demands the team, a Developer ID authority, `runtime`, a timestamp, no `get-task-allow`, and at least two executables. `--release` adds `stapler validate` and `spctl`. It is ntfy-mac's script with a bundle walk.
6. **Notarize, staple, then the dmg.** The app first, stapled; then the dmg is built by us from the stapled app (`hdiutil create`, an `/Applications` link, `codesign --timestamp`), notarized, stapled, assessed with `spctl --type open --context context:primary-signature`. `--wait` exits 0 on `Invalid`: read `.status`. A timeout prints the id; `RESUME_STAGE=app|dmg RESUME_NOTARY_ID=<id>` continues on the artifacts already built, no rebuild, no re-sign. Staple is retried five times, ten seconds apart (`mac-release.sh`).
7. **Update archive from the stapled app.** `COPYFILE_DISABLE=1 tar -czf Shutterflow.app.tar.gz`, signed with `tauri signer sign --app-version <v>`, then unpacked into a scratch directory where seal, `stapler validate`, `spctl` and the version must hold. Both builds of the update proof passed it: the staple survives the archive (`0060` *Proven (row updater)*).
8. **Publish** (`PUBLISH=draft|release`): *The feed*, below.

### Why notarization runs outside `tauri build`

The bundler can notarize. Three reasons the script does not (`mac-release.sh` header, `0060` *Why*):

- It logs "skipping app notarization" and finishes green when a credential is wrong. The line still prints during our build and is harmless there (`0060` *Proven (row mac-release-signed)*).
- It makes the dmg from an unstapled app and never notarizes the dmg, so the dmg has no ticket.
- It cannot resume a submission that queues for hours.

The same reasoning rules out `bundle.createUpdaterArtifacts`: it would archive the unstapled app (`tauri.md`, "Update archive and the updater").

### A bundled CLI (`externalBin`)

- `tauri.release.conf.json` lists `bundle.externalBin: ["../../../target/bundle-bin/shutterflow"]`. The release config only: the dev config has no sidecar. The bundler wants the file named `shutterflow-<host triple>`, so the script copies `target/release/shutterflow` to `target/bundle-bin/shutterflow-$(rustc -vV | sed -n 's/^host: //p')`; the bundler places it at `Contents/MacOS/shutterflow` (`mac-release.sh`; `tauri.md` "Release").
- It is a plain CLI, not a Tauri sidecar: the app's API server runs in-process (`tauri.md` §7 and "Release").
- Sign it before the app. The seal covers it only if it is signed first (step 4), and `codesign --verify --deep --strict` passes on the app and on the app inside the dmg.
- Prove it from the signed bundle: the script runs `Contents/MacOS/shutterflow --version` with `SHUTTERFLOW_FLEET=1`, `SHUTTERFLOW_KEYCHAIN=off` and a home under `~/ShutterflowLab`. That starts the binary under Hardened Runtime without touching a keychain item (`mac-release.sh` `check_version`).

### The update key

One minisign pair per app, as with Sparkle's. Facts, each from shutterflow:

- Made once with the **pinned** `tauri-cli` (`cargo-tauri tauri signer generate --ci --password '' --write-keys <file>`; `scripts/dev-host/doctor.sh`). `mac-release.sh` refuses a key file that is missing or not mode 0600, and passes it to `tauri signer sign` as `TAURI_SIGNING_PRIVATE_KEY` with an empty password. Tauri's docs say not to keep it in `.env` (`tauri.md`).
- The public half is the **contents** of the `.pub` file, not a path, in `plugins.updater.pubkey` of `tauri.release.conf.json`. It ships inside every build.
- **Losing it strands every installed copy:** an installed app accepts only an archive this key signed (`0060` §3). A forged manifest whose archive carries another key's signature made the install fail with `update_download_failed` and the app stayed on N (`0060` *Proven (row updater)*). A replaced key therefore needs a manual reinstall of every copy: an installed app moves forward only through the updater, and a reinstall by hand is the only other way (`docs/owner-install.md` "Going back").
- The backup comes before the first release: the file on the mini is one copy, the owner's 1Password Document in vault `mini` is the second (`0060` §3). `0060` *Unproven* still lists that Document as an open check on 2026-11-16: confirm it exists before a first release of a new app.

### The feed for a private source repository

Release assets of a private GitHub repository cannot be the update feed: the app would need a token, and a token in the binary can be read out of it (`0060` *Rejected*; tauri-apps/tauri#7329 cited there). A public releases-only repository worked as a first design and the owner rejected it, so shutterflow serves its own files:

- Plain files on the VPS, written by the mini over `ssh vps` (keyless Tailscale SSH), mounted read-only into the share container behind `shutterflow.app`. The URL compiled into the app is one host we own: `https://shutterflow.app/desktop/latest.json` (`0060` §4).
- Layout: `v<version>/{Shutterflow_<version>_<arch>.dmg, Shutterflow.app.tar.gz, Shutterflow.app.tar.gz.sig, latest.json}`, plus a top-level `latest.json`. That file is written last by one atomic rename and **is** the publication; the same rename with an older manifest is the rollback (`scripts/publish-release.sh` header; `make release-promote VERSION=<v>`). A draft is the first four files: nothing links to them.
- Nothing is trusted because it was uploaded. The draft is read back through the public URL and compared byte for byte, the archive's signature is verified against the public key, and the manifest must name the same version, signature and URL (`scripts/release/verify-release.ts`, run before and after the upload). On 2026-11-16 a draft read back equal, left `/desktop/latest.json` a 404, and promotion made it name `0.1.1129` (`0060` *Published*).
- Preconditions run before the build: `release` needs a clean tree, HEAD on `origin/master`, and a version newer than the published one; a draft needs HEAD on a remote branch (`mac-release.sh` header).
- The last five versions stay on disk, never the published one. The previous dmg is the way back.

### The team pin

The plugin checks only the minisign signature, like Sparkle only the EdDSA one. The pin is ours, in two places, as for ntfy-mac:

1. **The release gate:** `verify-signature.sh` (step 5).
2. **The app:** `apps/desktop/src-tauri/src/updater.rs` registers the plugin only for the release identifier (`app.shutterflow.desktop`; `.dev`, `.e2e` and ad-hoc builds never update) with a Developer ID signature whose team equals the one stored by the first signed run (`<config dir>/updater-team`, ntfy-mac's `TeamPin` pattern), outside `AppTranslocation` and `/Volumes`, in a folder the user can write to. Every other build answers "unavailable" with a reason (`dev_build`, `not_signed`, `wrong_team`, `not_installed`, `not_writable`). Before the swap it unpacks the archive and requires seal, `spctl` notarized, the pinned team and the announced version. Each refusal has a unit test in `updater::tests`. It uses `spctl`, not `stapler`: `stapler` ships with Xcode's tools, which the owner's Mac need not have, and `spctl` answers from the ticket offline (`0060` §5, *Proven (row updater)*).

### Traps that cost time

| Trap | What happened and the fix | Where |
|-|-|-|
| The dmg step hangs | Without `CI=true` the bundler's `bundle_dmg.sh` drives Finder over AppleScript and times out (-1712) in a session with no Finder rights. `CI=true` skips it and costs the positioned icons. Moot for `make mac-release` (the dmg is ours), needed for `make app-release` | `tauri.md` "Release" |
| A `._*` file breaks the seal | `tar` of a macOS tree writes AppleDouble entries that unpack into the bundle. `COPYFILE_DISABLE=1` | `mac-release.sh` `make_update_archive` |
| Dev build updates itself, or a release does not | The updater is gated on identifier plus Developer ID plus team. `make update-proof` builds two real signed releases under a config overlay (loopback `http://` feed, `dangerousInsecureTransportProtocol`; no dmg, never published) | `0060` §5, `tauri.md` "Update archive and the updater" |
| Updater cannot replace a translocated bundle | The plugin derives its target from the running executable. The shell refuses a bundle under `AppTranslocation` or a mounted image as `not_installed` and the About row says to move the app to Applications. Measured from a mounted read-only image: updater off, no feed reached. A Gatekeeper-translocated launch of a quarantined copy was never run | `0060` *Proven (row updater)* |
| The in-app update needs write access to `/Applications` | The owner works as a standard user and elevates on demand. The first update attempt failed with "couldn't write"; as an administrator it worked. The plugin would ask for an administrator password, and an open plugin issue reports the window freezing behind that prompt (`0060` §5), so the shell offers no install without write access (`not_writable`). Plan row `update-without-admin` | `0060` *On the owner's MacBook* |
| A terminal `mv` out of `/Applications` is refused | macOS App Management blocks it unless the terminal is allowed. Tell the owner to move and rename the old build in Finder | `docs/owner-install.md` step 2 |
| First launch on the owner's Mac asks for the keychain | Ad hoc to Developer ID under the same identifier: one prompt for one of three items on the first launch, none on the second, none during the update. Keychain items belong to the signature, so going back to an ad-hoc build prompts again once per item | `0060` *On the owner's MacBook*, `docs/owner-install.md` "Going back" |
| `requireSignedVersion` works with a version stamped by `--config` | N accepted N+1 under `requireSignedVersion: true`; the signature's trusted comment carries `version:<n>`. `signer sign --app-version` needs `tauri-cli` 2.12 or newer (pinned 2.12.4); `tauri-plugin-updater` is 2.14.1 | `0060` *Proven (row updater)*, `tauri.md`, `Makefile` |

### Not proven, do not build on it

- That the plugin's `SignedVersionMismatch` refuses a lying manifest (`0060` *Unproven*).
- A Gatekeeper-translocated launch of a quarantined copy (`0060` *Unproven*).
- Whether the two storage secrets prompt for the keychain at the first sync (`0060` *On the owner's MacBook*).
- Windows and Linux: unsigned bundles build, the AppImage starts under Xvfb, the installer was never started (`0060` §6, the spike of 2026-11-15).

## Packaging a Mac app for Homebrew: formula or cask

| | Formula (ntfy-mac today) | Cask (planned) |
|-|-|-|
| Works with | an ad-hoc or a Developer ID build (proven) | per the research: a notarized build only, because brew quarantines cask downloads and Gatekeeper must accept the app |
| App lives | under `opt_prefix`; the CLI is a symlink | in `/Applications` or `~/Applications`, `binary` stanza for the CLI |
| Updates | brew owns them: the app turns Sparkle off for a Cellar or `opt` copy (`InstallChannel`) | `auto_updates true`; `brew upgrade` skips a self-updating cask whose app is the same or newer |
| Trap | brew strips a lone top-level `.app` from a tarball: ship a sibling file next to it (ntfy-mac `LICENSE`) | a formula-to-cask migration needs a tested plan from a real formula install |

Proven (Wave 1 spike): a formula with `opt_prefix` works, and the notification permission survived `brew upgrade` to a new cdhash and a new Cellar path. The cask rows come from the Wave 7 research, not from a run: verify with `/research` before building one.

## Notifications: permission and the time-sensitive entitlement

- **The permission followed the bundle id, not the path or the signature.** On ntfy-mac it survived a new cdhash, a Cellar path change, a cask-style overwrite, and the move from an ad-hoc to a Developer ID build with the bundle id unchanged (`docs/waves/PLAN.md` Wave 1 spike c, Wave 7 checklist 2026-11-13). Changing a shipped bundle id asks every user again, so keep it.
- **Never quit the app while the authorization prompt is pending.** The authorization state went to denied and stayed there; only a fresh bundle id recovered it (Wave 1 spike a).
- **Time-sensitive notifications need more than the entitlement key.**
  - Required: a portal capability the API key cannot set, and a Developer ID provisioning profile embedded in the bundle.
  - ntfy-mac skipped it (owner decision). The app reads its own entitlements at runtime and downgrades `timeSensitive` to `active` when the key is absent, so adding it later is a signing change only.
  - Unproven on a run: that the portal offers the capability for macOS, and that a signed app claiming the entitlement without a profile is killed at launch. When `sign.sh` embeds a profile, test that the app still launches.

## Sparkle has no Team ID pin

Sparkle 2 accepts an update with a valid EdDSA signature or the same code identity: it never compares the Team ID. ntfy-mac pins the team in two places (`AGENTS.md`, the updating row of the Layout table), and a new Mac app copies both:

1. **The release gate:** `scripts/verify-signature.sh` holds every piece of the build to the expected `TeamIdentifier` and a Developer ID Authority before `package.sh` and the appcast run.
2. **The app:** it records the Team ID of its first Developer-ID-signed run (`Sources/NtfyCore/TeamPin.swift`, a `team-pin` file in the app support directory) and turns the updater off when a later build carries another team. A build that is not Developer ID signed, or a Homebrew copy, never self-updates.

A curl installer cannot pin the team, because the id stays out of tracked files. It checks Developer ID, Hardened Runtime, the staple and Gatekeeper, so any notarized Developer ID app passes. Closing that gap needs the id as a build-time constant, an owner decision.

## Proving an entitlement on the phone

```bash
codesign -d --entitlements :- <Iris.app or .appex> | plutil -convert json -o - -     # the group, aps-environment, keychain groups
```

then an app event that reads `containerURL(forSecurityApplicationGroupIdentifier:)` (Iris: `widget.container`, `available=true`) and one that shows a real write (`widget.snapshot saved=true`).

## Where the details live

Per-repo recipes stay in the repo (Iris: `AGENTS.md` "Device" and "Mac releases", skills `device`, `apple-dev`, `scripts/mac-release.sh` as the reference implementation, `docs/research/2026-11-04-apple-paid-team.md` for the design; ntfy-mac: `AGENTS.md` "Release process", `scripts/sign.sh`, `scripts/verify-signature.sh`, `scripts/apple-credentials.sh`, `scripts/appcast.sh`, `.github/workflows/release.yml`, `docs/waves/PLAN.md` Waves 1 and 7; shutterflow: `scripts/mac-release.sh`, `scripts/verify-signature.sh`, `scripts/publish-release.sh`, `docs/decisions/0060-distribution-and-updates.md`, `docs/owner-install.md`). This file is what holds for every app, so a new Mac app follows it without reading Iris. The global skill `apple-signing` points here.
