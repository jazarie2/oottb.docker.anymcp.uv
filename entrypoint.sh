#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] Starting anymcp-uv runner"

# Env vars
: "${PYTHON_UV_REPO_URL?PYTHON_UV_REPO_URL is required}"
PYTHON_UV_REPO_TOKEN="${PYTHON_UV_REPO_TOKEN:-}"
PYTHON_UV_REPO_PROXY="${PYTHON_UV_REPO_PROXY:-}"
PYTHON_UV_RUN_NAME="${PYTHON_UV_RUN_NAME:-}"

WORKDIR="/work"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

maybe_configure_proxy() {
  if [[ -n "$PYTHON_UV_REPO_PROXY" ]]; then
    echo "[entrypoint] Configuring git proxy: $PYTHON_UV_REPO_PROXY"
    git config --global http.proxy "$PYTHON_UV_REPO_PROXY" || true
    git config --global https.proxy "$PYTHON_UV_REPO_PROXY" || true
  fi
}

clone_repo() {
  local url="$PYTHON_UV_REPO_URL"
  if [[ -n "$PYTHON_UV_REPO_TOKEN" ]]; then
    if [[ "$url" =~ ^https:// ]]; then
      url="https://oauth2:${PYTHON_UV_REPO_TOKEN}@${url#https://}"
    fi
  fi

  local dest
  dest="repo-$(date +%s)"

  echo "[entrypoint] Cloning $PYTHON_UV_REPO_URL -> $dest"
  git clone --depth 1 "$url" "$dest"
  cd "$dest"
}

install_deps() {
  if [[ -f "pyproject.toml" ]]; then
    echo "[entrypoint] Installing deps via uv sync"
    uv sync --frozen || uv sync
  elif [[ -f "requirements.txt" ]]; then
    echo "[entrypoint] Creating venv and installing deps from requirements.txt"
    uv venv
    uv pip install -r requirements.txt
  else
    echo "[entrypoint] No dependency file found; continuing"
  fi
}

try_run() {
  # 1) scripts/serve.sh
  if [[ -x "scripts/serve.sh" ]]; then
    echo "[entrypoint] Running scripts/serve.sh"
    exec scripts/serve.sh
  fi

  # 2) project.scripts: mcp, serve, start
  if [[ -f "pyproject.toml" ]]; then
    for s in mcp serve start; do
      if python - <<'PY'
import sys
try:
    import tomllib
except Exception:
    print("0")
    sys.exit(0)
from pathlib import Path
p = Path('pyproject.toml')
if not p.exists():
    print("0")
    sys.exit(0)
data = tomllib.loads(p.read_text('utf-8'))
scripts = (data.get('project') or {}).get('scripts') or {}
print("1" if scripts.get(sys.argv[1]) else "0")
PY
      "$s" | grep -q "1"; then
        echo "[entrypoint] Running pyproject script: $s"
        exec uv run -- "$s"
      fi
    done
  fi

  # 3) explicit run name
  if [[ -n "$PYTHON_UV_RUN_NAME" ]]; then
    if [[ -x ".venv/bin/python" && "$PYTHON_UV_RUN_NAME" == python* ]]; then
      echo "[entrypoint] Running explicit with venv: .venv/bin/$PYTHON_UV_RUN_NAME"
      # shellcheck disable=SC2086
      exec .venv/bin/$PYTHON_UV_RUN_NAME
    else
      echo "[entrypoint] Running explicit: uv run $PYTHON_UV_RUN_NAME"
      # shellcheck disable=SC2086
      exec uv run $PYTHON_UV_RUN_NAME
    fi
  fi

  # 4) common python modules
  for mod in mcp app.main main; do
    if python - <<PY
import importlib, sys
mod = sys.argv[1]
try:
    importlib.import_module(mod)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    "$mod"; then
      if [[ -x ".venv/bin/python" ]]; then
        echo "[entrypoint] Fallback running module with venv: $mod"
        exec .venv/bin/python -m "$mod"
      else
        echo "[entrypoint] Fallback running module: $mod"
        exec uv run -m "$mod"
      fi
    fi
  done

  echo "[entrypoint] No known entrypoint found; exiting" >&2
  exit 1
}

maybe_configure_proxy
clone_repo
install_deps
try_run

