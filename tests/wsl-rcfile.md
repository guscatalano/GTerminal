# WSL shell integration, tested on a real distro

Item 12 gives a WSL tab the same prompt marks a PowerShell or cmd tab
has — `133;A` before the prompt, `9;9` with the folder, `133;B` where
typing starts, `133;D;<code>` when a command finishes — so command
blocks, jump-to-failure and the finish notification work there too. This
note records how that was tested against a real WSL2 Ubuntu, because the
machine GTerminal is built on has no WSL, and the first attempt was
wrong in a way only a distro could reveal.

## The bug: BASH_ENV is not read by interactive bash

The first implementation put the hook on through `BASH_ENV` — a file
bash sources at startup — forwarded across the boundary with
`WSLENV=BASH_ENV/p`. That is the natural mirror of the PowerShell hook,
and it emits nothing. **`BASH_ENV` is consulted only by *non-interactive*
bash.** An interactive shell (`bash -i`, which is what a terminal opens)
reads `~/.bashrc` and ignores `BASH_ENV` entirely. So every mark was
absent; a WSL tab had none of the integration the code claimed.

A faithful test — interactive bash under a real pty, the condition
ConPTY provides — confirmed it. All marks false:

```
RESULT-BASH_ENV
  reported cwd (9;9)   : False
  prompt start (133;A) : False
  input start  (133;B) : False
  block done   (133;D) : False
```

## The fix: bash --rcfile, sourcing the user's rc first

`bash --rcfile <file> -i` reads `<file>` instead of `~/.bashrc`. So the
file sources the user's own `~/.bashrc` first — untouched — then appends
the marks. This is the same "wrap, do not replace" the PowerShell hook
does. The rcfile GTerminal writes (`wsl_rc()` in `src-tauri/src/mux.rs`):

```bash
[ -f ~/.bashrc ] && source ~/.bashrc
__gt_prompt() { printf '\033]133;D;%s\007\033]133;A\007\033]9;9;%s\007' "$?" "$PWD"; }
PROMPT_COMMAND="__gt_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
PS1="${PS1}\[\033]133;B\007\]"
```

It is delivered *by value*, not by a shared path: `wsl_boot()` base64s it
(base64 has no shell-special bytes) and the launch is

```
wsl.exe -- bash -c 'printf %s <base64> | base64 -d > "$HOME/.gterminal-rc" && exec bash --rcfile "$HOME/.gterminal-rc" -i'
```

so no distro has to be named and no Windows→WSL path has to be
translated. `cargo test wsl_boot` decodes that embedded base64 and
asserts the rcfile is intact, that the launch uses `--rcfile` and never
`BASH_ENV`, and that the base64 encoder matches the RFC vectors — a
regression guard that runs on CI with no WSL present.

## Proof on the real distro

Run under interactive bash on a real WSL2 Ubuntu, planting a non-trivial
`~/.bashrc` (`export PROMPT_COMMAND='history -a'; PS1='myprompt$ '`)
first — the case the marks must survive rather than clobber:

```
RESULT-RCFILE / RESULT-BOOTSTRAP
  reported cwd (9;9)   : True
  prompt start (133;A) : True
  input start  (133;B) : True
  block done   (133;D) : True
  exit code carried    : True
  custom PS1 kept      : True
  command echoed+ran   : True
```

Every mark arrives, the exit code rides with the `D` (which cmd's prompt
cannot manage — it has no escape for `$?`), and the user's own `PS1` and
`PROMPT_COMMAND` are still there. The reported folder is the Linux path
(e.g. `/mnt/c/...`), which is where the shell actually is; a Windows-side
reader that wants `\\wsl$\...` can translate, and the daemon does not
guess.

## Reproducing

The test provisions a throwaway Windows VM, enables WSL2, installs
Ubuntu, and exercises the mechanism under a real pty. To re-run by hand
on any box that already has WSL:

```bash
# Plant a custom rc, then run the exact launch the daemon uses and look
# for the marks. `cat -v` renders ESC as ^[ so the marks are visible.
printf "export PROMPT_COMMAND='history -a'\nPS1='myprompt$ '\n" > ~/.bashrc
cat > /tmp/gt-rc <<'RC'
[ -f ~/.bashrc ] && source ~/.bashrc
__gt_prompt() { printf '\033]133;D;%s\007\033]133;A\007\033]9;9;%s\007' "$?" "$PWD"; }
PROMPT_COMMAND="__gt_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
PS1="${PS1}\[\033]133;B\007\]"
RC
# Under a real terminal, `bash --rcfile /tmp/gt-rc -i` then run a command;
# the bytes 133;A / 9;9 / 133;B / 133;D;0 appear around the prompt.
```

The equivalent question for PowerShell — does the hook survive a custom
profile — is answered by `tests/prompt.ps1`. This file is the WSL half.
