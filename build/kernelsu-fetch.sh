#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=${0##*/}

# ==> SETTINGS FOR OFFICIAL KERNELSU INTEGRATION <==
KSU_OWNER=${KSU_OWNER:-Baka-SU}
KSU_REPO=${KSU_REPO:-BakaSU}
KSU_BRANCH=${KSU_BRANCH:-main}
KSUD_TARGETS=${KSUD_TARGETS:-"aarch64-linux-android armv7-linux-androideabi"}
KSU_PREBUILT_BASE=${KSU_PREBUILT_BASE:-}
OUT_DIR=${OUT_DIR:-$PWD/kernelsu}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
curl_dl() { curl --connect-timeout 10 "$@"; }

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [options]

Downloads the Official KernelSU binaries (arm64 + armv7) that patch a kernel
into an existing boot image on device.

Environment:
  KSU_OWNER          KernelSU repository owner (default: tiann)
  KSU_REPO           KernelSU repository repo (default: KernelSU)
  KSU_BRANCH         Branch of the latest run (default: main)
  KSUD_TARGETS       Space-separated ksud Android targets (default:
                     aarch64-linux-android armv7-linux-androideabi)
  KSU_PREBUILT_BASE  Release base URL holding ksu-ksud-*.zip assets (optional)
  OUT_DIR            Output directory (default: ./kernelsu)
  GITHUB_TOKEN       Token for the actions-API fallback

Options:
  -h, --help         Show this help
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

API="https://api.github.com/repos/$KSU_OWNER/$KSU_REPO"

download_zip() {
    local zip=$1 prebuilt=$2 artifact=$3 aid

    if [ -n "$KSU_PREBUILT_BASE" ]; then
        if curl_dl -fL --retry 3 -sS -o "$zip" "$KSU_PREBUILT_BASE/ksu-$prebuilt.zip" 2>/dev/null; then
            ok "ksu-$prebuilt.zip from prebuilts release"
            return 0
        fi
        if [ -n "$GITHUB_TOKEN" ]; then
            local path repo_path tag url
            path=${KSU_PREBUILT_BASE#https://github.com/}
            repo_path=${path%%/releases/*}
            tag=${path##*/}
            url=$(curl_dl -sfL -H "Authorization: Bearer $GITHUB_TOKEN" \
                "https://api.github.com/repos/$repo_path/releases/tags/$tag" 2>/dev/null | \
                python3 -c "import json,sys; d=json.load(sys.stdin); a=[x for x in d.get('assets',[]) if x['name']==sys.argv[1]]; print(a[0]['url'] if a else '')" "ksu-$prebuilt.zip" 2>/dev/null || true)
            if [ -n "$url" ] && curl_dl -fL --retry 3 -sS -o "$zip" \
                -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/octet-stream" \
                "$url" 2>/dev/null; then
                ok "ksu-$prebuilt.zip from prebuilts release (API)"
                return 0
            fi
        fi
    fi

    [ -n "$GITHUB_TOKEN" ] || die "no prebuilt asset ksu-$prebuilt.zip and no GITHUB_TOKEN for the actions-API fallback"
    [ -n "${RUN_ID:-}" ] || RUN_ID=$(curl_dl -sfL -H "Authorization: Bearer $GITHUB_TOKEN" \
        "$API/actions/runs?branch=$KSU_BRANCH&status=success&per_page=1" 2>/dev/null | \
        python3 -c "import json,sys; r=json.load(sys.stdin).get('workflow_runs',[]); print(r[0]['id'] if r else '')" || true)
    [ -n "$RUN_ID" ] || die "no successful $KSU_OWNER/$KSU_REPO run on $KSU_BRANCH"
    aid=$(curl_dl -sfL -H "Authorization: Bearer $GITHUB_TOKEN" \
        "$API/actions/runs/$RUN_ID/artifacts?name=$artifact" | \
        python3 -c "import json,sys; a=json.load(sys.stdin).get('artifacts',[]); print(a[0]['id'] if a else '')" || true)
    [ -n "$aid" ] || die "artifact '$artifact' not found in run $RUN_ID"
    curl_dl -fL --retry 3 -sS -o "$zip" \
        -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
        "$API/actions/artifacts/$aid/zip"
    ok "$artifact artifact (run $RUN_ID)"
}

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.zip
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

prepare_target() {
    local target=$1 bin
    download_zip "$work/ksud-$target.zip" "ksud-$target" "ksud-$target" || return 1
    unzip -oq "$work/ksud-$target.zip" -d "$work/ksud-$target" || return 1
    bin=$(find "$work/ksud-$target" -type f -name ksud -print -quit)
    [ -n "$bin" ] || return 1
    cp -f "$bin" "$OUT_DIR/ksud-$target"
    chmod 755 "$OUT_DIR/ksud-$target"
    ok "ksud-$target"
}

pids=() rc=0
for target in $KSUD_TARGETS; do
    prepare_target "$target" & pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
done
[ "$rc" -eq 0 ] || die "one or more ksud downloads failed"

ok "Flash binaries ready in $OUT_DIR"
