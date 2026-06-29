# tethys-uvx

A **uv-built (no conda), salt-free, nginx-free** [Tethys Platform](https://www.tethysplatform.org/)
base image, served by **uvicorn** (ASGI). It contains the Tethys platform + framework/serving
dependencies and the generic init/serve scripts — but **no apps**. Portal images build *from* it and
add their own apps (e.g. tethysdash) and config.

## Image targets (published to GHCR)

| Tag | What it is | Use |
|---|---|---|
| `ghcr.io/aquaveo/tethys-uvx:builder` | toolchain (uv + Node + gcc) + venv + Tethys + framework deps | a portal's **build** stage (build/install apps) |
| `ghcr.io/aquaveo/tethys-uvx:runtime-base` | slim runtime **without** the venv (libs + user + scripts) | a portal's **runtime** stage (COPY your venv onto it) |
| `ghcr.io/aquaveo/tethys-uvx:runtime` | `runtime-base` + the no-apps venv | a runnable no-apps Tethys |

Each also gets `<target>-<short-sha>` and, on a git tag, `<target>-<tag>`. **Pin** a specific tag in
downstream portals so a base change can't silently break them.

## What's in vs out
- **In (base):** Tethys platform, Django, channels, uvicorn, DRF, psycopg2-binary, django-storages +
  boto3, the custom S3 static backend (`portal_storage.py`), the init/serve scripts, a generic
  `portal_config.yml` skeleton at `/config/portal_config.yml`.
- **Out (portal layer):** the scientific/geo stack (numpy, scipy, geoglows, …), tethysdash and its
  React build, plugins, and the portal-specific `portal_config.yml` / branding.

## Using it in a portal image
```dockerfile
# build the apps with the toolchain
FROM ghcr.io/aquaveo/tethys-uvx:builder AS builder
# ... npm build + `uv pip install` your apps into ${VIRTUAL_ENV} ...

# assemble onto the slim runtime
FROM ghcr.io/aquaveo/tethys-uvx:runtime-base
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/conda  /opt/conda          # venv with your apps
COPY --chown=1000:1000 conf/portal_config.yml /config/portal_config.yml   # your config/branding
# CMD (start-server.sh) is inherited from the base
```

## The scripts (baked into `/usr/local/bin`)
`init-tethys.sh` orchestrates the salt-free init (run in an init container before the web tier):
`wait-for-role` → `portal-config` → `db-migrations` → run-once(`configure-services`,
`configure-tethysdash`, `publish-static`) → `portal-bootstrap` → **portal `init.d` hooks**.
`start-server.sh` renders the config and serves the ASGI app. They're env-driven; see each script's
header.

### Portal extensions (`init.d` hooks)
After the portal is fully configured, `init-tethys.sh` runs every executable `*.sh` in
`/opt/portal/init.d` (lexical order). This lets a portal add its own one-off setup — proxy apps,
custom `manage.py` commands, seed data — **without modifying this base image**. A portal opts in from
its own Dockerfile:
```dockerfile
COPY init.d/ /opt/portal/init.d/   # each script idempotent; the dir is optional (skipped if absent)
```
Hooks run in the init container, once per task start, *after* migrations and branding. Make each one
idempotent (it re-runs every deploy); a hook that should fire only once per image version can wrap
itself in `run-once.sh`.

## CI
`.github/workflows/build.yml` builds both targets and pushes to GHCR on push to `main` / tags. The
first publish makes a **private** package — switch it to **public** once in the package settings.
