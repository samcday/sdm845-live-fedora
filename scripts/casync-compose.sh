#!/usr/bin/env bash
set -euo pipefail

EROFS_IMAGE="${COMPOSE_EROFS_IMAGE:-}"
OUTPUT_DIR="${COMPOSE_OUTPUT_DIR:-mkosi.output/compose}"
LOCAL_STORE_DIR="${COMPOSE_LOCAL_STORE_DIR:-.casync-cache/store.castr}"
CHUNK_SIZE="${COMPOSE_CHUNK_SIZE:-262144:1048576:4194304}"

OBJECT_PREFIX="${COMPOSE_OBJECT_PREFIX:-live-pocket-fedora}"
CHUNK_PREFIX="${COMPOSE_CHUNK_PREFIX:-${OBJECT_PREFIX}/casync/chunks}"
INDEX_PREFIX="${COMPOSE_INDEX_PREFIX:-${OBJECT_PREFIX}/casync/indexes}"
MANIFEST_PREFIX="${COMPOSE_MANIFEST_PREFIX:-${OBJECT_PREFIX}/casync/manifests}"
REFS_PREFIX="${COMPOSE_REFS_PREFIX:-${OBJECT_PREFIX}/casync/refs}"
IMAGE_PREFIX="${COMPOSE_IMAGE_PREFIX:-${OBJECT_PREFIX}/images}"

PUBLIC_BASE_URL="${COMPOSE_PUBLIC_BASE_URL:-https://bleeding.fastboop.win}"
ENABLE_PUBLISH_RAW="${COMPOSE_ENABLE_PUBLISH:-0}"
BUCKET="${COMPOSE_BUCKET:-}"
ENDPOINT_URL="${COMPOSE_ENDPOINT_URL:-${R2_ENDPOINT_URL:-}}"
USE_SUDO_CASYNC_RAW="${COMPOSE_USE_SUDO:-0}"

REPO="${GITHUB_REPOSITORY:-local/live-pocket-fedora}"
EVENT_NAME="${GITHUB_EVENT_NAME:-local}"
TARGET_REF="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-local}}"
BASE_LINEAGE_REF="${COMPOSE_BASE_LINEAGE_REF:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-main}}}"
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-0}"
WORKFLOW_NAME="${GITHUB_WORKFLOW:-local}"
WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-local}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${RUN_ID}"

if [[ -n "${GITHUB_SHA:-}" ]]; then
    COMMIT_SHA="${GITHUB_SHA}"
else
    COMMIT_SHA="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
fi

SHORT_SHA="${COMMIT_SHA:0:12}"
TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_ID="${RUN_ID}-${RUN_ATTEMPT}-${SHORT_SHA}"

INDEX_NAME="compose-${BUILD_ID}.caibx"
INDEX_PATH="${OUTPUT_DIR}/${INDEX_NAME}"
MANIFEST_PATH="${OUTPUT_DIR}/compose-manifest.json"
POINTER_LOCAL_PATH="${OUTPUT_DIR}/compose-latest-pointer.json"
BASE_POINTER_LOCAL_PATH="${OUTPUT_DIR}/base-latest-pointer.json"
PRE_SNAPSHOT_PATH="${OUTPUT_DIR}/store-pre.json"
POST_SNAPSHOT_PATH="${OUTPUT_DIR}/store-post.json"
REFERENCED_SNAPSHOT_PATH="${OUTPUT_DIR}/store-referenced.json"
DEDUPE_STATS_PATH="${OUTPUT_DIR}/dedupe-stats.json"
REMOTE_INDEX_PATH="${OUTPUT_DIR}/published-index.caibx"
REFERENCED_INDEX_PATH="${OUTPUT_DIR}/referenced-chunks.caibx"

SMOKE_IMAGE_PATH="${OUTPUT_DIR}/smoke-extract-image.ero"
REMOTE_SMOKE_IMAGE_PATH="${OUTPUT_DIR}/smoke-extract-remote-index.ero"

slugify_ref() {
    printf '%s' "$1" | tr '/:@' '-' | tr -cd 'a-zA-Z0-9._-'
}

