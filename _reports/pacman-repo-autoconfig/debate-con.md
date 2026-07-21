# ADVISER 2 (CON) — adversarial review of PLAN.md

**Lens:** attack the plan. Every challenge below states the claim, what I ran, the
actual output, and a verdict.

> **Mid-flight redirect applied.** The human has ruled **(B)** on OQ-1: `bootstrap.sh`
> gains a consumer mode. PLAN.md §1.4's recommendation of (A) is overridden and is not
> re-litigated here. My attack is now aimed at **(B)'s design** — see
> **Part I: attacking (B)**, which is the primary surface. The pacman-side empirical
> brief is retained in full as **Part II**.
>
> **Bottom line on (B): workable, but PLAN.md contains none of the integration design
> it needs, and four of the five integration points are actively broken as things
> stand.** B1 and B3 are shipping blockers — in the migration case, (B) as specified
> reproduces the exact §1.4 harm it exists to avoid, and the guard that should catch
> it is structurally incapable of firing. Both are fixable; neither is optional.

**Safety:** every experiment ran on temp fixtures inside a private `mktemp -d`
(`…/scratchpad/pacCYQhVL`). Nothing under `/etc` was written, moved, or chmod'd.

```
/etc/pacman.conf sha256 at start:  b19c50501ef9528fb47623f312978af5a5d0df6e7d25844b01f91b7dc75baa46
/etc/pacman.conf sha256 at end:    b19c50501ef9528fb47623f312978af5a5d0df6e7d25844b01f91b7dc75baa46
UNCHANGED ✓
```

Environment: pacman 7.1.0, libalpm 16.0.1, pacman-conf 1.0.0.

**Overall verdict: the plan is well-researched and gets the *mechanical* file-hygiene
questions right, but its central *security* claim is empirically backwards, and it
recommends a docs change that would delete correct guidance and replace it with a
false one. That single error (S1) must be fixed before anything ships. Four further
defects (S2–S5) are real bugs in the design as written.**

---

## Severity-ranked findings — all parts

| # | Finding | Verdict | Severity |
|---|---|---|---|
| **B1** | Consumer mode on a machine that was ever worktree-mode leaves a shadowing `~/.local/bin/fleet`; `bootstrap.sh` removes nothing | **CONFIRMED** | **BLOCKER** |
| **B3a** | `fleet setup`'s dev-shadow guard is symmetric and **cannot fire** in the case (B) creates — it silently wires the dev install | **CONFIRMED** | **BLOCKER** |
| **B3b** | A stale `~/.config/systemd/user/fleetd.service` masks the packaged unit (search path pos 5 vs 17) and `fleet setup` never replaces it | **CONFIRMED** | **HIGH** |
| **B2** | `fleet doctor` warns permanently on every consumer machine, and reports the *broken* half-migration identically to the healthy state | **CONFIRMED** | **HIGH** |
| **B4** | Mode-switch state matrix: 3 of 6 transitions corrupt; none are detected | **CONFIRMED** | **HIGH** |
| **B5** | §4's "call add-repo.sh from the local checkout" is **dead** under (B) — consumer mode has no checkout by definition | **REFUTED** | **MEDIUM** |
| S1 | "Repo ordering is not a security control" — and the docs change that follows from it | **REFUTED** | **CRITICAL** |
| S2 | §2.6 step 8 verification is false-green (passes on a hijacked conf) | **REFUTED** (as sufficient) | **CRITICAL** |
| S3 | Detection is blind to `[fleet]` arriving via `Include` → produces a conf that breaks *all* pacman | **REFUTED** (§3.11 "irrelevant") | **HIGH** |
| S4 | Verification happens *after* the `mv`, so a bad write goes live | **CONFIRMED** (design flaw) | **HIGH** |
| S5 | §3.8 preflight (`[ -w $CONF_REAL ]`) tests the wrong thing for the chosen write strategy | **REFUTED** | **MEDIUM** |
| S6 | §2.4 specifies the detection regex twice, inconsistently | **CONFIRMED** | **MEDIUM** |
| S7 | §3.4 CRLF handling is unnecessary; its stated rationale is false | **REFUTED** | **MEDIUM** |
| S8 | Proof-harness fixtures with `Include` will hard-fail or couple the test to `/etc` | **CONFIRMED** | **MEDIUM** |
| S9 | OQ-1 recommendation (A) ships a script with zero users | **CONFIRMED** | **MEDIUM** |
| — | §3.3 no-trailing-newline bug | **CONFIRMED**, and *understated* | (plan is right) |
| — | §2.1 EOF is always last; Include is inline expansion | **CONFIRMED** | (plan is right) |
| — | §3.10 `readlink -f` + write-target + `chmod --reference` | **CONFIRMED** | (plan is right) |
| — | §6 case 16: `pacman-conf --config` accepts and *validates* an arbitrary file | **CONFIRMED** | (plan is right) |

---

# PART I — ATTACKING (B)

