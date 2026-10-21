#!/usr/bin/env python3
"""
ensure_plugins — SessionStart hook that provisions this repository's declared
Claude plugins from its own committed `.claude/settings.json`.

Wired by the committed `.claude/settings.json` as this repository's plugin
mechanism; AGENTS.md is its documentation and the
`livespecPluginCurrencySuccessor` declaration in the same file points there.

Why a hook and not the canonical fleet form: the fleet's SessionStart step is
`mise exec -- just ensure-plugins`, which shells into a shared Python module
from `livespec-dev-tooling`. This repository carries no mise/just/lefthook
stack and no fleet Python dependency, so the mechanism is re-expressed here
as a stdlib-only hook.

Why settings-derived rather than an inline list of plugin names: a literal
list has to be edited by hand every time the enabled set changes, and a
`settings.json` entry added without that paired edit is silently never
provisioned. `.claude/settings.json` is the single source of truth for what
this repository expects, so the command set is derived from it.

Why `marketplace add` and `install`, not `update` alone: `plugin update` on a
plugin that was never installed does nothing at all, so an update-only
mechanism can keep an already-installed set current but can never provision a
NEWLY declared plugin. Adding a marketplace entry to `settings.json` is a
DECLARATION; the install is what makes the plugin's skills resolve in a
session. `marketplace update` still runs first, so the catalogs are fresh
before anything resolves against them.

This is a HARNESS concern only. It provisions the operator's Claude Code
plugin surface and is not a discovery input for any plugin's own runtime.

Fail-open contract: ANY failure — absent or malformed settings, a missing
`claude` CLI, a non-zero command — is a pass with exit 0. A session must never
be wedged because provisioning could not complete, and a single failing
command must not abort the commands after it. `main()` owns the filesystem and
subprocess boundary and does no work at import time, so the body is
unit-testable in-process.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Protocol, cast


class CommandRunner(Protocol):
    """Callable seam for command execution, so tests need no subprocess."""

    def __call__(self, *, args: tuple[str, ...], cwd: str | None = None) -> int: ...


def _as_object_dict(value: object) -> dict[str, object] | None:
    """Narrow an arbitrary JSON value to a string-keyed dict, else None."""
    if isinstance(value, dict):
        return cast("dict[str, object]", value)
    return None


def _marketplace_target(*, entry: object) -> str | None:
    """The `<owner>/<repo>@<ref>` target for one marketplace entry.

    `repo` and `ref` live under the entry's nested `source` object, NOT at the
    entry's top level. A top-level read returns None for every fleet-shaped
    entry, which reads as "nothing pins a ref" and is exactly backwards.
    """
    record = _as_object_dict(entry)
    source = _as_object_dict(record.get("source")) if record is not None else None
    if source is None or source.get("source") != "github":
        return None
    repo = source.get("repo")
    ref = source.get("ref")
    if not isinstance(repo, str) or not isinstance(ref, str) or not repo or not ref:
        return None
    return f"{repo}@{ref}"


def _enabled_plugin_names(*, raw: object) -> tuple[str, ...]:
    """Plugin ids this repository declares as enabled.

    Accepts the object form (`{"<plugin>@<marketplace>": true}`) that this
    repository uses, and tolerates a list form so a future settings shape does
    not silently provision nothing.
    """
    if isinstance(raw, list):
        return tuple(name for name in cast("list[object]", raw) if isinstance(name, str))
    mapping = _as_object_dict(raw)
    if mapping is None:
        return ()
    return tuple(name for name, value in mapping.items() if value is True)


def planned_commands(*, settings_text: str) -> tuple[tuple[str, ...], ...]:
    """The Claude CLI commands derived from a `.claude/settings.json` body.

    Returns an empty tuple for anything unparsable, so a malformed settings
    file provisions nothing rather than raising into session start.
    """
    try:
        parsed = json.loads(settings_text)
    except (TypeError, ValueError):
        return ()
    settings = _as_object_dict(parsed)
    if settings is None:
        return ()
    commands: list[tuple[str, ...]] = [
        ("claude", "plugin", "marketplace", "update"),
    ]
    marketplaces = _as_object_dict(settings.get("extraKnownMarketplaces"))
    if marketplaces is not None:
        for entry in marketplaces.values():
            target = _marketplace_target(entry=entry)
            if target is not None:
                commands.append(("claude", "plugin", "marketplace", "add", target))
    for plugin in _enabled_plugin_names(raw=settings.get("enabledPlugins")):
        commands.append(("claude", "plugin", "install", plugin, "-s", "project"))
        commands.append(("claude", "plugin", "update", plugin, "-s", "project"))
    return tuple(commands)


def provision(
    *, settings_text: str | None, runner: CommandRunner, project_dir: str
) -> int:
    """Run every planned command in `project_dir`, ignoring failures.

    Always returns 0. Every command is attempted even after one fails: the
    commands are independent, and stopping at the first failure would let one
    unreachable marketplace prevent every other plugin from provisioning.

    `project_dir` is passed as each command's cwd rather than inherited.
    `claude plugin install … -s project` resolves "project" from the PROCESS
    CWD and ignores `CLAUDE_PROJECT_DIR`, so a run from anywhere else exits 0
    having recorded the install against the wrong project, or none at all.
    """
    if settings_text is None:
        return 0
    for command in planned_commands(settings_text=settings_text):
        try:
            _ = runner(args=command, cwd=project_dir)
        except Exception:  # noqa: BLE001 — fail-open by contract
            continue
    return 0


def _subprocess_runner(*, args: tuple[str, ...], cwd: str | None = None) -> int:
    """Run one command, discarding its output so session start stays quiet."""
    completed = subprocess.run(  # noqa: S603 — fixed argv, no shell
        list(args),
        check=False,
        cwd=cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return completed.returncode


def _project_dir() -> str:
    """This repository's root.

    `CLAUDE_PROJECT_DIR` when the harness supplies it, else the hook file's
    own grandparent — which is this repository by construction, so the hook
    stays correct when run by hand.
    """
    return os.environ.get("CLAUDE_PROJECT_DIR") or str(Path(__file__).resolve().parents[2])


def _settings_text(*, project_dir: str) -> str | None:
    """This repository's committed settings body, or None when unreadable."""
    try:
        return (Path(project_dir) / ".claude" / "settings.json").read_text(
            encoding="utf-8"
        )
    except OSError:
        return None


def main() -> int:
    """Hook entry point: provision from committed settings; always exit 0."""
    try:
        project_dir = _project_dir()
        return provision(
            settings_text=_settings_text(project_dir=project_dir),
            runner=_subprocess_runner,
            project_dir=project_dir,
        )
    except Exception:  # noqa: BLE001 — fail-open by contract
        return 0


if __name__ == "__main__":
    sys.exit(main())
