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

# Configure git if proxy is provided and disable interactive prompts
export GIT_TERMINAL_PROMPT=0
if [[ -n "${GIT_PROXY}" ]]; then
  log "Configuring git proxy: ${GIT_PROXY}"
  git config --global http.proxy "${GIT_PROXY}"
  git config --global https.proxy "${GIT_PROXY}"
fi

# Embed token into URL if provided and not already present
REPO_URL_WITH_TOKEN="${REPO_URL}"
if [[ -n "${REPO_TOKEN}" ]]; then
  if [[ "${REPO_URL}" =~ ^https?:// ]]; then
    if [[ "${REPO_URL}" == *"@"* ]]; then
      # Already has credentials embedded; do not modify
      REPO_URL_WITH_TOKEN="${REPO_URL}"
    else
      host=$(echo "${REPO_URL}" | sed -E 's#https?://([^/]+)/.*#\1#')
      user="oauth2"
      if [[ "${host}" == *github.com* ]]; then
        user="x-access-token"
      elif [[ "${host}" == *gitlab.* ]]; then
        user="oauth2"
      elif [[ "${host}" == *bitbucket.* ]]; then
        user="x-token-auth"
      fi
      REPO_URL_WITH_TOKEN="${REPO_URL/https:\/\//https://${user}:${REPO_TOKEN}@}"
    fi
  else
    # For ssh URLs we cannot inject token; warn user
    log "WARNING: Token provided but REPO_URL is not https-based. Token will be ignored."
    REPO_URL_WITH_TOKEN="${REPO_URL}"
  fi
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
  log "Creating virtual environment via uv venv"
  if ! uv venv 2>&1 | tee /dev/stderr; then
    log "ERROR: uv venv failed"
    exit 3
  fi
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
  # If user provided an explicit run name via env, use it as final fallback
  if [[ -n "${PYTHON_UV_RUN_NAME:-}" ]]; then
    log "Using PYTHON_UV_RUN_NAME fallback: ${PYTHON_UV_RUN_NAME}"
    # Allow passing either a module (-m mod) or a script/entry spec
    # Safely split the env var into an array to avoid command injection
    # Validate for dangerous shell metacharacters
    if [[ "${PYTHON_UV_RUN_NAME}" =~ [\;\|\&\$\>\<\`\\] ]]; then
      log "ERROR: PYTHON_UV_RUN_NAME contains potentially dangerous shell characters. Aborting."
      exit 6
    fi
    # Use eval to properly split quoted arguments
    eval "set -- ${PYTHON_UV_RUN_NAME}"
    _uv_run_args=("$@")
    run_cmd=(uv run "${_uv_run_args[@]}")
  else
    log "ERROR: Could not determine how to run the cloned repo. Provide scripts/serve.sh, project script, or set PYTHON_UV_RUN_NAME."
    exit 5
  fi
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

