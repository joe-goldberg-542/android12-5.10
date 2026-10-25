#!/usr/bin/env bash
set -euo pipefail

KSU_OWNER=${KSU_OWNER:-LyraVoid}
KSU_REPO=${KSU_REPO:-FinaSU}
KSU_BRANCH=${KSU_BRANCH:-dev}
KSU_WANT=${KSU_WANT:-'ksud-*'}
OUT_DIR=${OUT_DIR:-$PWD/ksu-assets}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
curl_dl() { curl --connect-timeout 10 "$@"; }

[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is required (GitHub denies unauthenticated artifact downloads)"

API="https://api.github.com/repos/$KSU_OWNER/$KSU_REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

want() {
    local n=$1 p
    IFS='|' read -ra pats <<< "$KSU_WANT"
    for p in "${pats[@]}"; do
        case "$n" in
            $p) return 0 ;;
        esac
    done
    return 1
}

mkdir -p "$OUT_DIR"
run_ids=()
for page in 1 2 3 4 5; do
    mapfile -t ids < <(curl_dl -sfL "${AUTH[@]}" \
        "$API/actions/runs?branch=$KSU_BRANCH&status=success&per_page=10&page=$page" | \
        python3 -c "import json,sys; print('\n'.join(str(r['id']) for r in json.load(sys.stdin).get('workflow_runs',[])))")
    page_ids=()
    for id in "${ids[@]}"; do
        [ -n "$id" ] && page_ids+=("$id")
    done
    [ "${#page_ids[@]}" -eq 0 ] && break
    run_ids+=("${page_ids[@]}")

    for run_id in "${page_ids[@]}"; do
        mapfile -t art < <(curl_dl -sfL "${AUTH[@]}" \
            "$API/actions/runs/$run_id/artifacts?per_page=100" | \
            python3 -c "import json,sys; print('\n'.join(f\"{a['name']} {a['id']}\" for a in json.load(sys.stdin).get('artifacts',[])))")
        matched=()
        matched_ids=()
        for pair in "${art[@]}"; do
            n=${pair%% *}
            id=${pair#* }
            want "$n" || continue
            matched+=("$n")
            matched_ids+=("$id")
        done
        [ "${#matched[@]}" -gt 0 ] || { info "run $run_id has no wanted artifacts, skipping"; continue; }

        ok "using run $run_id ($KSU_OWNER/$KSU_REPO @ $KSU_BRANCH)"
        dl_pids=()
        dl_rc=0
        for i in "${!matched[@]}"; do
            n=${matched[$i]}
            aid=${matched_ids[$i]}
            [ -n "$aid" ] || die "artifact '$n' not found in run $run_id"
            ( curl_dl -fL --retry 3 -sS -o "$OUT_DIR/ksu-$n.zip" \
                -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
                "$API/actions/artifacts/$aid/zip" &&
                ok "ksu-$n.zip" ) & dl_pids+=("$!")
        done
        for dl_pid in "${dl_pids[@]}"; do
            wait "$dl_pid" || dl_rc=1
        done
        [ "$dl_rc" -eq 0 ] || die "one or more ksud artifact downloads failed"
        exit 0
    done
done
[ "${#run_ids[@]}" -gt 0 ] || die "no successful $KSU_OWNER/$KSU_REPO runs on $KSU_BRANCH"

die "no successful run with wanted artifacts on $KSU_BRANCH"
