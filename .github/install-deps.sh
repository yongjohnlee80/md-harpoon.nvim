#!/usr/bin/env bash
# .github/install-deps.sh — materialise the plugin dependencies tests/smoke.lua
# resolves, in the two shapes it resolves them from (the lazy dir, and a
# `<workspace>/<plugin>/main` sibling).
#
# Extracted from the workflow because two jobs need it (`lua` pins auto-core,
# `drift` rides its default branch) and the ONLY thing that should differ
# between them is a ref. Inlining it twice is how two copies drift apart.
#
# Refs come from the environment. An EMPTY ref means "whatever the default
# branch is now" — that is the drift job's whole purpose, so it is a supported
# value and not a mistake:
#   AUTO_CORE_REF  PLENARY_REF  MD_RENDER_REF
set -euo pipefail

lazy="$HOME/.local/share/nvim/lazy"
mkdir -p "$lazy"

# smoke.lua derives its sibling root as fnamemodify(plugin_root, ":h:h"), which
# on a runner is dirname(dirname($GITHUB_WORKSPACE)) — the checkout lives at
# /home/runner/work/<repo>/<repo>.
siblings="$(dirname "$(dirname "$GITHUB_WORKSPACE")")"

clone_at() {
  local url="$1" dest="$2" ref="$3"
  git clone --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ]; then
    git -C "$dest" checkout "$ref"
  fi
  printf '  %s -> %s\n' "$dest" "$(git -C "$dest" log --oneline -1)"
}

echo "dependencies:"
clone_at https://github.com/yongjohnlee80/auto-core.nvim \
         "$siblings/auto-core.nvim/main" "${AUTO_CORE_REF:-}"
clone_at https://github.com/nvim-lua/plenary.nvim \
         "$lazy/plenary.nvim" "${PLENARY_REF:-}"
# md-render is a SOFT dependency (open_slot rendering only) and it is a THIRD
# PARTY repo — delphinus/, not ours. Installed anyway so the open-slot path is
# exercised rather than skipped; note the owner, because guessing it as ours is
# a mistake already made once.
clone_at https://github.com/delphinus/md-render.nvim \
         "$lazy/md-render.nvim" "${MD_RENDER_REF:-}"