url_join() {
    local base="$1"
    local suffix="$2"
    base="${base%/}"
    suffix="${suffix#/}"
    printf '%s/%s' "$base" "$suffix"
}

capture_store_snapshot() {
    local store_path="$1"
    local output_json="$2"
    python3 - "$store_path" "$output_json" <<'PY'
import json
import os
import sys

store = sys.argv[1]
output = sys.argv[2]
entries = {}
total_bytes = 0

if os.path.isdir(store):
    for root, _dirs, files in os.walk(store):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, store)
            size = os.path.getsize(full)
            entries[rel] = size
            total_bytes += size

with open(output, "w", encoding="utf-8") as f:
    json.dump(
        {
            "entries": entries,
            "total_files": len(entries),
            "total_bytes": total_bytes,
        },
        f,
        sort_keys=True,
    )
PY
}

to_bool() {
    case "${1}" in
        1|true|TRUE|yes|YES|on|ON)
            printf '1'
            ;;
        *)
            printf '0'
            ;;
    esac
}

resolve_erofs_image() {
    local override="${COMPOSE_EROFS_IMAGE:-}"
    local candidate=""
    local ero_files=()

    if [[ -n "${override}" ]]; then
        if [[ -f "${override}" ]]; then
            printf '%s\n' "${override}"
            return 0
        fi

        echo "missing erofs image: ${override}" >&2
        return 1
    fi

    for candidate in "mkosi.output/live-pocket-fedora.ero" "mkosi.output/image.ero"; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    shopt -s nullglob
    ero_files=(mkosi.output/*.ero)
    shopt -u nullglob

    if [[ "${#ero_files[@]}" -eq 1 ]]; then
        printf '%s\n' "${ero_files[0]}"
        return 0
    fi

    if [[ "${#ero_files[@]}" -gt 1 ]]; then
        echo "multiple erofs images found in mkosi.output; set COMPOSE_EROFS_IMAGE" >&2
        return 1
    fi

    echo "missing erofs image: expected mkosi.output/live-pocket-fedora.ero or mkosi.output/image.ero" >&2
    return 1
}

if [[ "$(to_bool "${USE_SUDO_CASYNC_RAW}")" == "1" ]]; then
    CASYNC_CMD=(sudo casync)
else
    CASYNC_CMD=(casync)
fi

mkdir -p "${OUTPUT_DIR}" "${LOCAL_STORE_DIR}"

if ! EROFS_IMAGE="$(resolve_erofs_image)"; then
    exit 1
fi

capture_store_snapshot "${LOCAL_STORE_DIR}" "${PRE_SNAPSHOT_PATH}"

"${CASYNC_CMD[@]}" make --store="${LOCAL_STORE_DIR}" --chunk-size="${CHUNK_SIZE}" "${INDEX_PATH}" "${EROFS_IMAGE}"

capture_store_snapshot "${LOCAL_STORE_DIR}" "${POST_SNAPSHOT_PATH}"

REFERENCED_STORE_DIR="$(mktemp -d "${OUTPUT_DIR}/referenced-store.XXXXXX")"
cleanup() {
    if [[ "$(to_bool "${USE_SUDO_CASYNC_RAW}")" == "1" ]]; then
        sudo rm -rf "${REFERENCED_STORE_DIR}" || true
    else
        rm -rf "${REFERENCED_STORE_DIR}" || true
    fi
}
trap cleanup EXIT

"${CASYNC_CMD[@]}" make --store="${REFERENCED_STORE_DIR}" --chunk-size="${CHUNK_SIZE}" "${REFERENCED_INDEX_PATH}" "${EROFS_IMAGE}"

capture_store_snapshot "${REFERENCED_STORE_DIR}" "${REFERENCED_SNAPSHOT_PATH}"

python3 - "${PRE_SNAPSHOT_PATH}" "${REFERENCED_SNAPSHOT_PATH}" "${DEDUPE_STATS_PATH}" <<'PY'
import json
import sys

before_path, referenced_path, output_path = sys.argv[1:4]

with open(before_path, "r", encoding="utf-8") as f:
    before = json.load(f)
with open(referenced_path, "r", encoding="utf-8") as f:
    referenced = json.load(f)

before_entries = before.get("entries", {})
referenced_entries = referenced.get("entries", {})

new_entries = {k: v for k, v in referenced_entries.items() if k not in before_entries}
new_bytes = sum(new_entries.values())
total_bytes = referenced.get("total_bytes", 0)
total_files = referenced.get("total_files", 0)

result = {
    "new_files": sorted(new_entries.keys()),
    "new_chunk_count": len(new_entries),
    "new_chunk_bytes": new_bytes,
    "total_chunk_count": total_files,
    "total_chunk_bytes": total_bytes,
    "reused_chunk_count": total_files - len(new_entries),
    "reused_chunk_bytes": total_bytes - new_bytes,
}

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(result, f, sort_keys=True)
PY

eval "$(python3 - "${DEDUPE_STATS_PATH}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)

print(f"NEW_CHUNK_COUNT={d['new_chunk_count']}")
print(f"NEW_CHUNK_BYTES={d['new_chunk_bytes']}")
print(f"TOTAL_CHUNK_COUNT={d['total_chunk_count']}")
print(f"TOTAL_CHUNK_BYTES={d['total_chunk_bytes']}")
print(f"REUSED_CHUNK_COUNT={d['reused_chunk_count']}")
print(f"REUSED_CHUNK_BYTES={d['reused_chunk_bytes']}")
PY
)"

EROFS_CASYNC_DIGEST="$("${CASYNC_CMD[@]}" digest "${EROFS_IMAGE}")"
INDEX_CASYNC_DIGEST="$("${CASYNC_CMD[@]}" digest --store="${LOCAL_STORE_DIR}" "${INDEX_PATH}")"

if [[ "${EROFS_CASYNC_DIGEST}" != "${INDEX_CASYNC_DIGEST}" ]]; then
    echo "index digest does not match EROFS image digest" >&2
    exit 1
fi

INDEX_SHA256="$(sha256sum "${INDEX_PATH}" | cut -d' ' -f1)"
INDEX_BYTES="$(stat -c '%s' "${INDEX_PATH}")"
EROFS_SHA256="$(sha256sum "${EROFS_IMAGE}" | cut -d' ' -f1)"
EROFS_BYTES="$(stat -c '%s' "${EROFS_IMAGE}")"

printf '%s\n' "${EROFS_CASYNC_DIGEST}" > "${OUTPUT_DIR}/image.ero.casync-digest"
printf '%s\n' "${INDEX_CASYNC_DIGEST}" > "${OUTPUT_DIR}/index.casync-digest"
printf '%s\n' "${INDEX_SHA256}" > "${OUTPUT_DIR}/index.sha256"
printf '%s\n' "${EROFS_SHA256}" > "${OUTPUT_DIR}/image.ero.sha256"

rm -f "${SMOKE_IMAGE_PATH}" "${REMOTE_SMOKE_IMAGE_PATH}"

"${CASYNC_CMD[@]}" extract --store="${LOCAL_STORE_DIR}" "${INDEX_PATH}" "${SMOKE_IMAGE_PATH}"

SMOKE_IMAGE_SHA256="$(sha256sum "${SMOKE_IMAGE_PATH}" | cut -d' ' -f1)"

if [[ "${SMOKE_IMAGE_SHA256}" != "${EROFS_SHA256}" ]]; then
    echo "smoke extraction hash mismatch for ${EROFS_IMAGE}" >&2
    exit 1
fi

TARGET_REF_SLUG="$(slugify_ref "${TARGET_REF}")"
BASE_REF_SLUG="$(slugify_ref "${BASE_LINEAGE_REF}")"

if [[ -z "${TARGET_REF_SLUG}" ]]; then
    TARGET_REF_SLUG="unknown"
fi

if [[ -z "${BASE_REF_SLUG}" ]]; then
    BASE_REF_SLUG="main"
fi

INDEX_KEY="${INDEX_PREFIX}/${INDEX_NAME}"
MANIFEST_KEY="${MANIFEST_PREFIX}/${BUILD_ID}.json"
IMAGE_KEY="${IMAGE_PREFIX}/${BUILD_ID}.ero"
REF_POINTER_KEY="${REFS_PREFIX}/${TARGET_REF_SLUG}/latest.json"
BASE_POINTER_KEY="${REFS_PREFIX}/${BASE_REF_SLUG}/latest.json"

INDEX_S3_COORD=""
MANIFEST_S3_COORD=""
CHUNK_S3_COORD=""
IMAGE_S3_COORD=""
INDEX_PUBLIC_URL=""
MANIFEST_PUBLIC_URL=""
CHUNK_PUBLIC_PREFIX=""
IMAGE_PUBLIC_URL=""

if [[ -n "${BUCKET}" ]]; then
    INDEX_S3_COORD="s3://${BUCKET}/${INDEX_KEY}"
    MANIFEST_S3_COORD="s3://${BUCKET}/${MANIFEST_KEY}"
    CHUNK_S3_COORD="s3://${BUCKET}/${CHUNK_PREFIX}/"
    IMAGE_S3_COORD="s3://${BUCKET}/${IMAGE_KEY}"
fi

if [[ -n "${PUBLIC_BASE_URL}" ]]; then
    INDEX_PUBLIC_URL="$(url_join "${PUBLIC_BASE_URL}" "${INDEX_KEY}")"
    MANIFEST_PUBLIC_URL="$(url_join "${PUBLIC_BASE_URL}" "${MANIFEST_KEY}")"
    CHUNK_PUBLIC_PREFIX="$(url_join "${PUBLIC_BASE_URL}" "${CHUNK_PREFIX}/")"
    IMAGE_PUBLIC_URL="$(url_join "${PUBLIC_BASE_URL}" "${IMAGE_KEY}")"
fi

BASE_MANIFEST_S3=""
BASE_INDEX_S3=""
BASE_MANIFEST_URL=""
BASE_INDEX_URL=""
BASE_COMMIT=""

ENABLE_PUBLISH="$(to_bool "${ENABLE_PUBLISH_RAW}")"

if [[ "${ENABLE_PUBLISH}" == "1" ]]; then
    if [[ -z "${BUCKET}" || -z "${ENDPOINT_URL}" || -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        echo "publish requested but storage credentials/configuration are incomplete; publish disabled" >&2
        ENABLE_PUBLISH="0"
    fi
fi

if [[ "${ENABLE_PUBLISH}" == "1" ]]; then
    if aws s3 cp "s3://${BUCKET}/${BASE_POINTER_KEY}" "${BASE_POINTER_LOCAL_PATH}" --endpoint-url "${ENDPOINT_URL}" --only-show-errors 2>/dev/null; then
        eval "$(python3 - "${BASE_POINTER_LOCAL_PATH}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)

for key in ["manifest_s3", "index_s3", "manifest_url", "index_url", "commit"]:
    v = d.get(key, "")
    key_upper = key.upper()
    escaped = str(v).replace("'", "'\"'\"'")
    print(f"BASE_{key_upper}='{escaped}'")
PY
)"

        BASE_MANIFEST_S3="${BASE_MANIFEST_S3:-}"
        BASE_INDEX_S3="${BASE_INDEX_S3:-}"
        BASE_MANIFEST_URL="${BASE_MANIFEST_URL:-}"
        BASE_INDEX_URL="${BASE_INDEX_URL:-}"
        BASE_COMMIT="${BASE_COMMIT:-}"
    fi
fi

MKOSI_VERSION="$(mkosi --version 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//')"
CASYNC_VERSION="$(casync --version 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//')"
AWS_VERSION=""
if command -v aws >/dev/null 2>&1; then
    AWS_VERSION="$(aws --version 2>&1)"
fi

export REPO
export WORKFLOW_NAME
export WORKFLOW_REF
export EVENT_NAME
export COMMIT_SHA
export TARGET_REF
export RUN_ID
export RUN_ATTEMPT
export RUN_URL
export TIMESTAMP_UTC
export BUILD_ID
export BASE_LINEAGE_REF
export BASE_MANIFEST_S3
export BASE_MANIFEST_URL
export BASE_INDEX_S3
export BASE_INDEX_URL
export BASE_COMMIT
export EROFS_IMAGE
export EROFS_SHA256
export EROFS_CASYNC_DIGEST
export EROFS_BYTES
export IMAGE_S3_COORD
export IMAGE_PUBLIC_URL
export INDEX_PATH
export INDEX_SHA256
export INDEX_CASYNC_DIGEST
export INDEX_BYTES
export INDEX_S3_COORD
export INDEX_PUBLIC_URL
export CHUNK_PREFIX
export CHUNK_S3_COORD
export CHUNK_PUBLIC_PREFIX
export TOTAL_CHUNK_COUNT
export TOTAL_CHUNK_BYTES
export NEW_CHUNK_COUNT
export NEW_CHUNK_BYTES
export REUSED_CHUNK_COUNT
export REUSED_CHUNK_BYTES
export RUNNER_OS
export RUNNER_ARCH
export RUNNER_NAME
export MKOSI_VERSION
export CASYNC_VERSION
export AWS_VERSION
export ENABLE_PUBLISH
export BUCKET
export ENDPOINT_URL
export MANIFEST_S3_COORD
export MANIFEST_PUBLIC_URL
export TARGET_REF_SLUG
export MANIFEST_KEY
export INDEX_KEY
export IMAGE_KEY
export CHUNK_SIZE

python3 - "${MANIFEST_PATH}" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]

def maybe(value):
    return value if value else None

manifest = {
    "schema_version": 1,
    "kind": "live-pocket-fedora.compose",
    "build": {
        "repository": os.environ["REPO"],
        "workflow": os.environ["WORKFLOW_NAME"],
        "workflow_ref": os.environ["WORKFLOW_REF"],
        "event_name": os.environ["EVENT_NAME"],
        "commit": os.environ["COMMIT_SHA"],
        "ref": os.environ["TARGET_REF"],
        "run_id": os.environ["RUN_ID"],
        "run_attempt": os.environ["RUN_ATTEMPT"],
        "run_url": os.environ["RUN_URL"],
        "timestamp_utc": os.environ["TIMESTAMP_UTC"],
        "build_id": os.environ["BUILD_ID"],
    },
    "lineage": {
        "base_ref": os.environ["BASE_LINEAGE_REF"],
        "base_manifest_s3": maybe(os.environ.get("BASE_MANIFEST_S3", "")),
        "base_manifest_url": maybe(os.environ.get("BASE_MANIFEST_URL", "")),
        "base_index_s3": maybe(os.environ.get("BASE_INDEX_S3", "")),
        "base_index_url": maybe(os.environ.get("BASE_INDEX_URL", "")),
        "base_commit": maybe(os.environ.get("BASE_COMMIT", "")),
    },
    "artifacts": {
        "erofs_image": {
            "path": os.environ["EROFS_IMAGE"],
            "sha256": os.environ["EROFS_SHA256"],
            "digest": {
                "algorithm": "casync-sha512-256",
                "value": os.environ["EROFS_CASYNC_DIGEST"],
            },
            "size_bytes": int(os.environ["EROFS_BYTES"]),
            "s3": maybe(os.environ.get("IMAGE_S3_COORD", "")),
            "url": maybe(os.environ.get("IMAGE_PUBLIC_URL", "")),
        },
        "casync_blob_index": {
            "path": os.environ["INDEX_PATH"],
            "sha256": os.environ["INDEX_SHA256"],
            "chunk_size": os.environ["CHUNK_SIZE"],
            "digest": {
                "algorithm": "casync-sha512-256",
                "value": os.environ["INDEX_CASYNC_DIGEST"],
            },
            "size_bytes": int(os.environ["INDEX_BYTES"]),
            "s3": maybe(os.environ.get("INDEX_S3_COORD", "")),
            "url": maybe(os.environ.get("INDEX_PUBLIC_URL", "")),
        },
        "chunk_store": {
            "prefix": os.environ["CHUNK_PREFIX"],
            "s3_prefix": maybe(os.environ.get("CHUNK_S3_COORD", "")),
            "url_prefix": maybe(os.environ.get("CHUNK_PUBLIC_PREFIX", "")),
            "total_chunks": int(os.environ["TOTAL_CHUNK_COUNT"]),
            "total_bytes": int(os.environ["TOTAL_CHUNK_BYTES"]),
            "new_chunks": int(os.environ["NEW_CHUNK_COUNT"]),
            "new_bytes": int(os.environ["NEW_CHUNK_BYTES"]),
            "reused_chunks": int(os.environ["REUSED_CHUNK_COUNT"]),
            "reused_bytes": int(os.environ["REUSED_CHUNK_BYTES"]),
        },
    },
    "provenance": {
        "runner": {
            "os": os.environ.get("RUNNER_OS", "unknown"),
            "arch": os.environ.get("RUNNER_ARCH", "unknown"),
            "name": os.environ.get("RUNNER_NAME", "unknown"),
        },
        "tools": {
            "mkosi": os.environ.get("MKOSI_VERSION", ""),
            "casync": os.environ.get("CASYNC_VERSION", ""),
            "awscli": os.environ.get("AWS_VERSION", ""),
        },
    },
    "publish": {
        "enabled": os.environ["ENABLE_PUBLISH"] == "1",
        "bucket": maybe(os.environ.get("BUCKET", "")),
        "endpoint": maybe(os.environ.get("ENDPOINT_URL", "")),
        "manifest_s3": maybe(os.environ.get("MANIFEST_S3_COORD", "")),
        "manifest_url": maybe(os.environ.get("MANIFEST_PUBLIC_URL", "")),
    },
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY

python3 - "${POINTER_LOCAL_PATH}" <<'PY'
import json
import os
import sys

pointer_path = sys.argv[1]

pointer = {
    "schema_version": 1,
    "updated_at": os.environ["TIMESTAMP_UTC"],
    "ref": os.environ["TARGET_REF"],
    "ref_slug": os.environ["TARGET_REF_SLUG"],
    "build_id": os.environ["BUILD_ID"],
    "commit": os.environ["COMMIT_SHA"],
    "manifest_key": os.environ["MANIFEST_KEY"],
    "manifest_s3": os.environ.get("MANIFEST_S3_COORD", ""),
    "manifest_url": os.environ.get("MANIFEST_PUBLIC_URL", ""),
    "index_key": os.environ["INDEX_KEY"],
    "index_s3": os.environ.get("INDEX_S3_COORD", ""),
    "index_url": os.environ.get("INDEX_PUBLIC_URL", ""),
    "chunk_prefix": os.environ["CHUNK_PREFIX"],
    "chunk_s3_prefix": os.environ.get("CHUNK_S3_COORD", ""),
    "chunk_url_prefix": os.environ.get("CHUNK_PUBLIC_PREFIX", ""),
    "image_key": os.environ["IMAGE_KEY"],
    "image_s3": os.environ.get("IMAGE_S3_COORD", ""),
    "image_url": os.environ.get("IMAGE_PUBLIC_URL", ""),
    "new_chunks": int(os.environ["NEW_CHUNK_COUNT"]),
    "new_chunk_bytes": int(os.environ["NEW_CHUNK_BYTES"]),
    "publish_enabled": os.environ["ENABLE_PUBLISH"] == "1",
}

with open(pointer_path, "w", encoding="utf-8") as f:
    json.dump(pointer, f, indent=2, sort_keys=True)
    f.write("\n")
PY

if [[ "${ENABLE_PUBLISH}" == "1" ]]; then
    aws s3 sync "${LOCAL_STORE_DIR}/" "s3://${BUCKET}/${CHUNK_PREFIX}/" \
        --endpoint-url "${ENDPOINT_URL}" \
        --size-only \
        --no-progress \
        --only-show-errors

    aws s3 cp "${INDEX_PATH}" "s3://${BUCKET}/${INDEX_KEY}" \
        --endpoint-url "${ENDPOINT_URL}" \
        --content-type application/octet-stream \
        --only-show-errors

    aws s3 cp "${EROFS_IMAGE}" "s3://${BUCKET}/${IMAGE_KEY}" \
        --endpoint-url "${ENDPOINT_URL}" \
        --content-type application/octet-stream \
        --only-show-errors

    aws s3 cp "${MANIFEST_PATH}" "s3://${BUCKET}/${MANIFEST_KEY}" \
        --endpoint-url "${ENDPOINT_URL}" \
        --content-type application/json \
        --only-show-errors
    aws s3 cp "s3://${BUCKET}/${INDEX_KEY}" "${REMOTE_INDEX_PATH}" \
        --endpoint-url "${ENDPOINT_URL}" \
        --only-show-errors

    "${CASYNC_CMD[@]}" extract --store="${LOCAL_STORE_DIR}" "${REMOTE_INDEX_PATH}" "${REMOTE_SMOKE_IMAGE_PATH}"

    REMOTE_SMOKE_IMAGE_SHA256="$(sha256sum "${REMOTE_SMOKE_IMAGE_PATH}" | cut -d' ' -f1)"
    if [[ "${REMOTE_SMOKE_IMAGE_SHA256}" != "${EROFS_SHA256}" ]]; then
        echo "remote smoke extraction hash mismatch for ${EROFS_IMAGE}" >&2
        exit 1
    fi

    aws s3 cp "${POINTER_LOCAL_PATH}" "s3://${BUCKET}/${REF_POINTER_KEY}" \
        --endpoint-url "${ENDPOINT_URL}" \
        --content-type application/json \
        --only-show-errors
else
    echo "publish disabled; produced local compose manifest and index only" >&2
fi

echo "casync dedupe stats:"
echo "  new chunks: ${NEW_CHUNK_COUNT} (${NEW_CHUNK_BYTES} bytes)"
echo "  reused chunks: ${REUSED_CHUNK_COUNT} (${REUSED_CHUNK_BYTES} bytes)"
echo "  total chunks: ${TOTAL_CHUNK_COUNT} (${TOTAL_CHUNK_BYTES} bytes)"
echo "  publish enabled: ${ENABLE_PUBLISH}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### casync compose"
        echo ""
        echo "- Build ID: \`${BUILD_ID}\`"
        echo "- EROFS digest: \`${EROFS_CASYNC_DIGEST}\`"
        echo "- Index sha256: \`${INDEX_SHA256}\`"
        echo "- Chunk bytes: total=${TOTAL_CHUNK_BYTES}, new=${NEW_CHUNK_BYTES}, reused=${REUSED_CHUNK_BYTES}"
        echo "- Publish enabled: ${ENABLE_PUBLISH}"
        if [[ -n "${MANIFEST_S3_COORD}" ]]; then
            echo "- Manifest: \`${MANIFEST_S3_COORD}\`"
        fi
        if [[ -n "${INDEX_S3_COORD}" ]]; then
            echo "- Index: \`${INDEX_S3_COORD}\`"
        fi
        if [[ -n "${CHUNK_S3_COORD}" ]]; then
            echo "- Chunk store: \`${CHUNK_S3_COORD}\`"
        fi
    } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "compose_manifest_path=${MANIFEST_PATH}"
        echo "compose_manifest_s3=${MANIFEST_S3_COORD}"
        echo "compose_manifest_url=${MANIFEST_PUBLIC_URL}"
        echo "compose_index_path=${INDEX_PATH}"
        echo "compose_index_s3=${INDEX_S3_COORD}"
        echo "compose_index_url=${INDEX_PUBLIC_URL}"
        echo "compose_chunk_prefix_s3=${CHUNK_S3_COORD}"
        echo "compose_chunk_prefix_url=${CHUNK_PUBLIC_PREFIX}"
        echo "compose_image_s3=${IMAGE_S3_COORD}"
        echo "compose_image_url=${IMAGE_PUBLIC_URL}"
        echo "compose_erofs_digest=${EROFS_CASYNC_DIGEST}"
        echo "compose_index_digest=${INDEX_CASYNC_DIGEST}"
        echo "compose_index_sha256=${INDEX_SHA256}"
        echo "compose_new_chunk_count=${NEW_CHUNK_COUNT}"
        echo "compose_new_chunk_bytes=${NEW_CHUNK_BYTES}"
        echo "compose_reused_chunk_count=${REUSED_CHUNK_COUNT}"
        echo "compose_reused_chunk_bytes=${REUSED_CHUNK_BYTES}"
        echo "compose_total_chunk_count=${TOTAL_CHUNK_COUNT}"
        echo "compose_total_chunk_bytes=${TOTAL_CHUNK_BYTES}"
        echo "compose_publish_enabled=${ENABLE_PUBLISH}"
    } >> "${GITHUB_OUTPUT}"
fi