PLAN.md analyses **none** of this. §1.4 sketches (B) in two sentences
("drops `fleet` from the container loop, runs add-repo.sh, then
`sudo pacman -Sy && sudo pacman -S fleet-git && fleet setup`") and then declines it.
Now that (B) is the ruling, that two-sentence sketch is the entire design, and it is
not sufficient. Findings below are empirical.

---

## B1 — BLOCKER. The shadowing trap inverts, and `bootstrap.sh` cannot clean up after itself

**What must change (read precisely from the source).**

- `bootstrap.sh:32-37` — `REMOTES` associative array, includes `[fleet]`.
- `bootstrap.sh:54-76` — the container loop, hardcoded `for name in nvim tmux tmuxinator fleet`.
  Note the literal list is **duplicated** at `:111` in the verify loop. Consumer mode
  must change **both**, or verify will fail on a repo it deliberately didn't clone.
- `bootstrap.sh:43-47` — `LINKS`. **Empirically confirmed: `LINKS` contains no `fleet`
  entry.**

```
$ sed -n '42,48p' bootstrap.sh
LINKS=(
  "$HOME/.config/nvim|nvim/main"
  "$HOME/.tmux.conf|tmux/main/tmux.conf"
  "$HOME/.config/tmuxinator|tmuxinator/main"
)
```

**This is the finding that reframes B1: `bootstrap.sh` has never created
`~/.local/bin/fleet`.** That symlink comes from `fleet/main/install.sh:164`
(`ln -sf "$FLEET_DIR/bin/$b" "$BIN_DIR/$b"`), which the prereq comment at
`bootstrap.sh:14-19` tells the user to run *separately*.

So "drop fleet from the container loop" is necessary and — for a *virgin* machine —
sufficient: no container, no `install.sh`, nothing to shadow with. **On a virgin
machine (B) is correct.** The bug is everywhere else.

**Is there a path where consumer mode still ends up shadowed? Yes — three, and
`bootstrap.sh` detects none of them,** because it can only skip work it owns and the
shadowing artefacts belong to `install.sh`:

1. **Previous worktree-mode run + `install.sh`** — the documented path. Container at
   `$PC_TUNE_ROOT/fleet`, symlink `~/.local/bin/fleet` → it. Consumer mode skips the
   clone (fleet not in `REMOTES` any more) but **the existing container and symlink
   stay on disk**. `pacman -S fleet-git` then installs a package that
   `~/.local/bin/fleet` shadows on PATH. This is verbatim the §1.4 harm, now reached
   *through* the fix.
2. **`install-web.sh`** — clones to `~/.local/share/fleet` and symlinks
   `~/.local/bin/fleet` there. `$PC_TUNE_ROOT/fleet` never exists, so *nothing*
   bootstrap.sh inspects would reveal it. Note `install-web.sh:47-65` already refuses
   to clobber a foreign `~/.local/bin/fleet` — the precedent exists and consumer mode
   simply doesn't use it.
3. **Stale/partial install** — a `~/.local/bin/fleet` whose target is gone.

Empirically, a *dangling* shim is the one benign case:

```
$ PATH="$W/pt/bin:$W/pt/usr:$PATH" sh -c 'fleet'
REAL packaged fleet          # shell skips a symlink that resolves to nothing
```

**Verdict: CONFIRMED (paths 1 and 2 shadow; path 3 is harmless).** Consumer mode must
**detect and refuse**, not silently proceed:

```sh
# consumer mode, before touching pacman:
if [ -e "$HOME/.local/bin/fleet" ] || [ -L "$HOME/.local/bin/fleet" ]; then
  resolved=$(readlink -f "$HOME/.local/bin/fleet" 2>/dev/null)
  [ -n "$resolved" ] && die "a dev/curl fleet install owns ~/.local/bin/fleet -> $resolved
  it would shadow /usr/bin/fleet on PATH. Remove it first:
      <that tree>/install.sh --uninstall      # or: fleet unsetup"
fi
```

Refuse, don't auto-remove: `install.sh --uninstall` also disables a systemd unit and
unwires Claude Code hooks from `~/.claude*/settings.json`. `bootstrap.sh` must not do
that behind the user's back. Note the correct cleanup already exists and is exactly
right — `install.sh:126` removes `$UNIT_DIR/fleetd.service`, `$BIN_DIR/{fleet,fleetd,
fleet-hook,fleet-guard}` — so the instruction is a one-liner for the user.

---

## B2 — HIGH. `fleet doctor` warns forever on a consumer machine, and cannot see the broken state

`doctor_config_sync()` (`bin/fleet:4550-4633`) hardcodes fleet as a config repo:

```
bin/fleet:4562        "fleet|$HOME/.local/bin/fleet"
```

and derives "canonical main" from `$PC_TUNE_ROOT/fleet/.git`. On a consumer machine
neither exists. **Answered empirically** — I built a fake consumer root (nvim/tmux/
tmuxinator containers, no fleet container, empty `~/.local/bin`) and ran the real
`doctor`:

```
$ HOME=$W/consumer/home PC_TUNE_ROOT=$W/consumer/root fleet doctor
--- config-sync (pc-tune) ---
ok   nvim: live …/.config/nvim → …/consumer/root/nvim/main (canonical main)
ok   tmux: live …/.tmux.conf → …/consumer/root/tmux/main (canonical main)
ok   tmuxinator: live …/.config/tmuxinator → …/consumer/root/tmuxinator/main (canonical main)
warn fleet: no worktree claims branch main (cannot verify live link)
ok   chezmoi: no config-repo path managed (axes decoupled)
ok   no stale sibling clones in ~/proj
```

Exit code: **0** (doctor never fails on warns — verified). So "permanently red" is
strictly "permanently *warn*, exit 0". Less bad than feared, still a broken product:
every consumer machine reports a permanent warning about a state that is **correct**,
and the message ("cannot verify live link") is doubly wrong — there is no live link to
verify *by design*.

**The severe half is the aliasing.** Compare the healthy consumer state with the
broken half-migration (fleet container removed, stale `~/.local/bin/fleet` left):

```
=== S-A: pure consumer (correct state) ===
warn fleet: no worktree claims branch main (cannot verify live link)

=== S-B: half-migrated, stale shim left behind (BROKEN state) ===
warn fleet: no worktree claims branch main (cannot verify live link)
```

**Byte-identical.** The dangling-link branch at `bin/fleet:4595`
(`warn $name: live link … is DANGLING`) is **unreachable** in this state, because the
empty-`canon` check at `:4578` `continue`s first. Doctor cannot distinguish correct
from broken.

And the genuinely dangerous state gets a green tick:

```
=== S-C: fleet container present + ~/.local/bin/fleet present (package SHADOWED) ===
ok   fleet: live …/.local/bin/fleet → …/consumer/root/fleet/main (canonical main)
```

**Verdict: CONFIRMED.** Doctor prints `ok` for the one state (B) exists to prevent,
and the same `warn` for the correct state and the broken one.

**Required fix** — `doctor_config_sync` must become mode-aware. Detect packaged mode
(`readlink -f "$(command -v fleet)"` under `/usr/lib/fleet`, or `/usr/bin/fleet`
exists) and then assert the *consumer* invariants instead:

```
ok   fleet: packaged (/usr/bin/fleet → /usr/lib/fleet), no worktree expected
warn fleet: packaged BUT ~/.local/bin/fleet exists → /usr/bin/fleet is SHADOWED   ← the B1 check
warn fleet: packaged BUT ~/.config/systemd/user/fleetd.service masks the packaged unit  ← B3b
```

That third line is the one that turns B3b from invisible into self-diagnosing, and it
costs about eight lines in a function that is already read-only and fail-silent.

---

## B3 — BLOCKER (a) + HIGH (b). `install.sh` vs `fleet setup` vs the package do fight

### B3a — the dev-shadow guard is symmetric and cannot fire

`fleet setup` has a guard built for precisely this hazard
(`bin/fleet:4767-4783`), and `packaging/fleet-git.install` advertises it:

> If you also run a fleet dev checkout via `~/.local/bin` symlinks, that copy shadows
> `/usr/bin/fleet` on PATH — `fleet setup` detects it and no-ops unless you pass
> `--force`.

The guard compares *what is first on PATH* against *the tree the running `fleet`
belongs to*:

```sh
onpath=$(command -v fleet)
[ "$(readlink -f "$onpath")" != "$(readlink -f "$FLEET_DIR/bin/fleet")" ] && abort
```

Now trace (B)'s final step on a half-migrated machine. Consumer mode runs
`pacman -S fleet-git && fleet setup`. Which `fleet` executes? PATH order →
`~/.local/bin/fleet`, the **dev** one. So `FLEET_DIR` = the dev tree, and `onpath`
also resolves to the dev tree. They **match**. Simulated:

```
which fleet     -> …/g/home/.local/bin/fleet
onpath resolves : …/g/dev/bin/fleet
FLEET_DIR/bin   : …/g/dev/bin/fleet
GUARD DOES NOT FIRE -> silently wires the DEV install; the package just installed is invisible
```

**Verdict: CONFIRMED — the guard is structurally incapable of catching this.** It
answers "is the `fleet` I am, the `fleet` you run?" It never asks "is there a *packaged*
fleet that I am hiding?" It catches *"you ran `/usr/bin/fleet` while the dev one
shadows it"* and misses the symmetric case (B) actually produces. `fleet setup` exits
0, prints success, and wires Claude Code hooks to the worktree while `pacman -Syu`
dutifully upgrades a package nobody executes.

**Fix:** add a second, asymmetric check to `cmd_setup` — if `/usr/bin/fleet` exists and
`FLEET_DIR` is not `/usr/lib/fleet`, warn that a packaged install is being shadowed.
This is worth doing in the fleet repo regardless of (B); it is a real hole in an
existing guard.

### B3b — a stale user unit masks the packaged unit

Two units, same name:

| Source | Path | `ExecStart` |
|---|---|---|
| `install.sh:176` | `~/.config/systemd/user/fleetd.service` | `%h/.local/bin/fleetd` (`systemd/fleetd.service`) |
| `PKGBUILD:99-104` | `/usr/lib/systemd/user/fleetd.service` | `/usr/bin/fleetd` (sed-patched) |

Search-path precedence, verified against this machine (`systemd.unit(5)` order):

```
$ systemd-analyze --user unit-paths | nl | grep -E 'config/systemd/user$|usr/lib/systemd/user$'
     5   /home/red/.config/systemd/user
    17   /usr/lib/systemd/user
```

`~/.config` wins by 12 places. And on this box it demonstrably does:

```
$ systemctl --user show fleetd.service -p FragmentPath
FragmentPath=/home/red/.config/systemd/user/fleetd.service
```

**Verdict: CONFIRMED.** On a migrated machine the stale user unit masks the packaged
one and points `ExecStart` at `~/.local/bin/fleetd` — which `install.sh --uninstall`
removes but which nothing in (B) as sketched removes. Result: `fleetd` fails to start,
and every daemon-backed feature silently degrades (fleet is fail-silent by design, so
this produces *no error*, just a fleet that never reports agent state).

Worse, `fleet setup` **will not repair it**. Line 4803-4804:

```sh
if [ -f "$FLEET_DIR/systemd/fleetd.service" ] && \
   [ ! -f /usr/lib/systemd/user/fleetd.service ]; then    # ← packaged unit present ⇒ skip
```

Correct as written (don't clobber the packaged unit), but it means a pre-existing stale
`~/.config` unit is never rewritten or removed — and `:4812`
`systemctl --user enable --now fleetd` then enables **the stale one**.

**Fix:** B1's refusal check closes this too, since `install.sh --uninstall` removes the
unit (`install.sh:126`). Belt and braces: `fleet setup` should warn when
`/usr/lib/systemd/user/fleetd.service` and `~/.config/systemd/user/fleetd.service` both
exist. `packaging/fleet-git.install:pre_remove` already tells users to run
`fleet unsetup` for exactly this class of state — the *install* direction needs the same
care.

**Which is authoritative in consumer mode?** `fleet setup` — and it should be the only
one. `install.sh` must never run on a consumer machine; consumer mode must not invoke
it, and the `bootstrap.sh:14-19` prereq comment (which currently instructs the user to
run `install.sh`) must be rewritten per mode or it will actively lead users into B1.

---

## B4 — HIGH. The mode-switch state matrix: 3 of 6 transitions corrupt

`bootstrap.sh:11-13` advertises idempotency ("Idempotent: safe to re-run. Skips
anything already set up; backs up anything it has to displace"). Consumer mode breaks
that promise, because the property currently holds only over artefacts bootstrap.sh
creates, and the new mode's hazards live in artefacts it doesn't.

| # | From | Run | Outcome | Detected? |
|---|---|---|---|---|
| 1 | virgin | worktree | correct (today's behaviour, unchanged) | n/a |
| 2 | virgin | consumer | **correct** — no container, no shim, package wins | n/a |
| 3 | worktree | worktree | correct (idempotent re-run) | n/a |
| 4 | consumer | consumer | **mostly correct**, but `add-repo.sh` re-runs → relies on its §2.4 no-op path; and `pacman -S fleet-git` re-runs | partial |
| 5 | **worktree → consumer** | consumer | **CORRUPT.** Container + `~/.local/bin/fleet` + stale user unit all survive; package installed and fully shadowed (B1 path 1, B3a, B3b all fire at once) | **NO** |
| 6 | **consumer → worktree** | worktree | **CORRUPT.** fleet container gets cloned and (if the user follows the prereq comment) `install.sh` runs → `~/.local/bin/fleet` now shadows a *still-installed* `fleet-git`. `pacman -Syu` keeps upgrading a dead package forever; `[fleet]` repo stanza also still in `pacman.conf` | **NO** |

Transition 6 is the one nobody will think about, and it is the mirror image of the
§1.4 harm: the plan worries about consumer mode on a dev box; nobody has considered a
dev checkout landing on a consumer box. It needs the reverse guard — worktree mode
should detect an installed `fleet-git` (`pacman -Qq fleet-git`) and tell the user to
`pacman -R fleet-git` (+ optionally `add-repo.sh --remove`) first.

Transition 4 is where `add-repo.sh`'s exit codes bite. `bootstrap.sh:20` is
`set -euo pipefail`. A bare call to `add-repo.sh` that exits **3** (foreign `[fleet]`
stanza, PLAN §2.7) **aborts bootstrap.sh mid-run**, after containers are cloned but
before symlinks are made — a half-bootstrapped machine, from a condition that is
merely "a human should look at this". Consumer mode must branch on the exit code
explicitly, which is exactly the `--check` mode I propose as addition #7.

**Verdict: CONFIRMED.** (B) needs an explicit, tested state matrix, not an assumed
idempotency property. The two corrupting transitions both have the same shape —
*artefacts of the other mode survive* — and both are closed by the same B1-style
refusal check, run in **both** directions.

---

## B5 — MEDIUM. §4's curl-vs-vendor conclusion is dead; the right answer is curl

**Claim (§4):**

> if option (B) is taken later, the answer is **neither curl nor vendor: call it from
> the local checkout.** `bootstrap.sh:54-76` already clones the fleet container, so
> `$PC_TUNE_ROOT/fleet/main/packaging/add-repo.sh` exists on disk by the time any
> fleet-install step could run … **strictly better than both options in the brief.**

**Verdict: REFUTED.** This is self-contradictory under (B). Consumer mode's defining
change is that it **does not clone the fleet container** (B1). The path §4 relies on is
therefore guaranteed *not* to exist in the only mode that would call the script. §4's
reasoning holds only in `worktree` mode, which never needs `add-repo.sh` at all. Delete
the recommendation.

Between the two survivors:

- **The "curl adds a network dependency" objection is void.** `bootstrap.sh:60` is
  `git clone --bare "$url"` against `github.com` for three repos, and `:15` requires an
  authed `gh` because tmux/tmuxinator are private. **Network and GitHub reachability are
  already hard prerequisites.** A `curl -fsSL` of a *public* raw URL adds strictly less
  than what the script already demands.
- **The "pc-tune is private so a vendored copy can't be curl'd" objection is also
  void** under (B) — nobody third-party runs pc-tune's `bootstrap.sh`; you must have
  cloned the private repo to execute it at all. §4's stated reason for rejecting
  vendoring does not apply here.

So the real trade is: **vendor** = works offline, but a second copy of a script that
writes `/etc/pacman.conf` drifting against the fleet original; **curl** = always the
current version, one more failure mode that `curl -f` makes loud.

**Recommend curl**, for one reason the plan doesn't state: `add-repo.sh` is the single
highest-blast-radius artefact in this design (a bad one bricks `pacman`). A *stale
vendored copy* of it is the worst possible thing to have on a machine — it is precisely
the script you want to be un-forkable. Pin it to `main` and let §1.3's ordering
constraint (fleet merges and pushes first) do its job.

Two consequences to write down:

1. **Consumer mode introduces the first `sudo` into `bootstrap.sh`.** It currently
   never escalates. `add-repo.sh` + `pacman -Sy` + `pacman -S` all need root, and under
   `set -euo pipefail` a sudo timeout mid-run is a hard abort. Prompt for privilege
   **once, up front** (`sudo -v`) so the failure is early and legible, not halfway
   through a container clone.
2. The `curl -fsSL … | sudo bash -s -- --yes` form means the interactive prompt is
   suppressed. That is correct *inside* bootstrap.sh — but then **bootstrap.sh** owes
   the user the security disclosure that PLAN §5.6 assigned to `add-repo.sh`'s prompt.
   It must print the stanza and the standing-grant statement itself before invoking.
   Otherwise (B) silently reintroduces exactly the "deleted moment of attention" that
   R2 identifies as a High risk. **This is the single thing most likely to be
   forgotten**, because the prompt logic will look like it is already handled.

---

## (B) — what I'd actually ship

1. `--fleet=<worktree|pacman>`, default `worktree`. Existing behaviour byte-identical.
2. Consumer mode drops `fleet` from **`REMOTES` (`:32-37`), the container loop
   (`:54`) and the verify loop (`:111`)** — all three, or verify fails.
3. **Bidirectional refusal guard** (B1 + B4 transition 6): consumer mode refuses if
   `~/.local/bin/fleet` exists; worktree mode refuses if `pacman -Qq fleet-git`
   succeeds. Both print the exact one-line remedy. Reuse `install-web.sh:47-65`'s
   pattern.
4. `sudo -v` up front; print the stanza + standing-grant disclosure; then
   `curl -fsSL …/packaging/add-repo.sh | sudo bash -s -- --yes`.
5. Branch on `add-repo.sh`'s exit code (0 / 3 / other) rather than letting
   `set -e` abort mid-bootstrap.
6. `pacman -Sy && pacman -S --needed fleet-git`, then `fleet setup` — with the
   asymmetric shadow check added to `cmd_setup` first (B3a), or step 6 can silently
   wire the wrong tree.
7. Make `doctor_config_sync` mode-aware (B2), including the "packaged but shadowed"
   and "stale user unit masks packaged unit" warnings.
8. Rewrite `bootstrap.sh:14-19` **per mode**. The current text sends users to
   `install.sh`, which is the direct cause of B1 path 1.

Items 3, 6 and 7 are the ones without which (B) reproduces the harm it was chosen to
avoid.

---

# PART II — the pacman-side empirical brief

## S1 — CRITICAL. "Repo ordering is not a security control" is REFUTED

**Claim (§2.1, §5.1 pt 2, §5.6, R4):**

> `pacman -Syu` upgrades **by version comparison across all synced repos**. A
> `sudo-9999.0-1` in `[fleet]` is a newer version than official `sudo`, so
> `pacman -Syu` installs it — from the bottom-of-file repo … Ordering is hygiene,
> not a security control.

and the resulting action item:

> Correct the ordering-implies-safety wording in `docs/custom-repo.md:23-25` and
> `README.md:156`.

**What I ran.** Built two real pacman repos on `file://` with `repo-add`, containing
`official/sudo-1.0.0-1` and `fleet/sudo-9999.0-1`. Drove a real `pacman` against a
private `--root`/`--dbpath` inside `unshare -r`.

```
$ vercmp 9999.0-1 1.0.0-1
1                                  # fleet's is unambiguously newer

# conf: [official] then [fleet]  — i.e. fleet BELOW official, as the docs instruct
$ pacman-conf --config test.conf --repo-list
official
fleet

$ pacman ... -S sudo   →  installing sudo...   →  sudo 1.0.0-1
$ pacman ... -Su
:: Starting full system upgrade...
 there is nothing to do
```

Now flip the order, changing *nothing else*:

```
# conf: [fleet] then [official]  — fleet ABOVE official
$ pacman-conf --config test-flip.conf --repo-list
fleet
official

$ pacman ... -Su --print-format '%r/%n-%v'
fleet/sudo-9999.0-1
```

**Verdict: REFUTED.** `-Su` resolves each installed package name against the **first**
sync repo (in `pacman.conf` order) that carries that name, and only then compares
versions. A lower-priority repo's higher version of a name owned by a higher-priority
repo is **never selected**. Repo order is precisely the control that blocks this.

I also tested the `replaces=` vector, which is the usual way a lower repo *can* reach
across:

```
# fleet publishes fleet-extras-1.0-1 with  replaces = sudo
# fleet BELOW official:
$ pacman ... -Su
:: Starting full system upgrade...
 there is nothing to do

# fleet ABOVE official:
$ pacman ... -Su
:: Replace sudo with fleet/fleet-extras? [Y/n]
```

Same result: pacman declines the replacement when the replaced package lives in a
higher-priority repo.

And the case that *does* work regardless of order — a name official does not carry,
i.e. `fleet-git` itself:

```
$ pacman ... -S only-in-fleet   →  1.0-1
# fleet republishes 2.0-1, fleet still BELOW official
$ pacman ... -Su --print-format '%r/%n-%v'
fleet/only-in-fleet-2.0-1        # upgrades fine
```

**Consequences for the plan — three, all bad:**

1. **§5.6's "ship alongside, at zero cost" docs change is actively harmful.** The
   existing wording in `docs/custom-repo.md:23-25` and `README.md:156` ("put it
   **below** the official repos … so official packages always take precedence") is
   **correct and load-bearing**. The plan proposes replacing it with a statement that
   ordering doesn't matter. That would remove true security guidance and install a
   false claim. **Delete R4 and this action item.**
2. **§2.1's dismissal of the insertion-point question is right for the wrong reason.**
   "Append at EOF" is not merely hygiene — it is the *only* thing standing between the
   user and a `[fleet]` DB that can shadow `glibc`/`sudo`/`openssh`. That makes the
   EOF-append decision *more* load-bearing, not less, and it makes the ordering
   assertion in §6 case 1 ("it is the **last** section header in the file") a security
   assertion rather than a cosmetic one. Say so.
3. **§5.1's threat statement is overstated and should be rewritten.** The honest
   version: adding this repo grants the publisher root-code-execution **for package
   names not carried by a higher-priority repo** — which includes `fleet-git` and any
   *new* name the publisher invents. That is still a serious standing grant (a new
   package name with a malicious `.install` scriptlet is installed as root on
   `-S`, and `-Su` will upgrade anything already installed from `[fleet]`), but it is
   *not* "can publish `glibc-99.0` and win", which is what the plan says twice.

The prompt text the plan wants add-repo.sh to print (§5.4 option b) would therefore
be telling the user something false. Fix the threat model before writing the prompt.

---

## S2 — CRITICAL. The verification step is false-green

**Claim (§2.6 step 8):**

> Verify: … run `pacman-conf --repo-list` if available and assert `fleet` appears.
> **This is the single best end-to-end assertion available.**

**What I ran.** A conf whose `Include` pulls in a foreign `[fleet]`, then the managed
block appended at EOF exactly as the plan specifies:

```
$ pacman-conf --config c.conf --repo-list
core
fleet
fleet                              # ← listed TWICE
exit=0

$ pacman-conf --config c.conf --repo=fleet
Server = https://evil.example.org/fleet     # ← the FOREIGN server wins
exit=0
```

**Verdict: REFUTED as sufficient.** The assertion "`fleet` appears in `--repo-list`"
**passes** on a conf where our stanza is dead and the effective `[fleet]` repo points
at somebody else's server. The script would print success and next steps.

Also note `pacman-conf` exits **0** with only a *warning* for a malformed header:

```
$ pacman-conf --config g.conf --repo-list
warning: config file g.conf, line 7: directive '[fleet] # note' in section 'core' not recognized.
core
exit=0
```

**Required fix — the verification must assert all four:**
1. `pacman-conf --config "$CONF" --repo-list | grep -cx fleet` **equals exactly 1**;
2. `pacman-conf --config "$CONF" --repo=fleet` reports the `Server` **we intended**;
3. `pacman-conf` produced **no output on stderr** (warnings are silent corruption);
4. `core`/`extra` are still listed (the plan has this one).

---

## S3 — HIGH. Detection is blind to `Include`, and the failure mode bricks pacman

**Claim (§3.11):**

> Conf contains an `Include` that pulls in repos from elsewhere → **Irrelevant to
> correctness:** EOF is still after everything. Worth one doc sentence.

**What I ran.** `Include` *is* inline expansion — that half is confirmed:

```
# [core] { Include ./inc/mirrorlist; Include ./inc/repos.conf }  then [extra]
$ pacman-conf --config a.conf --repo-list
core
included-repo                      # expands in place, between core and extra
extra
```

But now the detection path. A conf that ends with `Include = ./inc/fleet-other.conf`,
where that file defines an active `[fleet]`:

```
$ grep -cE '^[[:space:]]*\[fleet\]' c.conf
0                                  # ← the plan's detector says ABSENT → it appends
```

Result after appending: the duplicate shown in S2. And what real `pacman` does with a
duplicate `[fleet]`:

```
$ pacman --config d.conf -Sl fleet
error: could not register 'fleet' database (database already registered)
```

**Verdict: §3.11's "irrelevant to correctness" is REFUTED.** It is correct for
*ordering* and wrong for *detection*. The plan's §2.8 aside — "pacman errors on
duplicate sections" — is **CONFIRMED**, but the plan files it as a footnote to the
concurrency race. It is not a footnote: `could not register … database already
registered` is emitted on **every subsequent pacman invocation**, i.e. the machine
can no longer install or update anything. That is exactly the R3 outcome ("a corrupted
`/etc/pacman.conf` bricks package management") that the plan claims to have mitigated,
reachable through a path the plan classified as irrelevant.

Note also that pacman-conf itself does **not** error on the duplicate — it takes the
**first** and exits 0 (S2). So neither the detector nor the verifier catches this.

**Required fix — and it is a genuine simplification.** Stop grepping INI. Ask pacman:

```sh
pacman-conf --config "$CONF" --repo-list | grep -qx "$FLEET_REPO_NAME"
```

That answers "does pacman already see a `[fleet]` repo?" exactly — through `Include`,
through whitespace variants, through everything — with no regex. Use the marker-comment
grep only to distinguish *ours* from *foreign*. This collapses §2.4's entire
classification problem, fixes S3, and removes S6. The plan reaches for `pacman-conf`
as a *verifier* but never considers it as a *detector*; it should be both.

(Confirmed in the same run: duplicate `[options]` does **not** error and the **last**
value wins — `ParallelDownloads` resolved to `99`, not `5`. Different rule from repos.
Harmless here, but the plan's §3 table has no row for it.)

---

## S4 — HIGH. Verification runs after the `mv`, so a bad write goes live

**Claim (§2.6):** the ordered algorithm is … 5. build temp → 7. `chmod --reference` +
`mv` → 8. verify with `pacman-conf`. Exit code 4 is "Write/verification failed **after
backup**".

**Verdict: CONFIRMED as a design flaw.** The plan's own exit-code table concedes that
verification can fail *after* the file has been replaced; its remedy is to print the
backup path and let the human restore. That is unnecessary. `pacman-conf --config`
accepts any path (proven below), so the candidate can be validated **while it is still
a temp file**:

```
5. build temp in the same directory
6. normalise the tail
6b. VALIDATE: pacman-conf --config "$TMP" --repo-list   (all four assertions from S2)
    → on failure: rm "$TMP", exit 4, original never touched
7. chmod --reference, mv
8. re-verify the live file (cheap belt-and-braces)
```

With that reordering, exit 4 becomes "we refused to install a broken conf" instead of
"we installed a broken conf, here's your backup". Free, and it retires most of R3.

---

## S5 — MEDIUM. The preflight tests the wrong permission

**Claim (§3.8):**

> Test `[ -w "$CONF_REAL" ]` rather than `[ "$(id -u)" = 0 ]`. Root-check alone is
> wrong for the harness … and for exotic ACLs.

**What I ran.** A writable file inside a non-writable directory — which is the shape
of "exotic ACLs" the plan invokes, and also the shape of a `pacman.conf` symlinked
into a read-only dotfiles checkout (§3.10):

```
$ [ -w ro/d/pacman.conf ] && echo "preflight PASSES"
preflight PASSES

$ mktemp "ro/d/.pacman.conf.fleet.XXXXXX"
mktemp: failed to create file via template ‘ro/d/.pacman.conf.fleet.XXXXXX’: Permission denied
```

**Verdict: REFUTED.** The preflight passes and step 5 then fails. Worse, it is wrong in
*both* directions: with a same-directory `mktemp` + `mv` strategy, write permission on
the **file** is not required at all — `mv` needs write permission on the **directory**.
The correct preflight is `[ -w "$(dirname "$CONF_REAL")" ]`, and it must be evaluated
against the *resolved* path, so for the §3.10 symlink case it checks the dotfiles
directory rather than `/etc`. The plan never connects §3.8 to §3.10 or to §2.6 step 5;
all three have to agree and currently don't.

---

## S6 — MEDIUM. The detection regex is specified twice, with two different meanings

§2.4 case 2 says: `^[[:space:]]*\[fleet\][[:space:]]*$` (fully anchored).
§2.4 prose and §3.5 say: match `^[[:space:]]*\[fleet\]` **only**.
§6 case 6's pass condition repeats the unanchored form.

These disagree. I built hostile fixtures for both (`| anchored | loose | does pacman
see a fleet repo?`):

| fixture | anchored | loose | pacman sees `fleet` |
|---|---|---|---|
| `[fleet]` | DETECTED | DETECTED | yes |
| `  [fleet]` (spaces) | DETECTED | DETECTED | yes |
| `\t[fleet]` (tab) | DETECTED | DETECTED | yes |
| `[fleet]   ` (trailing ws) | DETECTED | DETECTED | yes |
| `[fleet] # note` | absent | **DETECTED** | **no** |
| `[fleet]# note` | absent | **DETECTED** | **no** |
| `[ fleet ]` | absent | absent | no |
| `[fleet]\r\n` (CRLF) | DETECTED | DETECTED | yes |
| `#[fleet]` | absent | absent | no |
| `[FLEET]` | absent | absent | no |

**Verdict: CONFIRMED (ambiguous spec).** Credit where due — the **fully anchored**
form agrees with pacman on all ten fixtures, including the CRLF case (`\r` matches
`[[:space:]]`, and pacman does accept `[fleet]\r`). The **unanchored** form false-
positives on `[fleet] # note`, which pacman rejects as a directive (`warning: …
directive '[fleet] # note' in section 'core' not recognized`) — so the loose regex
would refuse with exit 3 on a conf that has no fleet repo at all.

Fix: delete the unanchored form from §2.4 prose, §3.5 and §6 case 6. Or, better, adopt
the `pacman-conf`-as-detector approach from S3 and delete the regex entirely.

---

## S7 — MEDIUM. CRLF handling is unnecessary and its rationale is false

**Claim (§3.4):** detect CRLF and emit CRLF for the appended block; *"pacman itself
tolerates trailing `\r` poorly in values — flag in docs."* Plus §2.6 step 6 and §6
case 5.

**What I ran.** A fully-CRLF conf, and a deliberately mixed one (CRLF body, LF-only
appended block — i.e. exactly what a naive implementation produces):

```
# all-CRLF
$ pacman-conf --config n.conf --repo-list
core
fleet
exit=0
$ pacman-conf --config n.conf --repo=fleet | grep Server | cat -A
Server = https://x/f$              # ← no ^M: pacman STRIPS the CR

# mixed: CRLF file + LF-appended [fleet] block
$ file o.conf
o.conf: Microsoft HTML Help Project      # (file(1) confused; pacman is not)
$ pacman-conf --config o.conf --repo-list
core
fleet
exit=0
$ pacman-conf --config o.conf --repo=fleet | grep Server
Server = https://x/f
```

**Verdict: REFUTED.** pacman strips CR cleanly, parses mixed line endings without
complaint, and the "tolerates `\r` poorly in values" claim is false. §3.4, the CRLF
half of §2.6 step 6, and §6 case 5 are gold-plating on a hazard that does not exist —
delete all three. (The *other* half of step 6, the missing-trailing-newline fix, is
essential; see below.)

---

## S8 — MEDIUM. The proposed fixtures will hard-fail or couple the harness to `/etc`

§6.3 specifies a `stock` fixture: "Full stock Arch pacman.conf including the commented
`#[custom]` example block". A stock Arch pacman.conf contains
`Include = /etc/pacman.d/mirrorlist` in every repo.

```
# missing Include target
$ pacman-conf --config l.conf --repo-list
error: config file /nonexistent/mirrorlist could not be read: No such file or directory
error parsing 'l.conf'
exit=1

# relative Include resolves against CWD, NOT the conf's directory
$ cd / && pacman-conf --config $W/sub/base.conf --repo-list
error: config file ./inc/mirrorlist could not be read: No such file or directory
exit=1
```

**Verdict: CONFIRMED.** Two consequences:
- A heredoc `stock` fixture keeps `Include = /etc/pacman.d/mirrorlist`, so §6.2's
  "fixtures are built by heredocs, **never copied from `/etc`**" is defeated in
  spirit — case 16 then reads `/etc` and its result depends on the host machine. It
  would fail outright in an `archlinux:latest` CI container with no mirrorlist.
- Any relative `Include` in a fixture is CWD-dependent and will break depending on
  where the harness is invoked from.

Fix: fixtures must use `Server = file:///dev/null`-style repo bodies with **no
`Include`**, or write a real mirrorlist into `$TMPROOT` and reference it by absolute
path. Either way, add an explicit case asserting `pacman-conf --config` exits 0 on the
*pristine* fixture before the add, so a fixture bug can't be misread as a script bug.

**On OQ-7 (should case 16 be hard rather than SKIP-if-absent): yes, make it hard.**
`pacman-conf` genuinely validates, not just parses:

```
$ pacman-conf --config h2.conf --repo-list        # garbage input
error: config file h2.conf, line 1: All directives must belong to a section.
exit=1

$ pacman-conf --config h3.conf --repo-list        # SigLevel = NotAValidLevel
error: config file h3.conf, line 5: invalid value for 'SigLevel' : 'NotAValidLevel'
exit=1
```

It is the only case that proves the output is valid *to pacman*, and per §3.7 the
script already refuses to run where `pacman` is absent — so SKIP-if-absent is
unreachable in any run that matters.

---

## Claims I tried to break and could not — the plan is right on these

**§2.1 "EOF is by definition below the official repos."** **CONFIRMED.** Including the
hard case, where a trailing `Include` pulls in a repo:

```
# b.conf: [options], [core]{Include mirrorlist}, Include ./inc/repos.conf, then [fleet] appended at EOF
$ pacman-conf --config b.conf --repo-list
core
included-repo
fleet                              # ← still last
```

**§2.1 "Include is inline expansion."** **CONFIRMED** (test A, S3 above).

**§3.3 the no-trailing-newline bug.** **CONFIRMED — and the plan understates it.** The
plan says it "silently makes the *previous* repo's Server garbage." It is worse than
that; it is a repo hijack:

```
# omarchy-shaped conf with no final newline, then a naive `cat >>`
$ tail -2 i2.conf
Server = https://pkgs.omarchy.org/stable/$arch[fleet]
Server = https://x/f

$ pacman-conf --config i2.conf --repo-list
core
omarchy                            # ← [fleet] repo was NEVER created
exit=0                             # ← no error, no warning

$ pacman-conf --config i2.conf --repo=omarchy | grep Server
Server = https://pkgs.omarchy.org/stable/x86_64[fleet]
Server = https://x/f               # ← the fleet URL is now an omarchy MIRROR
```

So `[omarchy]` gains the fleet release URL as a fallback server — the fleet publisher
silently becomes a package source for the omarchy repo — while `[fleet]` doesn't exist
and pacman exits 0 throughout. This is the strongest single justification for the whole
work item, and §6 case 4 is the most valuable case in the harness. It deserves to be
stated at this strength in the plan and in the case-4 comment.

**§3.10 `readlink -f` + write-the-target.** **CONFIRMED.**

```
$ CONF_REAL=$(readlink -f sym/conf)      # → sym/real/pacman.conf
$ TMP=$(mktemp "$(dirname "$CONF_REAL")/.pacman.conf.fleet.XXXXXX")
$ chmod --reference="$CONF_REAL" "$TMP"; echo $?      → 0
$ mv "$TMP" "$CONF_REAL"
conf still symlink? YES
link target: real/pacman.conf        # relative link preserved intact
mode: 644                            # chmod --reference behaved as claimed
$ pacman-conf --config sym/conf --repo-list
core / extra / fleet
```

Chained relative symlinks resolve correctly too (`sym2/top → a/mid → ../b/real.conf`
→ absolute target). Caveat: this is exactly why S5 matters — the writable directory is
now the dotfiles directory, not `/etc`.

**§2.6 step 5 same-directory `mktemp` + `mv`.** **CONFIRMED** as the right strategy
(`rename(2)` within one filesystem is atomic; `/tmp` here is a separate `tmpfs`, so the
plan's stated reason is correct on this machine). The *ordering* around it is the
problem — see S4.

**§6 case 16 `pacman-conf --config <arbitrary file>`.** **CONFIRMED** — accepts any
path, and validates (S8).

**Marker comments don't confuse pacman.** **CONFIRMED** — a conf with
`# >>> fleet repo … >>>` / `# <<< fleet repo <<<` around the stanza parses clean and
lists `core`, `fleet`. §2.4's marker scheme is safe. (On **OQ-6**: keep the markers,
and print the marker block in the docs verbatim. A docs/script mismatch guarantees
someone hand-pastes the unmarked form and then hits the exit-3 refusal path on their
next run — the plan's own §3.6 migration story. Making the documented text and the
written text identical removes that trap for free.)

---

## Is this the best way? Is there a better way? What additions?

### Is this the best way?

**Directionally yes, with one unexamined alternative.** Given the constraint "the
machine should track fleet via `pacman -Syu`", editing `pacman.conf` is unavoidable
(§5.5's rejection of the `fleet-repo` package and of a `conf.d` drop-in is sound — I
confirmed `/etc/pacman.conf.d` does not exist and pacman 7.1.0 has no such convention),
and appending at EOF is the correct algorithm — *more* correct than the plan realises,
per S1.

### Is there a better way?

**One the plan never considers: don't edit `pacman.conf` at all for first install.**
pacman accepts a remote URL for `-U`. If `publish-repo.sh` and the CI workflow also
uploaded the package under a **stable filename** (they already use
`gh release upload --clobber`, so this is a one-line addition), the entire first-run
story becomes:

```sh
sudo pacman -U https://github.com/Redmern/fleet/releases/download/repo/fleet-git-latest-any.pkg.tar.zst
```

Zero config edit, zero `curl | sudo bash`, zero standing `TrustAll` grant, zero
`SigLevel` change (`LocalFileSigLevel = Optional` is already the default on this box —
`/etc/pacman.conf:16`). The trade-off is honest and worth stating: **no automatic
`-Syu` updates.** But it exactly serves the "laptop / fresh box, I just want fleet"
case, and it is strictly *safer* than the repo (one-shot install vs. a standing root
channel redeemed on every future update). It also makes a clean two-tier story:

- *"I just want fleet here"* → `pacman -U <stable url>`, no repo, no standing grant.
- *"I want fleet to track main here"* → `add-repo.sh`, accept the standing grant.

I could not verify remote `-U` end-to-end (no network in this environment) — marked
**UNVERIFIABLE**, and it should be checked before adopting. But it is a materially
different point in the design space that the plan's alternatives section
(§5.5) does not mention, and it deserves a paragraph.

### Additions that would improve it

1. **Use `pacman-conf` as the detector, not just the verifier** (S3). Single biggest
   structural improvement: fixes the `Include` blind spot, deletes the regex, deletes
   S6, and shrinks §2.4 from a three-way INI classification to a two-line check.
2. **Validate the temp file before the `mv`** (S4). Turns "we broke your conf, here's
   the backup" into "we refused to break your conf."
3. **Four-part verification** (S2): count == 1, effective `Server` matches, stderr
   empty, `core`/`extra` still present.
4. **Preflight the resolved parent directory, not the file** (S5).
5. **Delete the CRLF machinery** (S7) — §3.4, half of step 6, case 5.
6. **Fix the threat model text before writing the prompt** (S1). The prompt is the
   plan's headline safety feature; it must not print a false claim.
7. **A `--check` / status mode.** Exit 0 = managed block present and current, 3 =
   foreign, 1 = absent. `--dry-run` prints; `--check` is machine-readable. This is what
   §1.4 option (B) would actually need from `bootstrap.sh` under `set -euo pipefail`,
   and it costs nothing to add now.
8. **On OQ-2 — agreed, and it is worse than the plan says.** `curl … | sudo bash`
   means stdin *is* the script. A `read` gets the script's own remaining bytes, not the
   user. The prompt **must** open `/dev/tty` explicitly and, when there is no tty,
   **exit non-zero** telling the user to pass `--yes` — never proceed, never
   auto-decline-silently. The plan flags this; make it a harness case (a run with
   stdin closed and no tty must exit non-zero and write nothing), because it is the
   kind of thing that regresses invisibly.
9. **On OQ-4 — agreed with the plan: do not run `pacman -Sy`.** Different blast radius,
   and `-Sy` without `-u` is the documented partial-upgrade footgun. Print it as the
   next step, as §2.6 step 9 already does.
10. **On OQ-5 (GPG) — the plan's deferral is defensible, but S1 changes the calculus
    slightly in *favour* of deferring.** The realistic attack is not `glibc`
    shadowing (blocked by ordering) but a malicious `fleet-git` or a new package name.
    That is a narrower surface than §5.1 claims, which makes "defer with a written
    trigger" more reasonable, not less. Keep the three trigger conditions; they are
    good.
11. **On OQ-3 — agreed, don't ship it in the package.** But once (B) exists, note that
    `fleet doctor` could *check* the stanza (read-only) and warn if the `Server` is
    stale. That is the non-circular half of the idea and is worth a line.

---

## OQ-1 — the central question. My position: **(B)**, and (A) is a dodge

The plan recommends **(A) fix the stale comment only**, on this reasoning:

> The stated goal — "eliminate the manual pacman.conf edit when installing fleet on a
> new non-dev Arch machine" — is fully achieved by the fleet side alone.

**Is (A) a dodge? Yes — and the plan does quietly redefine the goal to get there.**

The redefinition is subtle and worth naming precisely. The brief's leaning was *"wire
add-repo.sh into pc-tune's bootstrap.sh so a fresh machine needs no hand-editing."*
The plan restates the goal as *"eliminate the manual pacman.conf edit … on a new
non-dev Arch machine"* — dropping the words **bootstrap.sh** and **fresh machine**, and
inserting **non-dev**. With those three edits, (A) satisfies it trivially, because
"non-dev machine" is now defined as "a machine that does not run bootstrap.sh", and
there is no such machine.

That is the real objection, and it is empirical, not rhetorical: **under (A),
`add-repo.sh` has zero users.**

- Every machine red actually stands up runs `bootstrap.sh`, which clones fleet as a
  worktree container (`bootstrap.sh:32-37`, `:54-76`) and symlinks `~/.local/bin/fleet`
  into it. Those machines are excluded from the pacman path by construction.
- `bootstrap.sh`'s own prereq block (`:14-19`) tells you to install fleet by cloning
  and running `install.sh` — the *non*-pacman path. Under (A) that comment gets
  "corrected" to point at `install-web.sh`, which is *also* the non-pacman path. So
  after (A), pc-tune still never touches the pacman repo.
- The only consumer left is the hypothetical "laptop, fresh box" in
  `docs/custom-repo.md:16`. The plan's own §5.6 deferral trigger #1 ("**any** machine
  that is not solely red's runs add-repo.sh") strongly implies that machine does not
  exist yet.

So (A) proposes: build `packaging/add-repo.sh`, a 21-case proof harness, and rewrite
three documents — then decline to connect it to the only bootstrap that exists. That is
not scope discipline; it is building the thing and not plugging it in. If (A) really is
the answer, then intellectual honesty demands the *rest* of the plan shrink to match:
you do not write a 21-case harness for a script with no users.

**But the plan's objection to (B) is real and must be respected.** (B) as the plan
sketches it — run `add-repo.sh`, then `pacman -S fleet-git` — would, if the fleet
container is still cloned, install a package permanently shadowed by
`~/.local/bin/fleet`. The plan is right that this is worse than doing nothing. R1 is a
correct risk.

**The resolution is that (B) must be *mutually exclusive*, not additive** — and the
plan already half-says this ("drops `fleet` from the container loop") without noticing
that this fully answers its own objection. Concretely:

- `bootstrap.sh --fleet=pacman` (default `worktree`, so existing behaviour is
  byte-identical and the dev box is untouched).
- In `pacman` mode, `fleet` is removed from the `REMOTES` loop entirely — no container,
  no worktree, **nothing to shadow with**. R1 evaporates; it was a consequence of
  running both modes at once, not of (B) itself.
- Call `add-repo.sh` **from the local checkout** — except in `pacman` mode there is no
  fleet checkout, so here the plan's §4 conclusion inverts and it must `curl` the raw
  URL. Worth noting: §4 asserts "call it from the local checkout … strictly better than
  both options in the brief," which is true under (A)/`worktree` mode and **false**
  under the very mode that would use it. Small internal inconsistency, but it would
  bite an implementer.
- Add the shadow guard **this repo already has a proven pattern for**:
  `install-web.sh:47-65` refuses when `~/.local/bin/fleet` resolves outside its managed
  dir. Reuse that check verbatim in `pacman` mode and R1 cannot recur even if a user
  flips modes on a machine that was previously a dev box.
- Use the `--check` exit codes (addition #7) so `bootstrap.sh`'s `set -euo pipefail`
  (`:20`) can distinguish "already configured" from "broken".

Is `--fleet=pacman` a coherent product? Yes. `bootstrap.sh` sets up **four** repos;
three of them (nvim, tmux, tmuxinator) are *configuration* red wants everywhere. Only
`fleet` is a *tool* he hacks on. "I want red's configs on this laptop, but I don't
develop fleet here" is the exact machine `docs/custom-repo.md:16` is written for. (B)
makes that machine work end to end with no hand-editing — which is the original goal,
before the restatement.

**(C) is the worst option.** It duplicates the whole container/symlink/verify body of
`bootstrap.sh` to vary one decision. The plan calls it "most honest, most duplication";
the duplication is the whole cost and the honesty is available for ~15 lines under (B).

**Firm position: (B), landed in the same sequence, not deferred.** §1.3's ordering
constraint (fleet merges first, pc-tune second) already forces a pc-tune commit; adding
a flag to it costs almost nothing at that moment and a great deal later, because "(B)
as a follow-up if a real consumer machine materialises" is how a script acquires zero
users permanently.

**If the decision gate nonetheless picks (A), then it must also cut scope**: ship
`add-repo.sh` + the six RED-against-naive cases (4, 7, 10, 11, 13, 20 — the plan's own
list) and skip the rest until there is a consumer. Shipping (A) *and* the full 21-case
harness is the worst of both: maximum effort, zero users.

---

## Appendix — what I ran

All in `$(mktemp -d)` under the session scratchpad; `/etc` never written.

- `pacman-conf --config <fixture> --repo-list` / `--repo=fleet` across ~20 fixtures.
- Ten hostile section-header fixtures against both regex forms in §2.4.
- Real `pacman -Sy` / `-S` / `-Su` / `-Sl` / `-Ss` against two hand-built `file://`
  repos (`repo-add`, hand-crafted `.PKGINFO` packages), driven under `unshare -r` with
  private `--root` / `--dbpath` / `--cachedir`. Both repo orderings; plus a `replaces=`
  package; plus a fleet-only package upgrade.
- `readlink -f` + `mktemp` + `chmod --reference` + `mv` on single and chained relative
  symlinks; read-only-directory permission split; `df` to confirm `/tmp` is a separate
  filesystem.
- CRLF, mixed-ending, missing-`Include`, relative-`Include`, duplicate-`[fleet]`,
  duplicate-`[options]`, marker-comment, and no-trailing-newline fixtures.

`/etc/pacman.conf` sha256 verified identical before and after:
`b19c50501ef9528fb47623f312978af5a5d0df6e7d25844b01f91b7dc75baa46`.
