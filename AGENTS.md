# AGENTS.md

Instructions for any agent working in this repo.

## Commit and push your work

When a change is finished and verified, commit and push it. Don't leave work
sitting in the working tree waiting to be asked about.

- One commit per coherent change, on `main`, pushed to `origin`.
- Run `install.sh` and check the widget actually loads before committing a
  change to `oculus/` — see the Debugging section of the README, especially
  that the shell keeps running a cached copy until `omarchy restart shell`.
- Don't commit the installed copy under `~/.config/omarchy/plugins/`, local
  scratch files, or anything under `~/.config/oculus/`.

## Write a clean, minimal message

**Title** — one line, imperative mood, under ~60 characters, no trailing
period. An optional `scope:` prefix when it helps (`README:`, `0.4:`). It
says what the change does, not what you did:

```
Centre the bar mark on its slot
README: install from GitHub with lazy.nvim
```

**Description** — usually none. A one-line title that fully explains itself
is a finished commit message; adding a body to restate it is noise.

Write a body only when something is genuinely not obvious from the diff:
why the change was needed, a constraint that forced the approach, or a
behaviour change a reader would otherwise be surprised by. Then keep it to a
few wrapped lines of prose.

Don't:

- bullet the diff back, file by file
- narrate the process, the testing, or what you tried first
- restate the title in longer words
- pad with "Also", "Additionally", "Note that"

End the message with the `Co-Authored-By:` trailer your harness specifies.
