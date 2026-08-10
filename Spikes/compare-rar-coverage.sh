#!/bin/sh
#
# T-12 technical verification: compares UnRAR (QooUnrarBridge) vs
# libarchive's own RAR reader (CLibarchive) on a corpus of real .rar files.
#
# We don't have real-world .cbr samples (0-2 in 17_実装ロードマップ.md is
# explicitly deferred until such samples exist). Instead this uses
# libarchive's own RAR test corpus (Tests/*.rar.uu under libarchive/test/,
# BSD-2-Clause, bundled with the libarchive source we already vendor) —
# real, valid (and some deliberately-invalid) .rar files covering RAR4,
# RAR5, solid archives, multi-volume sets, encryption, and known malformed-
# input regression cases. It is NOT representative of typical real-world
# manga/doujin .cbr files; treat the numbers as a rough signal, not a
# final verdict. See Spikes/README.md for the actual comparison results
# and caveats.
#
# Usage: Spikes/compare-rar-coverage.sh

set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBARCHIVE_VERSION="3.8.9"
LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.gz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qoo-rar-coverage.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "==> fetching libarchive source (for its RAR test corpus only)"
curl -sL -o "${WORK}/libarchive.tar.gz" "${LIBARCHIVE_URL}"
tar xzf "${WORK}/libarchive.tar.gz" -C "${WORK}"
TEST_DIR="${WORK}/libarchive-${LIBARCHIVE_VERSION}/libarchive/test"

SAMPLES="${WORK}/samples"
mkdir -p "${SAMPLES}"
echo "==> decoding .rar.uu fixtures"
count=0
for f in "${TEST_DIR}"/*.rar.uu; do
    base="$(basename "${f}" .uu)"
    if uudecode -o "${SAMPLES}/${base}" "${f}" 2>/dev/null; then
        count=$((count + 1))
    fi
done
echo "==> decoded ${count} samples"

echo "==> building spikes"
(cd "${ROOT_DIR}" && ./Scripts/build-libarchive.sh > /dev/null && ./Scripts/build-unrar.sh > /dev/null && swift build > /dev/null)
BIN_DIR="$(cd "${ROOT_DIR}" && swift build --show-bin-path)"

RESULTS="${WORK}/results.tsv"
: > "${RESULTS}"
for f in "${SAMPLES}"/*.rar; do
    name="$(basename "${f}")"
    if "${BIN_DIR}/UnrarSpike" list "${f}" > /tmp/qoo-u.out 2>/tmp/qoo-u.err; then
        u_status="OK"
    else
        u_status="FAIL"
    fi
    if "${BIN_DIR}/LibarchiveSpike" list "${f}" > /tmp/qoo-l.out 2>/tmp/qoo-l.err; then
        l_status="OK"
    else
        l_status="FAIL"
    fi
    printf "%s\t%s\t%s\n" "${name}" "${u_status}" "${l_status}" >> "${RESULTS}"
done

echo "==> summary"
awk -F'\t' '
    { u[$2]++; l[$3]++; if ($2=="OK" && $3=="OK") both_ok++; if ($2=="FAIL" && $3=="FAIL") both_fail++ }
    END {
        total = NR
        printf "total samples:        %d\n", total
        printf "UnRAR OK:              %d\n", u["OK"]+0
        printf "libarchive OK:         %d\n", l["OK"]+0
        printf "both OK:               %d\n", both_ok+0
        printf "both FAIL:             %d\n", both_fail+0
    }
' "${RESULTS}"

echo
echo "==> UnRAR OK, libarchive FAIL:"
awk -F'\t' '$2=="OK" && $3=="FAIL" {print "  " $1}' "${RESULTS}"
echo
echo "==> libarchive OK, UnRAR FAIL:"
awk -F'\t' '$2=="FAIL" && $3=="OK" {print "  " $1}' "${RESULTS}"
