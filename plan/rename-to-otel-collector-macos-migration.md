# macOS migration — `claude-collector` → `otel-collector`

**Run this on the Mac, on the first session that sees it.** It migrates the
**macOS local collector** deployment to the new name. The VPS-side rename
(systemd unit, `/data/projects` dir, GitHub repo) is handled separately by
a VPS session — you do **not** do that here.

## What changed and why

The repo was renamed `claude-collector` → `otel-collector` because it is
functionally the host's shared OTel collector, of which the Claude-Code
Agentic-Timeline shaping is just one processor. On macOS this repo also runs
a **local** collector (`config.macos.yaml`, via a launchd LaunchAgent) that
shapes local Claude Code / Codex telemetry and forwards it to Honeycomb.

The rename touched two things on the macOS side:

1. **The launchd label** `com.thewoolleyweb.claude-collector` →
   `com.thewoolleyweb.otel-collector` — in the plist filename
   (`launchd/com.thewoolleyweb.otel-collector.plist.example`) and in
   `scripts/install-macos-launchagent.sh` / `uninstall-macos-launchagent.sh`
   / `smoke-test-macos-collector.sh`.
2. **The repo/dir name** (optional to mirror locally — see step 3).

**Not changed:** the Mac-local marker attribute stays
`collector.agent-activity-local` (it lives in `config.macos.yaml`, which is
a *separate* config from the VPS `config.yaml` and was deliberately left
alone). So Honeycomb data from this Mac keeps the same marker — this
migration is about the **LaunchAgent label + repo name**, not the telemetry
shape.

Because the label changed, the **old** LaunchAgent
(`com.thewoolleyweb.claude-collector`) is still loaded and the *renamed*
uninstall script only knows the *new* label — so you must unload the old one
explicitly (step 2).

## Preconditions

- You are on the macOS clone of this repo (historically
  `~/workspace/claude-collector`).
- `.env.local` exists at the repo root (gitignored; holds
  `HONEYCOMB_API_KEY`, optional `HONEYCOMB_API_ENDPOINT`). If missing, the
  install/run/smoke scripts exit with "Missing …/.env.local".
- `otelcol-contrib` is on `PATH` or at `~/.local/bin/otelcol-contrib`.

## Steps

**1. Get the renamed files.** If the GitHub repo has been renamed, the old
remote URL still redirects, but update it for cleanliness (leave the
`upstream` → jessitron remote alone):

```bash
git remote set-url origin https://github.com/thewoolleyman/otel-collector.git   # only if/after the GitHub repo is renamed
git checkout main && git pull --ff-only
```

**2. Unload + remove the OLD LaunchAgent (old label).** Do this explicitly —
the renamed `uninstall-macos-launchagent.sh` targets the NEW label and will
not find the old one:

```bash
launchctl bootout "gui/$(id -u)/com.thewoolleyweb.claude-collector" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.thewoolleyweb.claude-collector.plist"
```

**3. (Optional, for consistency) rename the local clone dir.** The installed
plist embeds the repo root path (`__REPO_ROOT__` is substituted at install
time), so if you move the clone you MUST reinstall (step 4) afterward:

```bash
cd ~/workspace && mv claude-collector otel-collector && cd otel-collector
```

If you skip the dir rename, just `cd` to your existing clone.

**4. Install the NEW LaunchAgent** (new label + new plist filename;
re-substitutes the current repo root):

```bash
./scripts/install-macos-launchagent.sh
```

**5. Smoke-test:**

```bash
./scripts/smoke-test-macos-collector.sh
```

This validates `config.macos.yaml`, confirms the LaunchAgent is loaded under
the **new** label, checks the collector is listening on 4317/4318/8888, and
prints receiver/exporter/uptime metrics.

**6. Verify in Honeycomb.** New telemetry from this Mac should continue to
land with `collector.agent-activity-local = "washere"` (marker unchanged).
Confirm fresh data is arriving in the destination environment.

## Cleanup (do this once step 5–6 pass)

The migration is complete only after the collector is **running and
smoke-tested under the new label on this Mac**. Then:

1. Delete the "PENDING macOS RENAME MIGRATION" reminder from **`AGENTS.md`**
   (its first line) AND the mirrored one-line pointer at the top of
   **`CLAUDE.md`**.
2. Archive this plan: `git mv plan/rename-to-otel-collector-macos-migration.md
   plan/archive/` (create `plan/archive/` if needed), or delete it.
3. Commit (`docs:` / plain-imperative subject per this repo's convention).

## Rollback

If the new LaunchAgent misbehaves, reinstate the old one from git history:
`git show <pre-rename-sha>:launchd/com.thewoolleyweb.claude-collector.plist.example`
plus the old-label scripts, then re-run the old install. The pre-rename SHA
is the parent of the commit that introduced this file.
