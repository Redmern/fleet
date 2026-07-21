# Incorporating `pass` into Fleet — Research Report

**Date:** 2026-06-24
**Scope:** Research only. No code written, no fleet changes made. Section 6 is a *proposal*, not an implementation.
**Sources:** fleet codebase read in place at `/home/red/proj/pc-tune/fleet/main` (cited `file:line`); external docs cited by URL.

---

## 1. Executive verdict

### Goal A — agent-mediated secret injection without the secret entering the AI context

**Verdict: BEST-EFFORT context hygiene, NOT a hard boundary.** You can reliably keep a secret out of the *transcript / context window* for a cooperating agent: a `fleet secret inject <name> <dest>` wrapper that runs `pass show k > dest` makes the plaintext flow through a pipe into the destination file while the agent's stdout sees only the command and its exit code. That genuinely prevents *accidental* leakage into context and is worth building. But it is **not an enforceable confidentiality boundary against a determined or merely curious agent.** The AI process runs as your UID, as a child of your shell, with reach to the same unlocked `gpg-agent` socket. To gpg-agent, the AI *is you*: it can re-run `pass show` itself, `cat` the file it just wrote, dump its own environment, or talk to `S.gpg-agent` directly — all with no passphrase prompt while the cache is warm. fleet-guard (a PreToolUse hook) can pattern-block the *obvious* tool calls (`pass show`, `cat .env`, env dumps) and that is useful as an accident-guard, but it filters an agent-controlled command string and cannot trace subprocesses or revoke the UID's right to the socket. A true hard boundary requires moving secret-handling authority outside the AI's UID/namespace (separate user, broker daemon, or a sandbox that omits `~/.password-store` + the agent socket) — at real `sudo`/operational cost. **Conclusion: build it for context hygiene, document it honestly as such, do not market it as "the AI cannot read the secret."**

### Goal B — per-branch / per-worktree secret overlay

**Verdict: WORKS, cleanly, and is the stronger of the two ideas.** Materialising a branch's secret files into a new worktree at `fleet new` time is a purely mechanical decrypt-on-create step with no enforcement claim attached, so none of Goal A's hard-truth problems apply. The store layout maps naturally onto pass subfolders keyed by `repo/branch` with base-branch fallback; a single master key unlocks delivery; fleet already has the exact primitives needed to keep materialised files out of git (the `info/exclude` mechanism at `bin/fleet:824-834`) and out of the reap dirty-check (`bin/fleet:2491-2496` already ignores `.fleet/`). The clean insertion point is right after `git worktree add` (`bin/fleet:815`). The only real design work is keying/fallback semantics, the no-commit guarantee, and shredding on reap. **Recommended even if Goal A is descoped to "context hygiene only."**

### Recommended tool

**`sops + age` beats `pass` for this specific use case**, though `pass` is viable and may win if you already live in pass. age replaces GPG's keyring/agent/trust-db machinery with a single `AGE-SECRET-KEY-1…` file; sops adds structured per-*value* encryption so a `.env.sops` committed *into the repo* shows variable names but not values and stays diffable; and `sops exec-env` runs a command with secrets in its env with **nothing on disk**. Pair it with **direnv** as the per-worktree loading layer. **Crucially, none of these tools changes the Goal A verdict** — the UID/gpg-agent (or age-key-on-disk) problem is identical for all of them. Tool choice is about ergonomics and the Goal B overlay, not about making secrets unreadable to the agent.

---

## 2. `pass` primer

