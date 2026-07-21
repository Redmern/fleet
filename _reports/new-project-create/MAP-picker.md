# MAP: Fleet Project Picker (FCF) — "Create New Project" Integration

## Executive Summary

This document maps the exact flow when a user runs bare `fleet` (no arguments) and explains where to inject a "create new project" option into the interactive fzf picker.

---

## 1. Bare `fleet` Dispatch (bin/fleet:4132-4141)

When a user runs `fleet` with **zero arguments** at an interactive terminal:

```bash
# /home/red/proj/pc-tune/fleet/main/bin/fleet lines 4132-4141
case "${1:-}" in
  # ... other subcommands ...
  "")
    # bare `fleet`: project picker only when interactive (stdin+stdout tty) AND
    # fzf present AND projects exist (cmd_pick_project handles the latter two).
    # Otherwise usage. NOTE: scripts/dashboard always call WITH a subcommand and
    # non-interactively, so they keep getting usage, never a popup.
    if [ -t 0 ] && [ -t 1 ]; then cmd_pick_project; else print_usage; fi
    ;;
esac
```

**Entry Point:** `cmd_pick_project` at **line 371**

**Preconditions:**
- stdin is a TTY (`[ -t 0 ]`)
- stdout is a TTY (`[ -t 1 ]`)
- Falls back to `print_usage` if either fails or fzf is missing

---

## 2. cmd_pick_project Implementation (bin/fleet:371-399)

### Complete Function

```bash
cmd_pick_project() { # fzf picker over saved projects -> fleet up <name> (bare `fleet`)
  # fzf-missing falls back to usage (do NOT popup); caller already gated on tty.
  command -v fzf >/dev/null || { print_usage; return 0; }
  local dir="$CONF_DIR/projects" ymls=()
  [ -d "$dir" ] && ymls=("$dir"/*.yml)
  # zero saved projects: friendly hint + usage, never an empty fzf.
  if [ ${#ymls[@]} -eq 0 ] || [ ! -e "${ymls[0]}" ]; then
    echo "no saved projects yet — run 'fleet save <name>' inside a session"
    echo
    print_usage
    return 0
  fi
  local rows="" f nm root
  for f in "${ymls[@]}"; do
    [ -f "$f" ] || continue
    nm=$(basename "$f" .yml)
    root=$(awk -F': *' '$1=="root"{print $2; exit}' "$f")
    if tmux has-session -t "=$nm" 2>/dev/null; then
      rows+=$(printf '%s\t\033[32m●\033[0m %-18s %s  \033[32m(running)\033[0m' "$nm" "$nm" "$root")$'\n'
    else
      rows+=$(printf '%s\t  %-18s %s' "$nm" "$nm" "$root")$'\n'
    fi
  done
  local choice
  choice=$(printf '%s' "$rows" | fzf --ansi --delimiter='\t' --with-nth=2 \
            --no-sort --prompt='project> ' --height=100% --border=rounded) || return 0
  [ -n "$choice" ] || return 0
  cmd_up "$(printf '%s' "$choice" | cut -f1)"
}
```

### 2.1 Row Building (bin/fleet:384-393)

**Source:** YAML files from `$CONF_DIR/projects/*.yml` (where `$CONF_DIR = ~/.config/fleet`)

**Row Format:**
```
<project-name> <TAB> <ansi-colored-display> <TAB> <empty>
```

**Two variants built in the for loop:**

- **Running session exists** (line 389):
  ```bash
  rows+=$(printf '%s\t\033[32m●\033[0m %-18s %s  \033[32m(running)\033[0m' \
    "$nm" "$nm" "$root")$'\n'
  # Result: "pc\t● pc                 ~/proj/pc-tune  (running)"
  ```

- **No running session** (line 391):
  ```bash
  rows+=$(printf '%s\t  %-18s %s' "$nm" "$nm" "$root")$'\n'
  # Result: "techweb2\t  techweb2           ~/work/rib/repos/techweb2.0"
  ```

**Example accumulated rows (from existing yml files):**
```
pc	● pc                 ~/proj/pc-tune  (running)
techweb2	  techweb2           ~/work/rib/repos/techweb2.0
webshop	  webshop            ~/proj/webshop
```

### 2.2 fzf Invocation (bin/fleet:395-396)

```bash
choice=$(printf '%s' "$rows" | fzf --ansi --delimiter='\t' --with-nth=2 \
          --no-sort --prompt='project> ' --height=100% --border=rounded) || return 0
```

**fzf Flags Explained:**

