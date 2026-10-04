# Project Guidelines

## Runtime

- Use the Ruby version from `.ruby-version`; run `rvm use` before Ruby, Bundler, RSpec, or Rake commands.
- Manage dependencies with Bundler and keep `Gemfile` and `Gemfile.lock` consistent.

## Code

- Fix root causes with small changes that follow existing patterns.
- Keep localized static text in `config/locales`; do not embed language-specific labels in Ruby.
- Rails app: every domain lives directly in `app/<domain>` (`app/audiobook`, `app/ffmpeg`, `app/bot`, ...), `app` is the Zeitwerk root so the folder is the namespace; only `app/models` (Sequel via sequel-rails), `controllers` and `helpers` are nested roots. Do not add catch-all buckets (`services`, `clients`, `support`). Specs mirror `app/`. Acronym inflections live in `config/initializers/zeitwerk.rb`.
- No `require_relative` between app files; constants autoload (`bin/rails zeitwerk:check`). One constant per file.
- Keep EWPRS audiobook code under `app/audiobook/ewprs/` with matching specs under `spec/audiobook/ewprs/`.
- Frontend (Vue Vapor + Pug via vite_rails) lives in `app/frontend`.
- Preserve unrelated worktree changes; never commit secrets, generated media, caches, or runtime logs.

## Verification

- Run focused specs while developing, then `bundle exec rspec` before committing. Specs need the test database (`RAILS_ENV=test bin/rails sequel:create sequel:migrate`).
- Run syntax checks and `git diff --check` for changed Ruby and text files.

## Operations

- Store resumable EWPRS output under `../ewprs-audiobooks/<language>/`; the publication manifest is authoritative.
- Never deploy or restart long-running services unless explicitly requested.

## Git

- Commit only when explicitly requested.
- Use focused commits with concrete module or feature prefixes.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **media-downloader-bot** (4428 symbols, 9979 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/media-downloader-bot/context` | Codebase overview, check index freshness |
| `gitnexus://repo/media-downloader-bot/clusters` | All functional areas |
| `gitnexus://repo/media-downloader-bot/processes` | All execution flows |
| `gitnexus://repo/media-downloader-bot/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
