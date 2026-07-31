# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`srvctl` is a CLI-only, security-hardened server management tool written entirely in **Bash**, targeting **Ubuntu 22.04 LTS** running as root (PHP-FPM, Nginx, MariaDB, Redis). It provisions per-domain isolation (separate Linux user, chroot, AppArmor, FPM pool, DB/Redis ACLs) plus server-wide hardening (ModSecurity WAF, seccomp, cgroups v2, AIDE, ClamAV). See [README.md](README.md) for the full command/security-layer reference.

There is **no build step, no test suite, and no CI/lint tooling**. `shellcheck` directives appear inline (`# shellcheck disable=...`) but nothing enforces them. The tool cannot meaningfully run on the macOS dev machine — it expects a root Ubuntu host with systemd, nginx, php-fpm, etc.

## Repo layout vs. runtime layout (important)

The repository is the **source**, not the install. [install.sh](install.sh) copies `bin/`, `lib/`, `templates/`, `conf/` into **`/usr/local/srvctl/`** and symlinks `bin/srvctl` → `/usr/local/bin/srvctl`. `SRVCTL_ROOT` is hardcoded to `/usr/local/srvctl` in both [bin/srvctl](bin/srvctl) and [lib/core.sh](lib/core.sh).

Consequences:
- Editing files in this repo does **not** affect an installed instance until `sudo bash install.sh` is re-run.
- `install.sh` preserves an existing `conf/srvctl.conf` across reinstalls (backs it up to `/tmp/srvctl.conf.bak`).
- Runtime state lives outside the repo: per-domain dirs under `/var/www/<domain>/`, logs under `/usr/local/srvctl/logs/`, secrets in `/var/www/<domain>/.credentials` (root:600).

## Architecture

Command flow: `bin/srvctl <cmd>` → sources [lib/core.sh](lib/core.sh) → loads plugins → a `case` dispatches to `_load_and_run <module> cmd_<module>`, which **sources only that one `lib/<module>.sh`** and calls its `cmd_<module>` function. Modules are lazy-loaded per invocation; they are not all sourced at startup.

Each `lib/<module>.sh` follows the same shape:
- A public `cmd_<module>()` entry that (usually) calls `require_root` then `case "${1:-help}"` to route subcommands.
- Private `_<module>_<action>()` functions implementing each subcommand.

[lib/core.sh](lib/core.sh) is the shared contract every module depends on (it is always sourced first). Key helpers to reuse rather than reinvent:
- Logging/UI: `info` `success` `warn` `error` (note: **`error` exits**) `step` `header` `divider`, plus color vars (`RED`, `GREEN`, `BOLD`, `NC`, …).
- `require_root` — call at the top of any mutating command.
- `load_config` — sources `conf/srvctl.conf` and applies defaults; **runs automatically at source time**, so `DEFAULT_PHP_VERSION`, `WEB_ROOT`, `SSH_PORT`, `BACKUP_DIR`, etc. are available everywhere.
- `safe_name` — `example.com` → `example_com`; this is the basis for derived identities: web user `web_<safe>`, DB user/name `usr_<safe>`/`db_<safe>`, FPM pool, AppArmor profile.
- `generate_password`, `render_template`, `domain_exists`, `list_all_domains`, `read_credentials` (sources `.credentials` to expose DB/Redis secrets), `php_version_exists`, `nginx_test`, `service_is_active`, `log_action`.

**Cross-module calls** are done by sourcing on demand, guarded so a missing module is non-fatal — e.g. modules that send alerts do `source "${SRVCTL_ROOT}/lib/notify.sh" 2>/dev/null || true` before calling `send_notification`. Follow this pattern instead of sourcing other modules at file top.

**Templates** in `templates/` (nginx, php-fpm, apparmor, logrotate, systemd, cgroups) use `{{TOKEN}}` placeholders rendered by `render_template <file> KEY=value ...`. [install.sh](install.sh) copies all six subdirs. (Note: `templates/seccomp/` was deleted in Phase 2 — seccomp deny list is hardcoded in `_apply_seccomp_hardening` [lib/domain.sh](lib/domain.sh).)

**Cross-module function calls need an explicit `source`.** `_load_and_run` sources only the dispatched module, so calling another module's `_`-prefixed helper fails at runtime with `command not found` (exit 127). `lib/security.sh` does this via `_security_load_domain_lib`. Unit tests that source several modules by hand cannot catch this class of bug — `tests/test_no_undefined_functions.sh` scans for it statically instead.

## Conventions to match when editing

- **All user-facing strings and code comments are in Turkish.** Keep new output and comments Turkish to stay consistent (e.g. section banners, `info`/`error` messages).
- `confirm()` and the install/OS prompts expect the literal answer **`evet`** (Turkish "yes"), not `y`/`yes`.
- Every script starts with `set -euo pipefail`. Be deliberate about commands that may fail (append `|| true` where a non-zero exit is expected).
- Reuse `core.sh` helpers for output and config; don't hand-roll color codes or re-read the config file.
- Use `_<module>_<action>` naming for new subcommand handlers and wire them into the module's `case` block (and ideally the help text + `completions/srvctl.bash` / `completions/srvctl.zsh`).

## Version note

The live version string comes from `SRVCTL_VERSION` in [lib/core.sh](lib/core.sh) (currently `2.0.0`), which is what `srvctl version` prints. If bumping the version, update `core.sh` — that is the source of truth.

## New conventions (Phase 2)

These emerged during this release cycle and should be matched in future work:

- **stderr routing:** `warn()` now outputs to **stderr** (previously stdout). `info()` and `success()` remain on stdout by design — `_deploy_prune_one`'s output is deliberately collected by the caller. This allows tools to separately capture logs/warnings vs. data.

- **Safe in-place sed:** Use `_sed_inplace()` (defined in core.sh) instead of bare `sed -i`. It is GNU/BSD-portable, atomic, preserves mode+ownership, leaves no `.bak`, and returns a testable status code.

- **Template token inventory:** Every file in `templates/*/` begins with a `TOKENS: KEY1 KEY2 ...` comment. The render helpers call `_domain_assert_no_leftover_tokens` to error if any `{{` literal survives — a leftover indicates a missing placeholder substitution.

- **Test-seams for macOS dev:** Code that runs on macOS uses env overrides like `${SRVCTL_SYSTEMD_DIR:-...}`, `${SITES_AVAILABLE:-...}`, `${SRVCTL_FPM_DIR:-...}`, `${SRVCTL_USERS_DIR:-...}`, `${SRVCTL_STATE_DIR:-...}`. New code should follow this pattern so tests can mock paths without touching `/etc`.

- **Module boundary test:** `tests/test_no_undefined_functions.sh` now audits cross-module calls; it knows which modules source each other. A call to `_domain_foo()` from `lib/deploy.sh` must be guarded by `source ... || return 1` or the caller explicitly loads domain.sh.

- **Cross-module calls example:** If `lib/security.sh` needs `_domain_fs_plan()` from `lib/domain.sh`, it sources it conditionally:
  ```bash
  _security_load_domain_lib() {
      declare -F _domain_fs_plan >/dev/null 2>&1 && return 0
      source "${SRVCTL_ROOT}/lib/domain.sh" || return 1
  }
  ```
  Then call `_security_load_domain_lib || error "..."` before using domain functions. Similarly, `lib/deploy.sh` loads the deploy-read framework detector via `_deploy_read_framework`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
