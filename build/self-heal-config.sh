#!/usr/bin/env bash
set -euo pipefail

info() { printf '\033[1;34m[HEAL]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[HEAL]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[HEAL]\033[0m %s\n' "$*" >&2; exit 1; }

: "${ROOT_DIR:?ROOT_DIR not set - run under build/build.sh}"
: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${OUT_DIR:?OUT_DIR not set}"
: "${ARCH:?ARCH not set}"
: "${DEFCONFIG:?DEFCONFIG not set}"

MAKE_ARCH_ARGS=()
if [ -n "${LLVM:-}" ]; then
    MAKE_ARCH_ARGS+=(LLVM="${LLVM}")
fi
if [ -n "${LLVM_IAS:-}" ]; then
    MAKE_ARCH_ARGS+=(LLVM_IAS="${LLVM_IAS}")
fi
if [ -n "${CLOUDFOX_HOST_CC:-}" ]; then
    MAKE_ARCH_ARGS+=(HOSTCC="${CLOUDFOX_HOST_CC}")
fi
if [ -n "${CLOUDFOX_HOST_CXX:-}" ]; then
    MAKE_ARCH_ARGS+=(HOSTCXX="${CLOUDFOX_HOST_CXX}")
fi
MAKE_ARCH_ARGS+=(ARCH="${ARCH}")

run_make() { 
    local dir=$1 target=$2
    ( cd "$ROOT_DIR/$KERNEL_DIR" && make "${MAKE_ARCH_ARGS[@]}" O="${dir}" "${target}" )
}

cfg_arch=$ARCH
case "$cfg_arch" in
    x86_64|i386) cfg_arch=x86 ;;
esac

COMMITTED=${ROOT_DIR}/${KERNEL_DIR}/arch/${cfg_arch}/configs/${DEFCONFIG}
[ -f "$COMMITTED" ] || die "committed defconfig not found: $COMMITTED"

SCRATCH=$(mktemp -d "${OUT_DIR}/.self-heal.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

info "deriving canonical config in a pristine scratch dir"
run_make "$SCRATCH" "$DEFCONFIG"
run_make "$SCRATCH" savedefconfig
CANONICAL=$SCRATCH/defconfig
[ -f "$CANONICAL" ] || die "savedefconfig produced no output at $CANONICAL"

if cmp -s "$COMMITTED" "$CANONICAL"; then
    info "already healthy: $DEFCONFIG matches canonical savedefconfig"
    exit 0
fi

if diff -q \
    <(grep -E '^CONFIG_[A-Za-z0-9_]+=' "$CANONICAL" | sort) \
    <(grep -E '^CONFIG_[A-Za-z0-9_]+=' "$COMMITTED" | sort) >/dev/null 2>&1; then
    info "normalization detected: $DEFCONFIG differs only in symbol ordering, effective config identical; no repair needed"
    exit 0
fi

info "repair needed: $DEFCONFIG differs from canonical savedefconfig"

BACKUP="${COMMITTED}.self-heal-backup"
cp -a "$COMMITTED" "$BACKUP"
info "backed up the original defconfig"

cp -a "$CANONICAL" "$COMMITTED"
info "repair performed: committed defconfig rewritten from canonical candidate"

rm -f "${OUT_DIR}/.config" "${OUT_DIR}/.config.old"

for i in 1 2 3 4 5; do
    run_make "$OUT_DIR" "$DEFCONFIG" || {
        cp -a "$BACKUP" "$COMMITTED"
        die "repair rejected+restored: regeneration failed after rewriting $DEFCONFIG"
    }
    run_make "$OUT_DIR" savedefconfig || {
        cp -a "$BACKUP" "$COMMITTED"
        die "repair rejected+restored: savedefconfig failed after rewriting $DEFCONFIG"
    }
    
    if cmp -s "${OUT_DIR}/defconfig" "$CANONICAL"; then
        info "repair verified: regenerated config converged to canonical savedefconfig"
        rm -f "$BACKUP"
        
        if [ -d "$ROOT_DIR/$KERNEL_DIR/.git" ] && \
           git -C "$ROOT_DIR/$KERNEL_DIR" -c user.name="${GIT_BUILDER_NAME:-joe-goldberg-542}" \
               -c user.email="${GIT_BUILDER_EMAIL:-joe_goldberg_542@protonmail.com}" \
               commit -q --only -m "chore: self-heal $DEFCONFIG to canonical savedefconfig" -- \
               "arch/$cfg_arch/configs/$DEFCONFIG" 2>/dev/null; then
            info "committed repaired $DEFCONFIG (kernel version stays clean)"
        else
            warn "could not commit repaired $DEFCONFIG; kernel version may carry -dirty"
        fi
        exit 0
    fi
    info "iteration $i: regenerated config not yet stable; re-deriving"
done

cp -a "$BACKUP" "$COMMITTED"
rm -f "$BACKUP"
warn "repair rejected+restored: config did not converge to a fixed point"
diff -u "$COMMITTED" "$CANONICAL" >&2 || true
die "failed to converge: committed defconfig restored, build aborted."
