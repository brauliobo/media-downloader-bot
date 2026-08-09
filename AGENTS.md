# Project Guidelines

## Runtime

- Use the Ruby version from `.ruby-version`; run `rvm use` before Ruby, Bundler, RSpec, or Rake commands.
- Manage dependencies with Bundler and keep `Gemfile` and `Gemfile.lock` consistent.

## Code

- Fix root causes with small changes that follow existing patterns.
- Keep localized static text in `config/locales`; do not embed language-specific labels in Ruby.
- Keep EWPRS audiobook code under `lib/audiobook/ewprs/` with matching specs under `spec/audiobook/ewprs/`.
- Preserve unrelated worktree changes; never commit secrets, generated media, caches, or runtime logs.

## Verification

- Run focused specs while developing, then `bundle exec rspec` before committing.
- Run syntax checks and `git diff --check` for changed Ruby and text files.

## Operations

- Store resumable EWPRS output under `../ewprs-audiobooks/<language>/`; the publication manifest is authoritative.
- Never deploy or restart long-running services unless explicitly requested.

## Git

- Commit only when explicitly requested.
- Use focused commits with concrete module or feature prefixes.
