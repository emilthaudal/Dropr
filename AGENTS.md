# AGENTS.md — Dropr Coding Agent Guide

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

---

## Project Overview

**Dropr** is a World of Warcraft addon written in **Lua 5.1** targeting Interface `120000`
(The War Within / early Midnight). It displays your Raidbots droptimizer top-3 item
recommendations automatically when you zone into an M+ dungeon.

**Companion web tool:** `dropr-web` (separate repo) — a Next.js app that fetches a
Raidbots droptimizer report and generates a base64-encoded JSON import string for this addon.

---

## Architecture

```
Init.lua    — DroprDB SavedVariables schema, constants, DroprPrint helper
Core.lua    — Slash commands (/dropr import|clear|show), base64+JSON import decode,
              ADDON_LOADED/PLAYER_ENTERING_WORLD/ZONE_CHANGED_NEW_AREA event handling,
              stale data check (fires AF.ShowNotificationPopup if > DROPR_OUTDATED_DAYS old)
UI.lua      — AbstractFramework frame: AF.CreateHeaderedFrame + 3 item rows + AF.CreateMover
Libs/       — Empty at commit time; BigWigs packager fetches externals at release:
                AbstractFramework (github.com/enderneko/AbstractFramework)
                json.lua (github.com/rxi/json.lua)
```

---

## Import String Format

The web tool produces: `btoa(JSON.stringify(payload))` where payload is:

```json
{
  "char": "Jetskis",
  "spec": "unholy",
  "importedAt": 1234567890,
  "dungeons": {
    "1315": {
      "name": "Maisara Caverns",
      "items": [
        { "id": 251168, "name": "Liferipper's Cutlass", "slot": "main_hand",
          "dpsGain": 2788, "boss": "Rak'tul, Vessel of Souls", "icon": "inv_..." }
      ]
    }
  }
}
```

In Core.lua: base64-decode the string → `json.decode()` (rxi/json.lua) → write to `DroprDB`.

---

## Build & Release

There is **no local build step**. The release pipeline is fully CI-driven:

- Releases are triggered by pushing a git tag (any tag pattern `**`)
- `.github/workflows/release.yml` runs `BigWigsMods/packager@v2`
- The packager fetches externals declared in `.pkgmeta`, zips the addon, and publishes
  to CurseForge, Wago.io, and GitHub Releases

To cut a release: `git tag v1.0.0 && git push origin v1.0.0`

---

## Testing

**No automated test framework.** WoW addon testing is done live in-game.

Workflow:
1. Copy the Dropr folder to `<WoW>/Interface/AddOns/Dropr/` (or symlink it)
2. Manually copy AbstractFramework and json.lua into `Libs/` for local dev
3. In-game: `/reload` to reload all addon code
4. Use `print(...)` or `DEFAULT_CHAT_FRAME:AddMessage(...)` for debug output
5. Lua errors appear as in-game error dialogs with stack traces

---

## WoW Lua Constraints

- **No HTTP requests** — WoW Lua sandbox has zero networking capability
- **No `require`** — all files loaded sequentially by WoW client per `.toc` order
- **No standard Lua libs** — `io`, `os`, `package`, `debug`, `utf8` do not exist
- **Lua 5.1** — no `goto`, no integer division `//`, no bitwise operators (use `bit` lib)
- **No `error()` or `assert()`** — these cause disruptive in-game error dialogs; use guards + `pcall`
- **AbstractFramework** — access via `_G.AbstractFramework` (global set by the library)
- **json.lua** — access via `_G.json` (global set by rxi/json.lua)

---

## Naming Conventions

| Construct               | Convention        | Example                          |
| ----------------------- | ----------------- | -------------------------------- |
| Globals / SavedVars     | `PascalCase`      | `DroprDB`, `DroprUI`             |
| Constants               | `UPPER_SNAKE_CASE`| `DROPR_OUTDATED_DAYS`            |
| Local functions         | `PascalCase`      | `CreateItemRow()`, `CheckStale()`|
| Local variables         | `camelCase`       | `dungeonId`, `itemRows`          |
| WoW frame locals        | `PascalCase`      | `Frame`, `DungeonLabel`          |

---

## Error Handling

- Guard all event handlers with nil checks at the top
- Use `pcall` for any WoW API call that may fail
- Never use `error()` or `assert()` — prefer silent/graceful failure
- Use `DroprPrint(msg)` for user-facing non-fatal warnings

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:full hash:f65d5d33 -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Dolt-powered version control with native sync
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Quality
- Use `--acceptance` and `--design` fields when creating issues
- Use `--validate` to check description completeness

### Lifecycle
- `bd defer <id>` / `bd supersede <id>` for issue management
- `bd stale` / `bd orphans` / `bd lint` for hygiene
- `bd human <id>` to flag for human decisions
- `bd formula list` / `bd mol pour <name>` for structured workflows

### Auto-Sync

bd automatically syncs via Dolt:

- Each write auto-commits to Dolt history
- Use `bd dolt push`/`bd dolt pull` for remote sync
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- END BEADS INTEGRATION -->
