# scripts

## Secrets

The shim, the accounts and the edit guardrail for `secrets-run` are in the root `AGENTS.md` §Secrets. The backend differs per machine (`~/.config/secrets/backend`, injected each session by `hooks/machine-role.ts`; trust it over guessing):

- **`op` (MacBook)** — passthrough to live `op`, biometric, native redaction.
- **`cache` (mini)** — resolves each ref from one SOPS+age cache decrypted in
  memory, injecting only the template's declared keys. No plaintext on disk, no
  network, fails closed on a missing ref. **A direct `op read` on the mini HANGS**
  on a biometric prompt no one can answer.

`make secrets-seed` reads `dotfiles-private/headless.refs` (+ `headless.iu.refs`),
resolves every ref through 1Password in one biometric pass, and reseals.
`secrets-run` warns after 14 days; the heartbeat pushes DOWN at 8.

- **Tiering guardrail:** only T0/T1 refs are cached — `op://Private/*` and T2/prod
  are refused by the seed (argo's `op://vps/argo/*` is an owner-classified
  exception). Work refs *are* cached: the gate is tkrumm's `Private` vault, not
  work-vs-personal.
- **A new ref is an incremental reseal, not a full one.** `make secrets-seed-new`
  (`secrets-seed.sh --new-only`) reads only the refs the sealed cache lacks and keeps
  every other value (the current cache is decrypted in memory — on the mini, over
  ssh when sealing from the MacBook): one new ref = one `op` read. It keeps the old
  `_seeded_at` and file mtime, so the 5-day / 8-day / 14-day age gates still measure
  the last COMPLETE reseal; the plain `make secrets-seed` stays the full pass. The
  hourly opbackup reseal runs `--new-only` when only the refs list moved.
- **Agents ask for a reseal through `make secrets-reseal-request` (mini), never by
  hand.** It lists the refs in `headless.refs`/`headless.iu.refs` that the cache has
  no key for (keys are plaintext in SOPS-JSON: no decrypt, no `op`), raises ONE
  request per missing-ref set (key `secrets-reseal-<hash of the set>`, so asking
  again is a no-op and a changed set replaces the old request), names the exact refs
  and the accounts to sign in, and carries a `--check` (`needed`) that closes the
  request once the cache has them. `make secrets-reseal-status` lists the set.
- **One unreachable account does not stop the other.** If an account cannot sign in,
  or none of its vaults exist on the machine sealing (careerpartner on
  the MacBook), the seed seals the reachable account's refs plus the unreachable
  account's existing values, names that account once, and exits **3** (partial; the
  cache IS delivered; opbackup does not stamp the refs as sealed). tkrumm is the
  trust anchor (recipient pin, Private-vault guard) and must be reachable.
  `secrets-rotate` runs `--require-complete`: it never delivers a partial cache.
- **A dead ref blocks a FULL reseal of a reachable account, not an incremental one.**
  `make secrets-seed` fails closed (it could drop a value the cache holds), collecting
  the complete list first. `--new-only` only reads refs the cache lacks, so a dead one
  has nothing to lose: it seals every ref that resolved, names the dead ones and exits
  **3**; the dead ref stays "missing" for `secrets-reseal-request` until the 1Password
  item exists. Fixing it is a refs-file or 1Password edit, never a `secrets-run`
  problem — and no monitor tells you which.
- **`op whoami` is not an unlock probe, it is a permanent lock-out** — under
  desktop-app integration there is no CLI session token, so it returns rc=1 on a
  fully unlocked app while `op read` works in the same second. Use
  `scripts/lib/op-signed-in.sh <acct>` for both accounts, never whoami.
- **1Password authorizes per calling binary** — the first `op` call from a new
  parent (`make`, a LaunchAgent) raises a one-time dialog, so "it works when I run
  it by hand" proves less than it looks like.
- **The second dialog is macOS, not 1Password** — *"op möchte auf Daten aus anderen Apps zugreifen"* is TCC
  `SystemPolicyAppData`: op reads the desktop app's group container. The grant is keyed on the BINARY PATH, which carries
  the version (`…/Caskroom/1password-cli/<ver>/op`), so **every `brew upgrade 1password-cli` drops it**. Held by Full Disk
  Access on that exact path (FDA supersedes AppData; "Allow" does **not** stick), asserted by `make brew-upgrade`. A grant
  earned through a Claude Code chain never sticks (its TCC client is a fresh `claude/versions/<ver>` per auto-update): run
  the seed from a plain terminal. MacBook: `op` under the `Herdr Core.app` FDA (Herdr terminals, `hc run` for
  `ask-human --cmd`) or the opbackup launcher; acceptance `make op-tcc-probe` (`docs/tcc.md` §1Password).
- **`secrets-seed` never fans out on an access failure.** A batch/read that dies on
  authorization, a timeout or the desktop-app handshake aborts the run at once (no
  per-ref fallback, no retry) and prints the resolved `op` path to add to Full Disk
  Access; only a genuine ref error (`isn't an item`…) falls back per-ref to name the
  dead ref. Seeing the TCC dialog = grant FDA on that exact path, then re-run.
- **"mini unreachable" no longer means "1Password is locked"** — `ssh mini` uses the
  dedicated `~/.ssh/id_ed25519_mini`; check Tailscale and that key's presence.
- **The login Keychain is not a headless credential store and it fails quietly** —
  `security find-generic-password` returns non-zero when the keychain is locked,
  which is what a launchd job gets with no GUI session. Callers fall back to
  `secrets-run read` on the same refs, and say so on stderr.
- `make secrets-rotate` **refuses on a detached mini rather than hanging** —
  rotation is biometric end to end and needs a human *at* the mini.

The data half (`headless.refs`, the encrypted cache, `.sops.yaml`, the ACL and serve declarations) lives in `~/SourceRoot/dotfiles-private`; full model in its `docs/{design,runbook,security-review}.md`. Operations: `/secrets`.

## Deploy gate pins

**IuRoot deploy-gate pins.** The gate (`epos-tool-athena/deploy-gate`) pins by sha256 `scripts/ask-human.sh`, `scripts/human-queue.sh`,
`scripts/lib/human-queue-json.sh` and `scripts/human-queue-notify-hook.sh` (the live list is `ask_human_pins` in
`~/.local/libexec/prometheus-deploy-gate/config.json`). **Changing any of them needs the owner's re-pin** (`make deploy-gate-install`
in his epos-tool-athena clone, owner-only): until then the gate's release dialog is silently off and `make verify` is red in every
gated repo. After `make deploy`, `scripts/gate-pin-notice.sh` compares them with the pins and enqueues one human-queue item
(key `gate-pin`, diff range + the re-pin command; a newer change replaces it, a re-pin clears it). It never runs the re-pin. Don't
call such a commit "the owner's" or treat the red verify as unrelated.


## Restarts of script agents

`make setup` also restarts a loaded `hc-events`/`hc-resume` whose script changed after the
process started (`scripts/agent-refresh.sh`, `kickstart -k` + deliberate-restart marker; never
the herdr-core agent). A new KeepAlive script agent calls it from its `*-setup`.