| Flag | Purpose |
|------|---------|
| `--ansi` | Interpret ANSI escape codes (`\033[32m` = green color) |
| `--delimiter='\t'` | Split rows on tab character |
| `--with-nth=2` | Display **only field 2** (the colored status line); keep all fields internally |
| `--no-sort` | Preserve input order (don't alphabetize) |
| `--prompt='project> '` | Input line prompt |
| `--height=100%` | Full terminal height |
| `--border=rounded` | Rounded visual border |

**User Actions:**
- Type to filter project names
- **Enter** → select the highlighted row
- **Esc** → cancel (returns via `|| return 0`)

### 2.3 Selection Routing (bin/fleet:397-399)

```bash
[ -n "$choice" ] || return 0
cmd_up "$(printf '%s' "$choice" | cut -f1)"
```

1. Check if user made a choice (non-empty)
2. Extract **field 1** (the project name / sentinel value): `cut -f1`
3. **Route to:** `cmd_up <project-name>` (or sentinel value)

---

## 3. cmd_up — Project Resolution (bin/fleet:3455-3568)

### Entry Point & Argument Parsing (lines 3456-3484)

```bash
cmd_up() {
  local arg="" root name no_restore=0 tmuxinator=0 harness=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore) shift ;;
      --no-restore) no_restore=1; shift ;;
      --tmuxinator) tmuxinator=1; shift ;;
      --harness|-h) harness="$2"; shift 2 ;;
      *) [ -z "$arg" ] && arg="$1"; shift ;;
    esac
  done
  
  # When called from cmd_pick_project, $arg = project name (e.g., "pc", "techweb2")
  
  if [ -n "$arg" ] && [ -d "$arg" ]; then
    # Case A: direct path argument
    root=$(readlink -f "$arg")
    name=$(basename "$root" | tr -cd 'a-zA-Z0-9_-')
  elif [ -n "$arg" ]; then
    # Case B: project name lookup in yml
    name="$arg"
    local yml="$CONF_DIR/projects/$arg.yml"
    if [ -f "$yml" ]; then
      root=$(awk -F': *' '$1=="root"{print $2; exit}' "$yml")
      root="${root/#\~/$HOME}"  # Expand ~ to $HOME
      case "$(awk -F': *' '$1=="tmuxinator"{print $2; exit}' "$yml" | tr -d '[:space:]')" in
        true|yes|1) tmuxinator=1 ;;
      esac
    fi
    [ -n "${root:-}" ] || root="$PWD"
  else
    # Case C: no argument (not used from picker)
    root="$PWD"
    name=$(basename "$root" | tr -cd 'a-zA-Z0-9_-')
  fi
  
  [ -d "$root" ] || die "project root $root does not exist"
  # ... continue with session creation ...
}
```

### YAML Fields Read (lines 3471-3478)

When `cmd_up <project-name>` is called:
1. **Reads `$CONF_DIR/projects/<name>.yml`** (line 3471)
2. **Extracts `root:` field** (line 3473) — **REQUIRED**
   - Path can use `~` (expanded to `$HOME`)
3. **Checks for `tmuxinator:` field** (lines 3476-3478) — **OPTIONAL**
   - If `true|yes|1`, enables tmuxinator layout on `fleet up`
4. **Uses `name:` field** — **OPTIONAL**, for readability only (written by `cmd_save`, never read)

### Project YAML Example

```yaml
name: pc
root: ~/proj/pc-tune
```

```yaml
name: techweb2
root: ~/work/rib/repos/techweb2.0
tmuxinator: true
```

### Session Creation (lines 3502-3540)

- Creates tmux session named `$name`
- Sets `@fleet_root` session option to `$root` (line 3542)
- Spawns orchestrator harness (Claude or other) in main window
- Restores previously-saved agents (if session is new)

---

## 4. fzf Styling Conventions (Pickers Across Fleet)

Fleet has multiple fzf pickers (agents, sessions, projects). They share a **consistent visual language**:

### cmd_pick — Agent Picker (bin/fleet:347-369)

```bash
rows=$(agents_tsv | sort -t$'\t' -k1,1 | awk -F'\t' '
  $3 ~ /_hidden$/{next}
  $1=="blocked"{c="\033[31m"; o=0}
  $1=="idle"   {c="\033[32m"; o=1}
  $1=="working"{c="\033[34m"; o=2}
  {printf "%d\t%s\t%s\t%s● %-8s\033[0m %-40s %s:%s  %s\n", o, $3, $4, c, $1, $2, $3, $5, $6}' \
  | sort -n | cut -f2-)

choice=$(echo "$rows" | fzf --ansi --delimiter='\t' --with-nth=3 \
          --no-sort --prompt='agent> ' --height=100% --border=rounded) || return 0
```

**Row structure:** Internal order key (for sorting) + tab + session + tab + window id + tab + colored display
**fzf:** `--ansi --delimiter='\t' --with-nth=3 --no-sort --prompt='agent> ' --height=100% --border=rounded`

### cmd_sessions — Session Picker (bin/fleet:2990-3027)

```bash
# Row building (lines 2975-2983)
while IFS=$'\t' read -r name root; do
  cnt=$(printf '%s\n' "$tsv" | awk -F'\t' -v s="$name" '$3==s' | grep -c .)
  if [ "$name" = "$cur" ]; then
    mark=$'\033[32m●\033[0m'; tag=$'  \033[32m(current)\033[0m'
  else
    mark=" "; tag=""
  fi
  rows+=$(printf '%s\t%s %-18s %s  [%s agents]%s' "$name" "$mark" "$name" "$root" "$cnt" "$tag")$'\n'
done

# fzf invocation (lines 3022-3024)
choice=$(printf '%s\n' "$rows" | fzf --ansi --delimiter='\t' --with-nth=2 \
          --no-sort --layout=reverse --prompt='fleet session> ' \
          --height=100% --border=none) || return 0
```

**Row structure:** Session name + tab + colored display
**fzf:** `--ansi --delimiter='\t' --with-nth=2 --no-sort --layout=reverse --prompt='fleet session> ' --height=100% --border=none`

### Shared Conventions

| Element | Standard in Fleet | Example |
|---------|-------------------|---------|
| Color scheme | ANSI codes | `\033[32m` = green (active/running), `\033[31m` = red (blocked), `\033[34m` = blue (working) |
| Display bullet | Green/red/blue bullet | `\033[32m●\033[0m` (green bullet) |
| Reset code | ANSI reset | `\033[0m` ends color |
| Delimiter | Tab | `'\t'` (field separator for `--delimiter` and fzf column extraction) |
| Sort | Never sort | `--no-sort` preserves input order |
| Height | Full terminal | `--height=100%` |
| Border | Rounded (top-level) / None (nested) | `--border=rounded` for main pickers, `--border=none` for popups |
| Prompt | Descriptive | `project> `, `agent> `, `fleet session> ` |

---

## 5. INJECTION POINT: Adding "Create New Project"

### 5.1 Location for Row Injection

**File:** `/home/red/proj/pc-tune/fleet/main/bin/fleet`
**Function:** `cmd_pick_project`
**Line:** **After line 393** (end of the yml for loop, before fzf invocation)

### 5.2 Synthetic Row Injection

Insert after line 393 (after `done` closes the for loop):

```bash
  done
  
  # ===== NEW: Inject "create new project" entry =====
  rows+=$(printf '%s\t%s %-18s %s\n' \
    '__create_new__' \
    '\033[33m＋\033[0m create new project' \
    '[interactive setup]')$'\n'
  # ===== END NEW =====
  
  local choice
```

**Key Details:**
- **Sentinel value:** `__create_new__` — first field, safe from yml filename collisions
- **Display line:** Yellow plus sign + text (following fleet color conventions)
- **Ansi color:** `\033[33m` = yellow (distinct from green/red/blue status colors)
- **Formatting:** Matches existing row width for visual consistency

**Resulting row added to picker:**
```
__create_new__	＋ create new project  [interactive setup]
```

### 5.3 Selection Routing (bin/fleet:397-398)

Replace the current selection handler:

**Before:**
```bash
[ -n "$choice" ] || return 0
cmd_up "$(printf '%s' "$choice" | cut -f1)"
```

**After:**
```bash
[ -n "$choice" ] || return 0
local proj_name; proj_name="$(printf '%s' "$choice" | cut -f1)"

case "$proj_name" in
  __create_new__)
    cmd_new_project
    return 0
    ;;
esac

cmd_up "$proj_name"
```

**Logic:**
1. Extract field 1 from user's selection
2. Check if it's the sentinel value `__create_new__`
3. If yes: invoke `cmd_new_project` (new function) and exit
4. If no: proceed with normal `cmd_up` flow

---

## 6. New Function: cmd_new_project

### Location

Insert after `cmd_up` ends (around **line 3569**, after line 3568).

### Stub Implementation

```bash
cmd_new_project() {
  # Interactive project creation wizard.
  # 1. Prompt for project name (validated as safe filename)
  # 2. Prompt for root directory (must exist)
  # 3. Create yml file at $CONF_DIR/projects/<name>.yml
  # 4. Boot the project with cmd_up <name>
  #
  # On error, return to the picker or bail gracefully.
  
  echo "Creating new project..."
  # TODO: Full implementation
}
```

### Expected Behavior

When selected:
1. User prompted for project name (or uses directory basename)
2. User prompted for project root directory
3. Validation:
   - Name contains only `[a-zA-Z0-9_-]`
   - Directory path exists and is accessible
4. Create YAML file: `$CONF_DIR/projects/<name>.yml`
   - Minimal content: `name: <name>` and `root: <path>`
5. Call `cmd_up <name>` to boot the session
6. Or, on validation error, return to the picker for user to try again

---

## 7. YAML File Format & Storage

### Directory

```
~/.config/fleet/projects/
```

Environment variable: `$CONF_DIR/projects` (where `$CONF_DIR = ${XDG_CONFIG_HOME:-$HOME/.config}/fleet`)

### File Naming

```
$CONF_DIR/projects/<name>.yml
```

where `<name>` is the project's safe name (alphanumeric + `-` + `_`).

### Minimum YAML

```yaml
name: myproject
root: ~/path/to/project
```

### Optional Fields

```yaml
tmuxinator: true
```

(Enables tmuxinator layout integration on `fleet up`)

### Examples from Live Config

```yaml
# ~/.config/fleet/projects/pc.yml
name: pc
root: ~/proj/pc-tune
```

```yaml
# ~/.config/fleet/projects/techweb2.yml
name: techweb2
root: ~/work/rib/repos/techweb2.0
```

---

## 8. Summary: Key Anchors for Implementation

| Component | File | Line(s) | Purpose |
|-----------|------|---------|---------|
| **Dispatch (bare `fleet`)** | bin/fleet | 4132-4141 | Routes no args → cmd_pick_project (if tty) |
| **cmd_pick_project** | bin/fleet | 371-399 | Main picker function |
| **Row building** | bin/fleet | 384-393 | Loops over yml files, formats display |
| **fzf invocation** | bin/fleet | 395-396 | Launches picker with `--ansi --delimiter='\t' --with-nth=2 ...` |
| **Selection routing** | bin/fleet | 397-399 | Extracts name, routes to cmd_up (or new sentinel handler) |
| **cmd_up** | bin/fleet | 3455-3568 | Reads yml, resolves root, creates tmux session |
| **YAML reading** | bin/fleet | 3471-3478 | Parses `root:`, optional `tmuxinator:` field |
| **CONF_DIR** | bin/fleet | 18 | `~/.config/fleet` |
| **Projects directory** | bin/fleet | 374 | `$CONF_DIR/projects/*.yml` |
| **Injection point** | bin/fleet | 393 | End of yml loop; inject synthetic row before fzf |
| **Sentinel routing** | bin/fleet | 397-398 | Check if selected name == `__create_new__` |
| **cmd_new_project** | bin/fleet | ~3569 | New function to be implemented |

---

## 9. Implementation Checklist

- [ ] **Step 1: Inject synthetic row**
  - [ ] Modify `cmd_pick_project` at line 393
  - [ ] Add rows entry with sentinel `__create_new__`
  - [ ] Use yellow color `\033[33m` for visual distinctness

- [ ] **Step 2: Route sentinel value**
  - [ ] Wrap lines 397-399 selection handler
  - [ ] Add `case` statement checking for `__create_new__`
  - [ ] Call `cmd_new_project` on match

- [ ] **Step 3: Implement cmd_new_project**
  - [ ] Insert new function after cmd_up (line 3569)
  - [ ] Interactive prompts: name, directory
  - [ ] Validation: safe name, directory exists
  - [ ] Create yml file in `$CONF_DIR/projects/<name>.yml`
  - [ ] Call `cmd_up <name>` to boot
  - [ ] Error handling: gracefully return or re-prompt

- [ ] **Step 4: Test end-to-end**
  - [ ] Run `fleet` (bare, no args) at terminal
  - [ ] Verify new "create" row appears in picker
  - [ ] Select it
  - [ ] Complete interactive setup
  - [ ] Verify session boots correctly
  - [ ] Verify yml file created with correct fields

---

## 10. Code References

**Three related pickers for reference:**

1. **cmd_pick** (lines 347–369) — agent picker, uses similar `--delimiter` + `--with-nth` pattern
2. **cmd_sessions** (lines 2990–3027) — session picker, row format template
3. **cmd_pick_project** (lines 371–399) — **target picker, where modification happens**

All follow the same visual conventions (ANSI colors, tab-delimited rows, fzf styling).

