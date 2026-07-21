#!/usr/bin/env python3
# Run argv[1:] under a pseudo-tty so the child sees `[ -t 0 ] && [ -t 1 ]` true.
# Child stdout is copied to our real stdout (capturable). Used to drive the
# fzf `--pick` path non-interactively (paired with FZF_DEFAULT_OPTS=--filter=...).
import os, pty, sys
status = pty.spawn(sys.argv[1:])
sys.exit(os.waitstatus_to_exitcode(status))
