#!/bin/bash
# Installs grap-ia dependencies for Claude Code on the web sessions.
# Each part is installed only once its manifest exists, so the hook works before and after scaffolding.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [ -f package.json ]; then
  echo "session-start: installing JS dependencies with pnpm"
  corepack enable >/dev/null 2>&1 || true
  pnpm install --prefer-offline
  # The Supabase CLI is a root devDependency; expose it as `supabase`.
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -x node_modules/.bin/supabase ]; then
    echo "export PATH=\"$PWD/node_modules/.bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  fi
fi

if [ -f apps/api/pyproject.toml ]; then
  echo "session-start: installing Python dependencies with uv"
  (cd apps/api && uv sync)
fi

echo "session-start: done"
