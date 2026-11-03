# Installing on Windows

Everything that tripped us up during a real deployment, in the order it appeared.
Environment: native Windows 10/11, Git Bash, Claude Code CLI 2.1.303.

Read this before reaching for `install.sh` on Windows — several failures here are
silent, and the symptom does not point at the cause.

## Prerequisites

| Tool | Why | Where it must be visible |
| - | - | - |
| Git for Windows | Claude Code runs `statusLine` and hook commands through Git Bash | `D:\Program Files\Git` (or wherever you installed it) |
| `jq` | HARD dependency of the status line; it parses the payload | **Inside Git Bash's PATH**, not just Windows' |
| Node.js 20+ | Builds the MCP server; runs the hook | Windows PATH is fine |
| Python 3 | Optional — cost estimate and output rate | Must be the real interpreter, not the Store stub |

## The four failures you are most likely to hit

### 1. `npm run build` says `'rm' is not recognized`

```
> tsc && rm -rf dist/data && cp -r src/data dist/data
'rm' is not recognized as an internal or external command
```

npm runs `scripts` through **`cmd.exe` on Windows**, no matter which shell started
it — Git Bash makes no difference. Fixed in the repo by moving the copy into
`scripts/copy-data.js`, so on current `main` this should not happen. If you see it
on an older checkout, `git pull`.

### 2. The status line renders but every field is empty

```
⬡  │  │ [----------] 0% 0/0 │ $0.0000
```

This is almost always **`jq` not visible to Git Bash**. The script still runs, so
there is no error — `parse_status` fails, the payload falls back to defaults, and
a blank-looking bar is drawn.

Installing with `winget install jqlang.jq` succeeded on our machine and still left
Git Bash unable to find it: the file landed under
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\jqlang.jq_...\jq.exe` and Windows' user
PATH listed that directory, yet `command -v jq` inside Git Bash failed. The fix
that worked was to also place it in Git's own bin directory:

```powershell
$src = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe\jq.exe"
Copy-Item -LiteralPath $src -Destination "D:\Program Files\Git\usr\bin\jq.exe" -Force
```

Then `jq --version` in a fresh Git Bash window should print `jq-1.8.2`.

**Reinstalling Git for Windows deletes that file** — copy it again afterwards.

> We could not establish exactly why Git Bash missed the WinGet directory on this
> machine; treat the path above as the workaround that was verified, not as a
> general rule about how Git Bash assembles PATH.

### 3. `pet-hook.sh` fails with `$'\r': command not found`

A CRLF line ending in a shell script. The hook still exits 0, so Claude Code shows
no error — prompts just silently stop scoring.

`.gitattributes` now pins these files to LF, but a checkout made *before* that
landed keeps its CRLF. Re-expand it:

```bash
cd /e/local-ai/claude/claudePet
git checkout -- .
```

Verify first that nothing is actually lost — CRLF-only differences show up as a
tree full of modified files, and this will prove they are empty:

```bash
git diff --ignore-cr-at-eol --stat    # no output means only line endings differ
```

### 4. `./install.sh` will not run

Three different causes look alike:

- **You are in PowerShell or CMD.** `install.sh` is bash. Open Git Bash from the
  Start menu, or call it explicitly:
  ```powershell
  & "D:\Program Files\Git\bin\bash.exe" -lc "cd /e/local-ai/claude/claudePet && ./install.sh"
  ```
  `-l` matters: it reloads the environment so the script can find `node`, `npm`, `jq`.
- **PowerShell 5.1 rejects `&&`.** It arrived in PowerShell 7. Run the commands on
  separate lines.
- **`which` is not a PowerShell command.** Use `Get-Command` there.

## What to check after installing

1. **Paths in `settings.json`** must be drive-letter form with forward slashes —
   `E:/local-ai/claude/claudePet/scripts/pet-statusline.sh`. A `/e/...` (MSYS) path
   works when Git Bash runs the command but not if Claude Code falls back to
   PowerShell.
2. **Look for `copied instead` in the installer output.** Symlinks need Developer
   Mode or elevation on Windows; without it the installer falls back to a junction
   and then to a copy. Copies work but stop tracking the checkout, so re-run
   `./install.sh` after updating the repo.
3. **Restart Claude Code once.** Changing `statusLine.command` takes effect
   immediately, but the MCP server is only connected at session start.

## Why these are easy to miss

Every failure above is of one shape: **it looks like success.** The script runs,
exits 0, prints something plausible.

- a missing `jq` renders a bar with default values instead of an error
- `/dev/stdin` failing inside the hook is caught and returns an empty prompt
- the Microsoft Store `python3` answers `command -v`, prints "Python was not
  found", and exits 0

So verify by effect — a file that was written, a field that has a value — rather
than by the absence of complaints. That is also how the tests for this area are
written.

## A configuration that worked

```
Git for Windows  D:\Program Files\Git
jq               D:\Program Files\Git\usr\bin\jq.exe
checkout         E:\local-ai\claude\claudePet
settings.json    C:\Users\<you>\.claude\settings.json
statusLine       E:/local-ai/claude/claudePet/scripts/pet-statusline.sh
hook             E:/local-ai/claude/claudePet/scripts/pet-hook.cmd
```
