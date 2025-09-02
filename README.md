# Out Of The Box (OOTB)
# oottb.docker.anymcp.uv

This Docker image boots a Python environment with `uv`, clones a user-specified repo at container start, installs dependencies, and serves the repo's MCP entrypoint using `uv`. If serving fails, the container exits non-zero and prints logs to stdout/stderr for Kubernetes/Docker to capture.

## Environment variables

- `PYTHON_UV_REPO_URL` (required): Git URL of the repo to run.
- `PYTHON_UV_REPO_TOKEN` (optional): Token for private HTTPS repos. Injected as `oauth2:<token>@` in the URL.
- `PYTHON_UV_REPO_PROXY` (optional): HTTP/HTTPS proxy URL for git when behind a proxy.
- `PYTHON_UV_RUN_NAME` (optional): Either the clone directory name or an explicit command to pass to `uv run` as a fallback. Examples:
  - `-m http.server 9999`
  - `your_pkg.cli:main`
  - `python path/to/script.py`

## Build

```bash
docker build -t anymcp-uv:latest .
```

## Run

```bash
docker run --rm \
  -e PYTHON_UV_REPO_URL="https://github.com/yourorg/your-mcp-repo.git" \
  anymcp-uv:latest
```

Private repo with token and proxy:

```bash
docker run --rm \
  -e PYTHON_UV_REPO_URL="https://gitlab.com/yourorg/your-mcp-repo.git" \
  -e PYTHON_UV_REPO_TOKEN="<token>" \
  -e PYTHON_UV_REPO_PROXY="http://proxy.corp:3128" \
  -e PYTHON_UV_RUN_NAME="-m http.server 8000" \
  anymcp-uv:latest
```

## How the image runs

At container start, the `entrypoint.sh` script:

1. Optionally configures Git proxy from `PYTHON_UV_REPO_PROXY`.
2. Clones `PYTHON_UV_REPO_URL` into a temp dir (injects token for HTTPS if `PYTHON_UV_REPO_TOKEN` is set).
3. Installs dependencies via `uv sync` if `pyproject.toml` exists, otherwise `uv pip install -r requirements.txt` if present.
4. Attempts to serve the repo by, in order:
   - Executing `scripts/serve.sh` if it exists and is executable.
   - Running the first of `mcp`, `serve`, or `start` from `[project.scripts]` in `pyproject.toml` using `uv run`.
   - Falling back to `uv run -m` with common modules: `mcp`, `app.main`, `main` (auto-detected).

If none of the above entrypoints are found, the container exits with an error.

## Kubernetes example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anymcp-uv
spec:
  replicas: 1
  selector:
    matchLabels:
      app: anymcp-uv
  template:
    metadata:
      labels:
        app: anymcp-uv
    spec:
      containers:
      - name: anymcp-uv
        image: anymcp-uv:latest
        env:
        - name: PYTHON_UV_REPO_URL
          value: "https://github.com/yourorg/your-mcp-repo.git"
        - name: PYTHON_UV_REPO_TOKEN
          valueFrom:
            secretKeyRef:
              name: mcp-token
              key: token
        - name: PYTHON_UV_REPO_PROXY
          value: "http://proxy.corp:3128"
        ports:
        - containerPort: 8000
```

## License

MIT ©
