# Fleet Project Persistence — Full Architecture Map

## 1. CONF_DIR Definition

File: /home/red/proj/pc-tune/fleet/main/bin/fleet
Line: 18

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleet"

The configuration directory is ~/.config/fleet/ (or $XDG_CONFIG_HOME/fleet/ if set).

---

## 2. ~/.config/fleet/ Directory Layout

~/.config/fleet/
├── guard-on                    # marker file (0 bytes) — write-guard feature enabled
├── keybinds.conf              # runtime key bindings (action=key pairs)
├── profiles                   # (optional) Claude profile paths (newline-separated)
├── projects/                  # saved project definitions (yml files per project)
│   ├── pc.yml                 # sample project
│   ├── techweb2.yml           # sample project
│   └── webshop.yml            # sample project
└── sessions/                  # per-session agent persistence
    ├── pc.agents              # agents in session 'pc' (empty)
    ├── pc-tune.agents         # agents in session 'pc-tune'
    └── <session>.agents       # one file per session

---

## 3. Project YAML Schema — cmd_save() Implementation

File: /home/red/proj/pc-tune/fleet/main/bin/fleet
Function: cmd_save() at lines 3570–3593

EXACT YAML TEMPLATE:

name: <project-name>
root: <project-root-path>

Optional field:

tmuxinator: true|yes|1    # opt-in to tmuxinator layout (defaults to false/absent)

---

## 4. Real examples from ~/.config/fleet/projects/

File: ~/.config/fleet/projects/pc.yml
name: pc
root: ~/proj/pc-tune

File: ~/.config/fleet/projects/techweb2.yml
name: techweb2
root: ~/work/rib/repos/techweb2.0

File: ~/.config/fleet/projects/webshop.yml
name: webshop
root: ~/proj/webshop

---

## 5. How cmd_save writes (lines 3570–3593)

cmd_save() { # save [name]
  # Reads @fleet_root from current tmux session (or $PWD fallback)
  # Derives project name from session name or root basename
  # Sanitizes name to [a-zA-Z0-9_-] only
  # Contracts $HOME → ~ for portability
  # Writes to $CONF_DIR/projects/$name.yml with exactly two fields:
  local rootc="${root/#$HOME/\~}"
  printf 'name: %s\nroot: %s\n' "$name" "$rootc" > "$yml"
}

Line 3590 is the actual write. That's it — two fields, YAML format, done.

---

## 6. How cmd_pick_project reads (lines 371–399)

Scans $CONF_DIR/projects/*.yml
Extracts project name from filename (basename <name>.yml)
Extracts root: field using awk -F': *' '$1=="root"{print $2; exit}'
Checks if tmux has-session -t "=$name" (to mark running projects)
Displays: <name> <root> [(running)] in fzf picker
User selects → calls cmd_up with the project name

No special field requirement — only name and root are used by cmd_up.

---

## 7. How cmd_up loads projects (lines 3469–3484)

if [ -f "$CONF_DIR/projects/$arg.yml" ]; then
  root=$(awk -F': *' '$1=="root"{print $2; exit}' "$yml")
  root="${root/#\~/$HOME}"      # expand ~ back to $HOME
  case "$(awk -F': *' '$1=="tmuxinator"{print $2; exit}' "$yml")" in
    true|yes|1) tmuxinator=1 ;;
  esac
fi

Reads root: field (required)
Reads tmuxinator: field (optional, enables layout auto-start)
Falls back to $PWD if root missing

NO SESSION REQUIRED to read/boot a project — cmd_up runs standalone.

---

## 8. Session agent persistence

Location: ~/.config/fleet/sessions/<session>.agents
Format: Tab-separated, 7 fields per agent

<dir><TAB><repo><TAB><branch><TAB><bare><TAB><base><TAB><harness><TAB><self_merge>

Real example (pc-tune.agents):
/home/red/proj/pc-tune/tmux/chezmoi-collision	tmux	chezmoi-collision	1		claude	0
/home/red/proj/pc-tune/fleet/reconcile-config-guardrails	fleet	reconcile-config-guardrails	0	main	claude	0

Lines are written by persist_agent() (line 454) when cmd_new spawns an agent.
Lines are removed by cmd_forget() (line 461) when an agent window closes.

This is session-specific, independent of projects/. Different projects have
separate agent history files.

---

## 9. Minimum fields for a standalone new project

ANSWER: YES, can be written standalone without a tmux session.

MINIMUM VALID YAML:

name: myproject
root: ~/my/project/root

That's all cmd_up needs. It does not require:
- Existing tmux session
- Agent history (sessions/ file)
- Guard markers or keybinds

STANDALONE WORKFLOW:

mkdir -p ~/.config/fleet/projects
cat > ~/.config/fleet/projects/myproject.yml << 'EOF'
name: myproject
root: ~/my/project/root
EOF

fleet up myproject                    # boots session directly
# OR:
fleet                                 # brings up picker, myproject appears

No session pre-requisite. cmd_up creates a fresh session on demand.

---

## 10. CONF_DIR path and project yml exact fields

CONF_DIR: ${XDG_CONFIG_HOME:-$HOME/.config}/fleet
Default: ~/.config/fleet/

Project YAML exact fields (from cmd_save line 3590):
  name: <sanitized-name>
  root: <path-with-tilde>
  
Optional:
  tmuxinator: true|yes|1

Minimum for standalone: name and root. That's it.

cmd_save writes it when you run 'fleet save <name>' INSIDE a fleet session.
cmd_up reads it when you run 'fleet up <name>' from anywhere (no session needed).
cmd_pick_project displays all projects in ~/.config/fleet/projects/*.yml via fzf.

A new project needs just the two-field yml on disk to register. No session
required. Next time you run 'fleet', it appears in the picker and can be launched
with 'fleet up <name>'.

