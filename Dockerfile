# syntax=docker/dockerfile:1.7-labs

FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/root/.local/bin:${PATH}"

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       curl \
       ca-certificates \
       tini \
       bash \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Astral's Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

# No CMD; the entrypoint script determines how to run the cloned repo

