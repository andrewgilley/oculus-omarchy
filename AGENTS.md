# AGENTS.md

Instructions for any agent working in this repo.

## Commit and push your work

When a change is finished and verified, commit it to `main` and push it to
`origin`. Don't leave finished work sitting in the working tree waiting to be
asked about. Keep each commit to one coherent change.

Before committing anything under `oculus/`, run `install.sh` and confirm the
widget actually loads. The shell keeps running a cached copy of the old widget
until `omarchy restart shell`, so a change that looks applied often isn't; the
Debugging section of the README has the details. Never commit the installed
copy under `~/.config/omarchy/plugins/`, local scratch files, or anything from
`~/.config/oculus/`.

## Write a clean, minimal message

The title is one line in the imperative mood, under about sixty characters,
with no trailing period and an optional `scope:` prefix where it helps. It
says what the change does rather than what you did, like `Centre the bar mark
on its slot` or `README: install from GitHub with lazy.nvim`.

Usually there is no description at all. A title that explains itself is a
finished commit message, and adding a body to restate it is noise. Write one
only when something genuinely isn't obvious from the diff — why the change was
needed, a constraint that forced the approach, or a behaviour change a reader
would otherwise find surprising — and then keep it to a few wrapped lines of
plain prose.

Don't bullet the diff back file by file, don't narrate the process or the
testing or what you tried first, and don't pad the message out with words that
carry nothing. End it with the `Co-Authored-By:` trailer your harness
specifies.
