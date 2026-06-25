# syntax=docker/dockerfile:1
#
# tethys-uvx -- uv-built (no conda), salt-free, nginx-free Tethys Platform base image, served by
# uvicorn (ASGI). Apps are NOT installed here -- a downstream portal image builds FROM the targets:
#
#   builder  -- toolchain (uv + Node + gcc) + Python venv + Tethys platform + framework deps.
#               Portals use this to build/install their apps:  FROM tethys-uvx:builder AS builder
#   runtime  -- slim image: just the venv + interpreter + runtime libs + the init/serve scripts.
#               A runnable no-apps Tethys; portals assemble:    FROM tethys-uvx:runtime
#
# A portal layers apps in by building FROM :builder, then COPYing the augmented venv onto :runtime.

###############################################################################
# base - shared environment (both stages FROM this)
###############################################################################
FROM debian:trixie-slim AS base

# Paths + venv layout (mimics the conda layout Tethys expects). All Tethys state lives under
# /home/tethys (the service user's home) so a non-root user owns it WITHOUT chowning system dirs.
ENV HOME="/home/tethys" \
    TETHYS_HOME="/home/tethys/portal" \
    TETHYS_LOG="/home/tethys/log" \
    TETHYS_PERSIST="/home/tethys/persist" \
    TETHYS_APPS_ROOT="/home/tethys/apps" \
    BASH_PROFILE=".bashrc" \
    CONDA_HOME="/opt/conda" \
    CONDA_ENV_NAME="tethys" \
    ENV_NAME="tethys" \
    VIRTUAL_ENV="/opt/conda/envs/tethys" \
    CONDA_PREFIX="/opt/conda/envs/tethys" \
    LD_LIBRARY_PATH="/opt/conda/envs/tethys/lib" \
    PATH="/opt/conda/envs/tethys/bin:${PATH}"

ENV STATIC_ROOT="${TETHYS_PERSIST}/static" \
    WORKSPACE_ROOT="${TETHYS_PERSIST}/workspaces" \
    MEDIA_ROOT="${TETHYS_PERSIST}/media"

# Framework Python modules (e.g. portal_storage) live here, on PYTHONPATH and OUTSIDE the venv, so a
# downstream portal can override the whole venv without losing them.
ENV PYTHONPATH="/opt/portal"

ENV TETHYS_PORT=8000 \
    TETHYS_DB_ENGINE="django.db.backends.postgresql" \
    TETHYS_DB_NAME="tethys_platform" \
    TETHYS_DB_USERNAME="tethys_default" \
    TETHYS_DB_HOST="db" \
    TETHYS_DB_PORT=5432 \
    PORTAL_SUPERUSER_NAME="" \
    PORTAL_SUPERUSER_EMAIL="" \
    ASGI_PROCESSES=1

###############################################################################
# builder - toolchain + venv + Tethys + framework deps (NO apps)
###############################################################################
FROM base AS builder

# uv binary (build-time only)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# build deps: git, gcc + libpq-dev (psycopg2 fallback), ca-certificates, curl+gnupg (NodeSource),
# nodejs. Node is here so DOWNSTREAM portal builds (FROM tethys-uvx:builder) can build React apps.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git gcc libpq-dev curl gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

ENV UV_PYTHON_PREFERENCE=only-managed \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_COMPILE_BYTECODE=1

WORKDIR ${TETHYS_HOME}
COPY pyproject.toml .

# Python interpreter + venv + Tethys platform + framework deps + a default portal_config.yml
RUN uv python install 3.12 \
  && uv venv "${VIRTUAL_ENV}" --python 3.12 \
  && uv pip install --no-cache "tethys-platform @ git+https://github.com/tethysplatform/tethys.git" \
  && uv pip install --no-cache -r pyproject.toml \
  && tethys gen portal_config

# world-readable so the venv works run as the non-root runtime user
RUN chmod -R a+rX /opt/python /opt/conda

###############################################################################
# runtime-base - slim runtime WITHOUT the venv (OS + libs + user + scripts + config skeleton).
# This is the foundation a portal builds on: FROM tethys-uvx:runtime-base, then COPY in the
# app-augmented venv -- avoids shipping the base venv twice.
###############################################################################
FROM base AS runtime-base

# runtime libs only: certs (outbound HTTPS), curl (healthcheck), postgresql-client (psql + libpq),
# libexpat1 (some geo libs dlopen it; tiny -- kept so portal images don't need extra apt).
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl postgresql-client libexpat1 \
  && rm -rf /var/lib/apt/lists/*

# Non-root service user; --create-home makes /home/tethys owned by uid 1000.
RUN useradd --uid 1000 --create-home --home-dir /home/tethys --shell /bin/bash tethys

# venv-activating entrypoint shim + the framework init/serve scripts
RUN printf '#!/bin/bash\nexport VIRTUAL_ENV=%s\nexport PATH="${VIRTUAL_ENV}/bin:${PATH}"\nexport CONDA_PREFIX="${VIRTUAL_ENV}"\nexport LD_LIBRARY_PATH="${VIRTUAL_ENV}/lib:${LD_LIBRARY_PATH}"\nexec "$@"\n' "${VIRTUAL_ENV}" > /usr/local/bin/_entrypoint.sh \
  && chmod +x /usr/local/bin/_entrypoint.sh
COPY --chmod=0755 scripts/*.sh /usr/local/bin/

# Custom S3 static backend (tolerates Tethys' leading-slash static paths), on PYTHONPATH (/opt/portal)
# so it survives a venv override; importable as portal_storage.PortalStaticS3Storage.
COPY conf/portal_storage.py /opt/portal/portal_storage.py

USER 1000:1000

RUN mkdir -p "${TETHYS_HOME}/keys" "${TETHYS_HOME}/tethys" \
      "${STATIC_ROOT}" "${MEDIA_ROOT}" "${WORKSPACE_ROOT}" \
      "${TETHYS_APPS_ROOT}" "${TETHYS_LOG}"

# Baked default portal_config.yml (the bare `tethys gen` output; overwritten at runtime).
COPY --chown=1000:1000 --from=builder ${TETHYS_HOME}/portal_config.yml ${TETHYS_HOME}/portal_config.yml
# Generic declarative portal config skeleton. portal-config.sh copies this to TETHYS_HOME and injects
# secrets/host at startup (PORTAL_CONFIG_SRC default /config/portal_config.yml). A portal image
# OVERWRITES /config/portal_config.yml with its own (DB, branding, app settings).
COPY --chown=1000:1000 conf/portal_config.yml /config/portal_config.yml

VOLUME ["${TETHYS_PERSIST}", "${TETHYS_HOME}/keys"]
WORKDIR ${TETHYS_HOME}
CMD ["/usr/local/bin/start-uvicorn.sh"]

###############################################################################
# runtime - runtime-base + the no-apps venv: a standalone runnable Tethys
###############################################################################
FROM runtime-base AS runtime

# The interpreter AND the venv, at the SAME paths (pyvenv.cfg hardcodes /opt/python).
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/conda  /opt/conda
