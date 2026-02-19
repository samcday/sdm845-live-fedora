# casync Compose Producer

This repository publishes a deduplicated "Compose Thing" for branch and PR builds.

## Object layout

All objects live under the existing `live-pocket-fedora/` prefix in the bleeding bucket:

- `live-pocket-fedora/casync/chunks/` - shared casync chunk store layout (`.castr` compatible)
- `live-pocket-fedora/casync/indexes/compose-<run>-<attempt>-<sha>.caibx` - immutable blob index per build
- `live-pocket-fedora/casync/manifests/<run>-<attempt>-<sha>.json` - immutable compose manifest per build
- `live-pocket-fedora/casync/refs/<ref>/latest.json` - mutable lineage pointer per ref
- `live-pocket-fedora/images/<run>-<attempt>-<sha>.ero` - canonical EROFS image per build

## CI behavior

`step_build.yml` now performs the producer flow after mkosi finishes:

1. Restores local casync chunk cache from `actions/cache` (`.casync-cache/store.castr`).
2. Builds an EROFS image and indexes it directly with casync.
   - `scripts/casync-compose.sh` resolves the source image in this order:
     `COMPOSE_EROFS_IMAGE`, `mkosi.output/live-pocket-fedora.ero`, `mkosi.output/image.ero`, then a single `mkosi.output/*.ero` match.
   - Uses `COMPOSE_CHUNK_SIZE` (default `262144:1048576:4194304`) to keep chunk cardinality manageable in CI.
3. Verifies integrity:
   - `casync digest` of the resolved EROFS image equals digest of generated `.caibx`.
   - Smoke extraction of `.caibx` recreates an `image.ero` blob with matching SHA256.
   - If publish is enabled, a second smoke extraction uses the uploaded index.
4. Prints and exports dedupe metrics (`new_bytes`, `reused_bytes`).
5. Publishes only missing/different chunk objects via `aws s3 sync --size-only`, then uploads immutable index/manifest/image objects and updates `refs/<ref>/latest.json`.

Publish is attempted on PR/main/dispatch only when standard repository secrets are available:

- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET`
- `R2_ENDPOINT_URL`

Fork PRs without secrets still run build + integrity checks, but skip object-store publication.

## Local dry-run

From repo root:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y erofs-utils systemd-ukify casync awscli
sudo mkosi -f --profile erofs-lz4,phosh,embedded-firmware,precompile-akmods
COMPOSE_ENABLE_PUBLISH=0 COMPOSE_USE_SUDO=1 ./scripts/casync-compose.sh
```

Dry-run artifacts are written to `mkosi.output/compose/`:

- `compose-manifest.json`
- `compose-*.caibx`
- `dedupe-stats.json`
- `*.sha256` and `*.digest` files

## Local publish test

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export COMPOSE_BUCKET=...
export COMPOSE_ENDPOINT_URL=...
export COMPOSE_PUBLIC_BASE_URL=https://bleeding.fastboop.win
export COMPOSE_ENABLE_PUBLISH=1
export COMPOSE_USE_SUDO=1
./scripts/casync-compose.sh
```

## Recovery steps

If cache/store state becomes inconsistent:

1. Remove local cache and rebuild:
   - `rm -rf .casync-cache/store.castr mkosi.output/compose`
   - rerun build + `./scripts/casync-compose.sh`
2. If `refs/<ref>/latest.json` points to a bad build, update it to a known-good manifest/index pair.
3. If chunks are missing remotely, run a trusted main build with an empty local cache and publish enabled; this repopulates required chunks.
4. If integrity checks fail in CI, inspect:
   - `mkosi.output/compose/dedupe-stats.json`
   - `mkosi.output/compose/compose-manifest.json`
   - workflow summary for digest mismatches.
