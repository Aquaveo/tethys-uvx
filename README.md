# tethys-uvx

A **uv-built (no conda), salt-free, nginx-free** [Tethys Platform](https://www.tethysplatform.org/)
base image. It contains the Tethys platform + framework/serving dependencies and a small set of
generic init/serve scripts — but **no apps**. Portal images build *from* it and add their own apps
and config.

> Note on the `/opt/conda` layout: this image has **no conda** — `/opt/conda/envs/tethys` is a plain
> `uv venv`. The `CONDA_*` env vars + path only exist because upstream Tethys hard-codes them; it's a
> compatibility shim, not conda.

## Design principles

1. **The image builds and serves. Nothing else.** The serving entrypoint (`start-server.sh`) only
   renders config + injects secrets, then runs the server. It never migrates the DB, syncs stores,
   collects/publishes static, or discovers hosts.
2. **Provisioning is pipeline work, not image work.** DB migrations, persistent-store creation +
   `syncstores`, static publishing, and superuser/branding are run by the **deploy pipeline / CI**
   (a job or step that invokes the scripts below), out of band and once — not on container start.
   The scripts live in the image as *tools the pipeline calls*.
3. **Deployment config is declarative, not discovered.** Hosts, storage backends, proxy/SSL headers,
   etc. belong in a portal's own `portal_config.yml` (or its deploy inputs). The base does not sniff
   the environment to decide behavior.
4. **No behavior flags.** No `RUN_STATIC` / `RUN_STORE_SETUP` / host-discovery switches. If the image
   doesn't do a thing, there's nothing to toggle. The one derived behavior is the server mode, and it
   follows an existing declarative setting (see below), not a dedicated flag.
5. **Dev server follows `DEBUG`.** `start-server.sh` reads `settings.DEBUG` from the rendered
   `portal_config.yml`: `DEBUG: true` → the Django dev server (`tethys manage start`, serves `/static/`
   locally, no CDN); otherwise the production ASGI server (uvicorn, or gunicorn if `SERVER=gunicorn`).

> **In transition:** `SECURE_PROXY_SSL_HEADER`, cursor mode, and `STORAGES` are now portal-owned
> (declared in each portal's `portal_config.yml` / rendered config, or via a `portal-config.d` hook).
> Still bundled here pending a coordinated change: the ECS host-IP merge in `portal-config.sh` and the
> `RUN_STATIC`/provisioning steps in `init-tethys.sh`.

## Image targets (published to GHCR)

| Tag | What it is | Use |
|---|---|---|
| `ghcr.io/aquaveo/tethys-uvx:builder` | toolchain (uv + Node + gcc) + venv + Tethys + framework deps | a portal's **build** stage |
| `ghcr.io/aquaveo/tethys-uvx:runtime-base` | slim runtime **without** the venv (libs + user + scripts) | a portal's **runtime** stage |
| `ghcr.io/aquaveo/tethys-uvx:runtime` | `runtime-base` + the no-apps venv | a runnable no-apps Tethys |

Each also gets `<target>-<short-sha>` and, on a git tag, `<target>-<tag>`. **Pin** a specific tag in
downstream portals so a base change can't silently break them.

## What's in vs out
- **In (base):** Tethys platform, Django, channels, uvicorn/gunicorn, DRF, psycopg2-binary,
  django-storages + boto3, the custom S3 static backend (`portal_storage.py`), the init/serve scripts,
  a generic `portal_config.yml` skeleton at `/config/portal_config.yml`.
- **Out (portal layer):** the scientific/geo stack, tethysdash/GEOGLOWS/other apps, plugins, and the
  portal-specific `portal_config.yml` / branding / app settings.

## Using it in a portal image
```dockerfile
FROM ghcr.io/aquaveo/tethys-uvx:builder AS builder
# npm build + `uv pip install` your apps into ${VIRTUAL_ENV}

FROM ghcr.io/aquaveo/tethys-uvx:runtime-base
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/conda  /opt/conda                                # venv with your apps
COPY --chown=1000:1000 conf/portal_config.yml /config/portal_config.yml   # your config/branding
# CMD (start-server.sh) is inherited from the base
```

## Database backends
`TETHYS_DB_ENGINE` selects the backend; the scripts branch on it via `db-env.sh`:

| Engine | `TETHYS_DB_ENGINE` | Notes |
|---|---|---|
| **postgres** (default) | `django.db.backends.postgresql` | needs `TETHYS_DB_HOST/PORT/USERNAME/PASSWORD`; supports poolers + PostGIS persistent stores |
| **sqlite** | `django.db.backends.sqlite3` | one file, no server — ideal for a single-container local/dev portal. `wait-for-role` is a no-op; `run-once` markers are files beside the DB |

For sqlite the DB file is `TETHYS_DB_NAME` (if absolute) or `${TETHYS_PERSIST}/tethys_platform.sqlite`
— keep `TETHYS_PERSIST` on a mounted volume. Persistent stores are Postgres-only.

## Scripts reference (`/usr/local/bin`)

Comments in the scripts are intentionally terse; this is the reference.

**Serving (runs in the web container):**
- `start-server.sh` — the image `CMD`. Runs `portal-config.sh`, then serves: `DEBUG: true` → dev
  server; else uvicorn (or gunicorn via `SERVER=gunicorn`). Does no provisioning.
- `portal-config.sh` — copies `/config/portal_config.yml` into `TETHYS_HOME`, injects `SECRET_KEY` +
  DB password/host/user/port/name, then runs any `/opt/portal/portal-config.d/*.sh` (portal-owned
  config extensions, e.g. `STORAGES`). Idempotent; no DB writes. (Still merges hosts in transition.)
- `db-env.sh` — sourced helper; sets `DB_IS_SERVER` / `SQLITE_PATH` from `TETHYS_DB_ENGINE`.

**Provisioning (invoked by the deploy pipeline / an init job, NOT the web container):**
- `init-tethys.sh` — the current init-container orchestrator: `wait-for-role` → `portal-config` →
  `db-migrations` → run-once `configure-services` → run-once `publish-static` → `portal-bootstrap` →
  portal `init.d` hooks.
- `wait-for-role.sh` — blocks until the app DB role can authenticate (no-op on sqlite).
- `db-migrations.sh` — `tethys db migrate`.
- `configure-services.sh` — creates the PostGIS persistent-store service from `TETHYS_PS_CONNECTION`.
- `provision-persistent-store.sh <app> <setting>` — generic, parameterized: create service → link →
  `syncstores` for any app's store, with a least-privilege role. Use this instead of app-specific
  scripts.
- `publish-static.sh` — collect (incl. tethysdash plugin static, if present) → `collectstatic`
  (uploads to S3 when `STORAGES.staticfiles` is S3).
- `portal-bootstrap.sh` — create the superuser + apply `site_settings` (branding) via `tethys site -f`.
- `run-once.sh <marker> -- <cmd>` — run `<cmd>` once per `<marker>` (per `INIT_VERSION`), recording the
  marker in the DB (or a file for sqlite) so it survives container replacement.

### Portal extensions (two hook dirs, both opt-in, no base edits)
- **`/opt/portal/portal-config.d/*.sh`** — run by `portal-config.sh` (so in **both** the provision
  and web containers), for portal-owned **config** injection that needs deploy-time env, e.g.
  `STORAGES` from a bucket var. `COPY conf/portal-config.d/ /opt/portal/portal-config.d/`.
- **`/opt/portal/init.d/*.sh`** — run by `init-tethys.sh` (provisioning only), after migrations/
  branding, for one-off setup (proxy apps, seed data). `COPY init.d/ /opt/portal/init.d/`.

Each script is idempotent; both dirs are optional (skipped if absent).

## conf/
- `portal_config.yml` — generic skeleton shipped at `/config/portal_config.yml`; **a portal image
  overwrites it** with its own (DB, branding, app settings, `STORAGES`, `SECURE_PROXY_SSL_HEADER`).
- `portal_storage.py` — `PortalStaticS3Storage`: strips a leading slash so Tethys's leading-slash
  static paths resolve as S3 keys. A generic **enabler** kept in the base (on `PYTHONPATH`) for any
  S3-using portal to reference from its own `STORAGES`; the base itself configures no storage.

## CI
`.github/workflows/build.yml` builds the targets and pushes to GHCR on push to `main` / tags. The
first publish makes a **private** package — switch it to **public** once in the package settings.