`pass` ("the standard unix password manager", [passwordstore.org](https://www.passwordstore.org/)) is a thin shell wrapper over `gpg2` + optional `git`.

**Storage model.** Each secret is one GPG-encrypted file under `~/.password-store`, the file path being the secret's name (e.g. `~/.password-store/Email/work.gpg`). Directory structure and names are **plaintext**; only file *contents* are encrypted. Decryption needs the OpenPGP private key, itself protected by your passphrase. ([pass(1)](https://man.archlinux.org/man/pass.1))

**`.gpg-id` and recipients.** `pass init <gpg-id…>` records the recipient key(s) in a plaintext `.gpg-id` at the store root, one id per line. Any subfolder may carry its *own* `.gpg-id`; the deepest one on a file's path governs it, so different subtrees can encrypt to different recipients. `pass init <id1> <id2>` makes a **multi-recipient** store where either private key can decrypt — this is how shared stores work. Changing `.gpg-id` re-encrypts the affected files. ([pass(1)](https://man.archlinux.org/man/pass.1))

**Commands** (all [pass(1)](https://man.archlinux.org/man/pass.1)):
- **`pass show <key>`** — decrypts and prints the file's **entire plaintext** to stdout, no redaction. By convention **line 1 is the password**, later lines are free-form metadata.
- **`pass show -c[n] <key>`** — prints nothing to stdout; copies line *n* (default 1) to the clipboard and auto-restores after ~45 s. Closest built-in to "use without showing."
- **`pass insert [-m] [-f] <key>`** — reads a new secret from stdin (echo off, asks twice; `-m` multiline; `-f` overwrite).
- **`pass edit <key>`** — decrypts into `$EDITOR` via `/dev/shm` when available, re-encrypts on save.
- **`pass generate [-n] [-c] <key> [len]`** — random from `/dev/urandom`.
- **`pass ls`** — tree of *names* only. **`pass grep <s>`** — decrypts **every file** and greps plaintext. **`pass rm/mv/cp`** — manage/re-encrypt.
- **`pass git <args>`** — the store can be a git repo; pass auto-commits every mutation, so it's a versioned, optionally pushable history of ciphertext.

**Extensions.** **pass-otp** ([tadfisher/pass-otp](https://github.com/tadfisher/pass-otp)) stores `otpauth://` URIs and computes TOTP via `pass otp [-c] <key>`. **pass-tomb** keeps the whole store inside an encrypted LUKS Tomb so the directory of `.gpg` files is itself encrypted at rest.

**Decryption gating — the key fact for Goal A.** `pass show` calls `gpg -d`, which asks **gpg-agent**. gpg-agent caches the unlocked key and prompts via pinentry only when needed:
- `--default-cache-ttl` defaults to **600 s**, and **every access resets the timer** (sliding window). ([GnuPG Agent Options](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html))
- `--max-cache-ttl` defaults to **7200 s** (hard ceiling). ([ibid.](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html))
- While cached, subsequent decrypts succeed **silently, no prompt**. The agent listens on a UID-owned socket `/run/user/$UID/gnupg/S.gpg-agent` (mode 0600, under a 0700 dir). Its *entire* access control is "can you write to this socket?" — true for **any process at your UID**. ([ArchWiki GnuPG](https://wiki.archlinux.org/title/GnuPG), [gnupg-devel](https://lists.gnupg.org/pipermail/gnupg-devel/2016-October/031771.html))

---

## 3. Goal A — deep analysis, threat model, enforceability

### 3.1 The mechanism (what the agent sees vs. doesn't)

A wrapper `fleet secret inject DB_PASSWORD .env` implemented as roughly `pass show DB_PASSWORD > "$dest"`:

- **The agent's tool result contains:** the command string it submitted, exit code, and any non-secret stderr. **Not** the secret value — the plaintext went down the redirect into `$dest`, never to the stdout the harness captures.
- This is real and useful: it keeps the secret **out of the transcript / context window** for the normal, cooperating flow. The agent can wire `DB_PASSWORD` into a `.env`, a config file, or `curl -H "Authorization: Bearer $(...)"` **without the value ever being printed to it.**

So "the AI does not *need* to read the secret" is fully achievable. The hard question is whether it's "the AI *cannot* read the secret."

### 3.2 Threat model — who holds the key, and can the AI bypass

**Setup:** Claude Code runs as a child of your interactive shell — same UID, same view of `$GNUPGHOME` and `/run/user/$UID/gnupg/`, gpg-agent already unlocked by you.

**Can the agent decrypt directly with no prompt? Yes.** With the key cached and the AI at your UID with socket reach, the AI running `pass show k` is **indistinguishable to gpg-agent** from your shell doing it. No pinentry fires. There is no GPG mechanism that lets the shell decrypt but denies the shell's own child — **UID is the granularity.**

**Exfil paths a determined/curious agent has** (the redirect hides bytes on *one* invocation; it changes nothing about authority):
1. **Re-run the source** — `pass show k` without the redirect, plaintext straight to context.
2. **`cat .env`** — the file it just wrote is its own UID's.
3. **Read any file/temp/FIFO** it routed the secret through.
4. **`/proc/self/environ`, `/proc/<pid>/environ`** — anything injected as an env var into the agent or a child it owns.
5. **`printenv` / language `os.environ`** — env-injected secrets are *already in context the moment they're set*.
6. **Clipboard scrape** — `wl-paste`/`xclip -o` within the `pass -c` 45 s window.
7. **`gpg-connect-agent` / library binding** straight to `S.gpg-agent`, bypassing the `pass` wrapper.
8. **Copy ciphertext + decrypt at leisure** while the cache is warm.
9. **`pass git log -p`** — recover any secret that ever lived in store history.

### 3.3 What fleet-guard can and cannot do

fleet-guard (`bin/fleet-guard`) is a PreToolUse hook: POSIX-sh wrapper + embedded Python, fail-silent (any parse error → exit 0/allow, `bin/fleet-guard:15-23`). It has two arms:
- **Always-on worker merge/push block** (`bin/fleet-guard:43-113`): quote-aware tokenizes Bash commands, denies `git merge`/`git push` for workers; falls *closed* on parse error (`bin/fleet-guard:88-104`).
- **Opt-in protected-path edits** (`bin/fleet-guard:116-189`, active only when `FLEET_GUARD_ON=1`): inspects Edit/Write/MultiEdit/NotebookEdit `file_path` against built-in globs (`:127-134`) plus per-repo `<cwd>/.fleet/protected` and global `$CFG/protected` (`:137-153`). Leading `!` = hard-deny and wins over soft-ask (`:156-189`).

**What it buys for secrets:** it sees the full tool input before execution, so you *can* add deny rules for `Bash` commands matching `pass show`, `gpg -d`, `gpg-connect-agent`, `cat`/`grep` of the secret file, `printenv`, `/proc/*/environ` reads, and Edit/Write targeting the secret file. This meaningfully raises the bar against **accidents** and casual reads.

**What it fundamentally cannot do:**
- It intercepts the **agent's own tool calls**, not arbitrary subprocesses. A permitted command can spawn children, write a wrapper script, obfuscate the call (`p\ass`, `bash -c "$(printf …)"`, a Python `subprocess`), or use a library binding — none re-examined by the hook.
- It is a **deny-by-pattern over an agent-controlled string** — a losing game for *prevention*, fine for *guardrails*.
- It cannot revoke the AI process's **UID-level right** to open `S.gpg-agent`. It governs the harness's tools, not the kernel's answer to a same-UID `connect()`.

### 3.4 What *would* make it hard (and the cost)

The boundary must be a **UID or namespace boundary**, not policy inside one UID:

| Mechanism | Why it's hard | Cost |
|---|---|---|
| **Separate UID** (secret-consuming process as another user) | `/run/user/$UID/gnupg` is 0700 owner-only; the AI's UID can't open the socket | needs `sudo`/polkit to cross; AI must lack passwordless sudo to it; real dev-loop friction |
| **Broker daemon** (AI asks "deploy with secret X"; broker at another UID decrypts + injects, returns results not secrets) | decryption oracle behind an API that returns *capabilities*, not credentials | must build/operate the broker; ensure no method leaks plaintext back — the genuinely robust pattern |
| **Separate gpg-agent / distinct `$GNUPGHOME` under another UID** | AI's UID has no path to a cached key | same UID-separation requirement or AI just repoints `GNUPGHOME` |
| **Namespaces/container** (AI in a mount/PID/user ns without `~/.password-store` + agent socket) | socket + ciphertext absent from AI's view | a half-built sandbox bind-mounting `$HOME` leaks everything; disrupts normal file access |
| **seccomp** | blocks syscalls | wrong granularity — can't say "this socket yes, that no"; not the tool |

### 3.5 Enforceability conclusion (brutally honest)

**On a single-UID laptop with gpg-agent unlocked, keeping a secret out of the AI's reach is BEST-EFFORT, not a hard boundary.** The reason is structural: GPG's decryption authority is gated by **UID + socket access**, and the AI runs at **your UID with your socket** — to gpg-agent it *is* you, and the cache means decrypts happen **silently** with no human-in-the-loop checkpoint. Every in-process trick (redirect to file, `pass -c`, "don't echo it", a PreToolUse blocklist) reduces to filtering a string or relocating bytes *within the same authority domain*; a capable agent has many equivalent paths (§3.2), and the hook can't trace subprocesses (§3.3).

**This is identical for sops/age/git-crypt/gopass** — substitute "age key file readable by your UID" or "git-crypt symmetric key" for "gpg-agent socket" and the analysis is unchanged.

**Therefore:** build `fleet secret inject` for **context hygiene** (keep secrets out of the transcript, prevent accidental exposure, give a cooperating agent a way to wire secrets it never needs to see). Document it as exactly that. Do **not** claim it stops a determined or cooperating agent. If you genuinely need a hard boundary, the agent must run under a different UID/namespace than the one holding the keys, or behind a broker — a separate, larger project.

---

## 4. Goal B — per-branch / per-worktree secret overlay design

This is mechanical materialisation; no enforcement claim, so §3's hard-truth does not bite. Fleet already has every primitive needed.

### 4.1 Where it hooks in

`fleet new` creates the worktree via `git worktree add` at `bin/fleet:791-793` (existing branch) / `:814-815` (new branch). The **clean insertion point is immediately after `:815`, before the docs/env seeding at `:820-823`** — confirmed by the Explore agent as the natural and currently-empty post-create slot. Today there is **no secrets/.env/gpg/pass logic anywhere** in the codebase (grep clean), so this is greenfield.

### 4.2 Keying and fallback

Map store layout to `repo/branch`:
```
secrets/<repo>/<branch>/<file>      e.g. secrets/api/feat-login/.env
secrets/<repo>/_base/<file>         base-branch / shared default
```
At materialise time, for each target file: prefer `secrets/<repo>/<branch>/<file>`, else fall back to `secrets/<repo>/_base/<file>` (mirrors `cmd_new`'s own base-resolution logic at `bin/fleet:794-815`). With pass this is subfolders; with sops+age it's path-keyed files under `.sops.yaml` `creation_rules`.

**Worktree reuse:** `cmd_new` already removes an inherited `.fleet/ready` on reuse (`bin/fleet:845`). Materialisation should be **idempotent**: overwrite (or skip-if-present with a `--force-secrets` to refresh). Treat re-materialise as cheap and deterministic.

### 4.3 Guaranteeing no-commit

Two existing mechanisms make this clean:
- **Git invisibility:** `cmd_new` appends `/.fleet/` to the shared `info/exclude` (`bin/fleet:824-834`) rather than a tracked `.gitignore` — never committed, applies to all worktrees off the anchor. The materialiser should **append the materialised secret paths to the same `info/exclude`** (e.g. `/.env`, `/test/creds.json`), reusing the idempotent `grep -qxF || printf >>` pattern at `:833`.
- **Reap dirty-check already ignores `.fleet/`:** `cmd_reap` computes `dirty=$(git status --porcelain | grep -vE '^...\.fleet/')` (`bin/fleet:2491-2496`). Materialised files outside `.fleet/` *would* show as dirty and **block reap** unless excluded — so either (a) put materialised files under `.fleet/secrets/<file>` and symlink, or (b) extend the dirty-check's `grep -vE` to also drop the known secret paths. Option (a) is cleaner: it inherits the existing ignore + archive behaviour for free.

### 4.4 Shred on reap

`cmd_reap` already archives `.fleet/notes` and removes the worktree (`bin/fleet:2533-2570`). Add a step before `git worktree remove` (`:2551`) to **shred** materialised secret files (`shred -u` / overwrite-then-unlink), since plaintext secrets must not survive in the archive. If secrets live under `.fleet/`, ensure they are shredded and **excluded from the notes archive** at `:2541-2546` (don't `mv` plaintext secrets into `notes/archive/`).

### 4.5 Single key unlocks delivery

One GPG (pass) or age (sops) master key, unlocked once (gpg-agent cached, or age key file present), decrypts all branches' overlays at worktree-creation time. No per-branch key management. This is exactly the single-master-key ergonomic both tools provide.

---

## 5. Alternatives comparison + ranking

Use case: local dev, per-branch worktree overlay, agent-mediated, single-user laptop, fail-silent, no-daemon.

| Tool | Encryption | Key mgmt | Offline / no-daemon | Git-committable ciphertext | Partial-file enc. | Per-branch fit | Worktree-materialise fit | AI-context isolation | Laptop ergonomics |
|---|---|---|---|---|---|---|---|---|---|
| **pass** | GPG (AES+asym) | 1 GPG key + agent | ✅ | ✅ (store external) | ❌ per-secret | ⚠️ namespace+script | ⚠️ `pass show > .env` | ✅ strong (external store) | ⚠️ GPG/agent friction |
| **sops+age** | age ChaCha20/X25519, values-only | 1 age key, no GPG/agent | ✅ | ✅✅ cipher *in repo*, diffable | ✅✅ per-value | ✅ `.sops.yaml` rules | ✅✅ `sops -d > .env` / `exec-env` | ✅✅ strongest | ✅✅ excellent |
| **git-crypt** | AES-256-CTR (det.) | symm. key or GPG | ✅ | ✅ tracked files only | ❌ whole-file | ❌ not branch-aware | ❌ whole-tree unlock, ignores overlays | ❌ plaintext after unlock | ⚠️ filter gotchas |
| **agenix** | age via SSH keys | SSH/age, no GPG | ✅ | ✅ `.age` | ❌ per-file | ⚠️ off-Nix only `age -d` | ⚠️ module targets /run only | ✅ if target ignored | ❌ Nix-coupled |
| **gopass** | GPG *or* age | 1 GPG/age key | ✅ (no remote) | ✅ store *is* git repo | ❌ per-file | ⚠️ namespace+hook | ✅ `gopass env` / hook | ✅ via env/stdin/file (mind /proc) | ✅ richer than pass |
| **direnv** | none (loader) | delegates | ✅ | n/a | n/a | ✅✅ per-dir=per-worktree | ✅✅ `use sops`, `dotenv_if_exists` | ⚠️ leaks env to children incl. agent | ✅✅ glue |
| **1Password op** | account E2E | 1P account + biometric | ❌ online + app daemon | ❌ refs in git, store=account | n/a | ⚠️ items | ⚠️ `op inject`/`run` (online) | ✅✅ `op://` pointer pattern | ❌ account-bound |
| **Vault** | barrier (Shamir) | tokens, seal/unseal | ❌ mandatory daemon | ❌ separate backend | ❌ | ⚠️ paths | ❌ needs live unsealed server | ⚠️ runtime inject | ❌ overkill |
| **Doppler** | AES-256-GCM fallback | account + token | ⚠️ no daemon, online-seed | ⚠️ cache, not source | ❌ | ✅ configs≈envs | ⚠️ `doppler run`, online-seed | ⚠️ real env values | ⚠️ SaaS |
| **Infisical** | server-side | account/machine id | ❌ cloud or self-host daemon | ❌ store=cloud/DB | ❌ | ✅ `--env` | ⚠️ `infisical run`, online | ⚠️ real env values | ❌ overkill |

### Ranking

1. **sops + age — winner.** One age key (a single `AGE-SECRET-KEY-1…` file, **no keyring/trust-db/agent**), fully offline/no-daemon, commits **ciphertext into the repo tree** as a diffable structured file, **per-value** encryption (names readable, values not), and two clean worktree patterns: `sops -d .env.sops > .env` on create (git-ignored) or `sops exec-env .env.sops 'cmd'` (no disk plaintext). ([getsops/sops](https://github.com/getsops/sops), [FiloSottile/age](https://github.com/FiloSottile/age))
2. **direnv — essential loading layer, not a competitor.** Not encryption; the per-worktree glue. `use sops` decrypts to env on `cd` with no disk plaintext; `dotenv_if_exists`/`source_up_if_exists` give exactly the **fail-silent optional overlay + base/override layering** the use case wants; `watch_file` handles rotation. Caveat: alone it leaks env to children incl. the agent. ([direnv.net](https://direnv.net/), [Sops wiki](https://github.com/direnv/direnv/wiki/Sops))
3. **gopass (age backend) — strong runner-up** if you prefer a *central* store over cipher-in-tree: single age key, offline, git-versioned store, excellent `gopass env <prefix> -- cmd` injection. Behind sops on no per-value enc. and store-not-in-repo; mind `/proc/<pid>/environ` exposure. ([gopass.pw](https://www.gopass.pw/))
4. **pass — GPG baseline, beaten on ergonomics.** Fully functional and offline, but every edge of #1–#3 is "avoid GPG keyring + agent + trust-db pain." No structured enc., no built-in run-with-env, store external. **Still a fine choice if you already use pass daily.**
5. **agenix — skip unless on NixOS** (off-Nix it's a thin `age -d`).
6. **git-crypt — wrong shape** (whole-tree unlock to plaintext, only tracked files, no decrypt-to-stdout).
7. **Doppler — best SaaS, still disqualified** (account-bound, online-to-seed; its encrypted-fallback-file model is the right *shape* though).
8. **1Password op — borrow the idea (`op://` opaque references), not the tool** (offline/no-daemon violated).
9. **Infisical / 10. Vault — overkill, daemon-bound.**

### Where the winners beat pass
- **age vs GPG:** one key file, no keyring/agent/trust-db.
- **sops partial encryption:** encrypt `.env` *values*, keep keys readable + diffable — pass can only blob a whole secret.
- **`sops exec-env` / `gopass env`:** built-in run-with-env, secrets never hit disk — pass has no such primitive.
- **direnv loading layer:** per-dir=per-worktree, fail-silent, base/override layering, `watch_file` rotation — the materialisation half pass leaves to you.

**Recommended stack:** **sops + age** as the encrypted, git-committed store, materialised per-worktree (either a `git worktree add` hook doing `sops -d > .env` git-ignored, or `sops exec-env` for no-disk), optionally with an `op://`-style opaque-pointer convention so any file an agent reads holds only references. If you'd rather not introduce a new tool and already run pass, pass works for both goals with more glue.

---

## 6. Implementation proposal (NOT built — design only)

Marked clearly as a **PROPOSAL**. All `file:line` are touch-points in the current tree.

### 6.1 The `fleet secret` subcommand family

A new `cmd_secret` dispatched from the top-level case in `bin/fleet` (alongside `cmd_new`/`cmd_reap`):
- **`fleet secret inject <name> <dest>`** — `pass show <repo>/<branch>/<name> > <dest>` (or sops `-d`). Plaintext never to stdout. Appends `<dest>` to `info/exclude`. **Context-hygiene tool; documented as best-effort, not a boundary (per §3.5).**
- **`fleet secret set <name>`** — `pass insert`/`pass edit` wrapper, scoped to current repo/branch.
- **`fleet secret ls`** — `pass ls <repo>` (names only).
- **`fleet secret materialise [<branch>]`** — re-run the overlay step for the current/given worktree (the worktree-reuse refresh path).

### 6.2 cmd_new worktree-overlay hook

Insert after `bin/fleet:815` (`git worktree add`), before docs seeding at `:820`:
1. Resolve overlay set for `<repo>/<branch>` with `_base` fallback (mirror base-resolution at `:794-815`).
2. For each overlay file: decrypt to `$dir/.fleet/secrets/<file>` (under `.fleet/` to inherit the existing ignore + dirty-check exemption), symlink into the worktree at the intended path, or write directly and append the path to `info/exclude` (reuse `:833` pattern).
3. Make idempotent (overwrite or skip-if-present).

### 6.3 fleet-guard rules

Extend `bin/fleet-guard`:
- Add a **secret-read guard** arm (opt-in, like the protected-path arm at `:116`): deny `Bash` commands matching `pass show`, `gpg -d`, `gpg-connect-agent`, `cat`/`grep`/`printenv` of materialised secret paths, `/proc/*/environ` reads — reusing the quote-aware tokenizer at `:88-104`.
- Add materialised secret globs to the protected-path deny list (`!`-prefixed hard-deny) so Edit/Write can't target them.
- **Document in-code that this is accident-prevention, not enforcement (§3.3).**

### 6.4 gpg-id / store setup

- `fleet secret init` → `pass init <gpg-id>` (or `age-keygen` + `.sops.yaml`) and create `secrets/<repo>/_base/`.
- Document short `default-cache-ttl` guidance and `gpgconf --reload gpg-agent` to flush cache when an agent is active.

### 6.5 inject-without-reveal wrapper

The core of `fleet secret inject`: `pass show "$key" > "$dest"` with stderr suppressed of any secret, exit code propagated. The agent sees command + exit code only. **(Reminder: §3.5 — context hygiene, not a boundary.)**

### 6.6 reap shredding

In `cmd_reap` before `git worktree remove` (`bin/fleet:2551`): `shred -u` materialised secret files; ensure they are **excluded from the notes archive** at `:2541-2546`.

---

## 7. Risks, open questions, what to prototype first

**Risks**
- **Overclaiming Goal A.** The single biggest risk is documenting/marketing `fleet secret inject` as "the AI can't read the secret." It can (§3). Frame honestly or it becomes a false sense of security.
- **Plaintext on disk.** Materialised `.env` files are plaintext at rest in the worktree for the worktree's life. `sops exec-env` (no disk) avoids this where the consumer is a subprocess; file overlays cannot.
- **Reap archive leakage.** If materialised secrets land under `.fleet/notes` they'd be `mv`'d into `notes/archive/` (`bin/fleet:2541-2546`) — plaintext secrets surviving reap. Must exclude + shred.
- **gpg-agent cache window.** Anything decrypted stays decryptable silently for up to 7200 s — covers the whole agent session.

**Open questions**
- pass vs sops+age: is avoiding a new tool worth keeping GPG friction? (Recommend sops+age unless already pass-native.)
- Symlink-into-worktree vs write-and-exclude: which is cleaner against the dirty-check?
- Do you want any overlays *committed* as ciphertext (sops-in-repo) vs an entirely external store (pass)?
- Should fleet-guard's secret guard be on-by-default or opt-in like the protected-path arm?

**Prototype first (smallest honest slice)**
1. **Goal B materialiser, pass or sops, behind `fleet secret materialise`** — purely mechanical, no enforcement claim, exercises the `info/exclude` + reap-shred plumbing. Lowest risk, highest value.
2. Then `fleet secret inject` as a **context-hygiene** wrapper with explicit honest docs.
3. Only then, if a real boundary is needed, scope the separate-UID/broker design as its own project.

---

## Source index

**Fleet codebase** (`/home/red/proj/pc-tune/fleet/main`): `bin/fleet:791-815` (worktree add), `:820-823` (docs seed), `:824-834` (info/exclude), `:845` (ready cleanup), `:2388-2457` (cmd_ready), `:2459-2577` (cmd_reap), `:2491-2496` (dirty-check ignores `.fleet/`), `:2541-2546` (notes archive), `:2551` (worktree remove); `bin/fleet-guard:15-23` (fail-silent), `:43-113` (merge/push block), `:88-104` (tokenizer), `:116-189` (protected-path arm); `FLEET.md:31-36` (`$FLEET_DOCS`). No existing secret/env/gpg/pass logic (grep clean).

**External:** [passwordstore.org](https://www.passwordstore.org/), [pass(1)](https://man.archlinux.org/man/pass.1), [GnuPG Agent Options](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html), [ArchWiki GnuPG](https://wiki.archlinux.org/title/GnuPG), [gnupg-devel socket perms](https://lists.gnupg.org/pipermail/gnupg-devel/2016-October/031771.html), [pass-otp](https://github.com/tadfisher/pass-otp), [Claude Code Hooks](https://code.claude.com/docs/en/hooks), [getsops/sops](https://github.com/getsops/sops), [age](https://github.com/FiloSottile/age), [git-crypt](https://github.com/AGWA/git-crypt), [agenix](https://github.com/ryantm/agenix), [gopass](https://www.gopass.pw/), [direnv](https://direnv.net/) + [Sops wiki](https://github.com/direnv/direnv/wiki/Sops), [1Password CLI](https://developer.1password.com/docs/cli/), [Vault](https://developer.hashicorp.com/vault/docs), [Doppler CLI](https://docs.doppler.com/docs/cli), [Infisical CLI](https://infisical.com/docs/cli/overview).
