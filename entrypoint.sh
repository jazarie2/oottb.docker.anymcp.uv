#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[entrypoint] $*" | tee -a /var/log/entrypoint.log >&2
}

if [[ "${PYTHON_UV_REPO_URL:-}" == "" ]]; then
  log "ERROR: PYTHON_UV_REPO_URL is not set. Exiting."
  exit 1
fi

REPO_URL="${PYTHON_UV_REPO_URL}"
REPO_TOKEN="${PYTHON_UV_REPO_TOKEN:-}"
GIT_PROXY="${PYTHON_UV_REPO_PROXY:-}"

TMP_DIR="/tmp/repo-$(date +%s)-$$"
mkdir -p "${TMP_DIR}"
cd "${TMP_DIR}"

# Configure git if proxy is provided
if [[ -n "${GIT_PROXY}" ]]; then
  log "Configuring git proxy: ${GIT_PROXY}"
  git config --global http.proxy "${GIT_PROXY}"
  git config --global https.proxy "${GIT_PROXY}"
fi

# Embed token into URL if provided and not already present
if [[ -n "${REPO_TOKEN}" ]]; then
  if [[ "${REPO_URL}" =~ ^https?:// ]]; then
    # insert token for https urls like https://token@host/path or https://oauth2:token@host/path
    # Prefer using token as password with an oauth2 user for gitlab-style tokens
    REPO_URL_WITH_TOKEN="${REPO_URL/https:\/\//https://oauth2:${REPO_TOKEN}@}"
  else
    # For ssh URLs we cannot inject token; warn user
    log "WARNING: Token provided but REPO_URL is not https-based. Token will be ignored."
    REPO_URL_WITH_TOKEN="${REPO_URL}"
  fi
else
  REPO_URL_WITH_TOKEN="${REPO_URL}"
fi

log "Cloning repository: ${REPO_URL}"
if ! git clone --depth 1 "${REPO_URL_WITH_TOKEN}" repo 2>&1 | tee /dev/stderr; then
  log "ERROR: Failed to clone repository ${REPO_URL}"
  exit 2
fi

cd repo

# If there is a .tool-versions (asdf) or .python-version, respect it by setting UV_PYTHON
if [[ -f .python-version ]]; then
  PY_VER=$(cat .python-version | tr -d "\n\r")
  export UV_PYTHON="$PY_VER"
  log "Detected .python-version -> UV_PYTHON=${UV_PYTHON}"
fi

# If there is a requirements.txt or pyproject.toml, use uv to sync
if [[ -f pyproject.toml ]]; then
  log "Installing project dependencies via uv sync"
  if ! uv sync 2>&1 | tee /dev/stderr; then
    log "ERROR: uv sync failed"
    exit 3
  fi
elif [[ -f requirements.txt ]]; then
  log "Installing requirements via uv pip install -r requirements.txt"
  if ! uv pip install -r requirements.txt 2>&1 | tee /dev/stderr; then
    log "ERROR: uv pip install failed"
    exit 4
  fi
else
  log "No dependency spec found (pyproject.toml or requirements.txt). Proceeding."
fi

# Determine how to serve MCP via uv
# Priority order:
# 1) If repo provides an executable serve script at scripts/serve.sh, use it
# 2) If repo defines an "mcp" script in pyproject [project.scripts], run via uv run -m <entry>
# 3) If repo has module with __main__ under src/ or package name, attempt uv run -m mcp

serve_script="scripts/serve.sh"
if [[ -x "${serve_script}" ]]; then
  log "Running custom serve script: ${serve_script}"
  exec bash "${serve_script}"
fi

# Try common entry points
run_cmd=""

if [[ -f pyproject.toml ]]; then
  # Try reading project.scripts for a reasonable default
  if grep -q "\[project.scripts\]" pyproject.toml && grep -E "^(mcp|serve|start)\s*=\s*" pyproject.toml -q; then
    ENTRY=$(awk '/\[project.scripts\]/{flag=1;next}/\[/{flag=0}flag' pyproject.toml | awk -F'=' '/^(mcp|serve|start)\s*=/{print $2}' | head -n1 | tr -d '" ')
    if [[ -n "${ENTRY}" ]]; then
      run_cmd=(uv run ${ENTRY})
    fi
  fi
fi

if [[ -z "${run_cmd}" ]]; then
  # Fallback common modules
  for module in mcp app.main main; do
    if uv run python -c "import importlib,sys; sys.exit(0 if importlib.util.find_spec('${module}') else 1)" >/dev/null 2>&1; then
      run_cmd=(uv run -m ${module})
      break
    fi
  done
fi

if [[ -z "${run_cmd}" ]]; then
  log "ERROR: Could not determine how to run the cloned repo. Provide scripts/serve.sh or project script."
  exit 5
fi

log "Starting server: ${run_cmd[*]}"
set +e
"${run_cmd[@]}" 2>&1 | tee /dev/stderr
exit_code=$?
set -e

if [[ ${exit_code} -ne 0 ]]; then
  log "ERROR: Service exited with code ${exit_code}"
  exit ${exit_code}
fi

