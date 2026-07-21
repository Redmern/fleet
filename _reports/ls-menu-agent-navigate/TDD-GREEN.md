# TDD-GREEN — d5 / ls-popup-navigate

Same harness as TDD-RED, against the PATCHED bin/fleet. All checks pass.

## Harness output
```
== SELF=/home/red/proj/pc-tune/fleet/fleet_ls-popup-navigate/bin/fleet ==
== windows: A=@1(blocked) B=@2(working) C=@3(idle) ==
PASS  static print lists *_hidden agent
PASS  --measure is not the static table (no tab header)
PASS  --measure emits fzf prompt chrome line
PASS  --measure drops *_hidden rows
PASS  --measure exits 0
PASS  ls --pick piped/non-tty returns (no hang)
PASS  ls --pick non-tty falls back to printed rows
PASS  picking repoC_idle navigates to its window (@3==@3)
PASS  picking repoB_fix navigates to its window (@2==@2)
PASS  *_hidden agent is not selectable (active stays @1)
PASS  no-match pick is inert (active stays @1)
PASS  fleet doctor reports ok fzf
== 12 passed, 0 failed ==
```

## Empty-diff keystone (S1): `fleet ls` static byte-for-byte unchanged
```
IDENTICAL — static/CLI ls output unchanged pristine vs post
```

## Live keystone (S2 / §3): real display-popup -E, cross-session jump
A genuine `tmux display-popup -E` running `ls --pick --all` (fzf forced to
select `repoZ_cross` via `--filter`) ran `switch-client -t sbx2` AND
`select-window -t @3` from the popup/client context; the attached client
moved cross-session:
```
before: sbx  @1
after:  sbx2 @3 repoZ_cross   (== expected)
```
Proves the switch-client+select-window composition works from a sizer-style
-E popup — the one combination neither precedent covered end-to-end.

## fleet doctor
```
ok   fzf
```
