#!/usr/bin/env bash
#
# Regenerate the xrt source patches from the upstream commit pinned in xrt.yaml.
#
# The sed/python transforms in this script are the SOURCE OF TRUTH. The generated
# patches/*.patch files are committed build artifacts consumed by flatpak-builder.
#
# Usage: bump `commit:` in xrt.yaml, then run:
#   ./modules/regenerate-patches.sh
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$MODULE_DIR/xrt.yaml"
PATCH_DIR="$MODULE_DIR/patches"

URL="$(awk '/url:/ {print $2; exit}' "$MANIFEST")"
COMMIT="$(awk '/commit:/ {print $2; exit}' "$MANIFEST")"
if [ -z "$URL" ] || [ -z "$COMMIT" ]; then
  echo "ERROR: could not parse url/commit from $MANIFEST" >&2
  exit 1
fi

echo "Regenerating patches from $URL @ $COMMIT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"

git clone --filter=blob:none "$URL" "$SRC"
git -C "$SRC" checkout --quiet "$COMMIT"
git -C "$SRC" submodule update --init --recursive --depth 1

mkdir -p "$PATCH_DIR"

# gen <relpath> <patch-filename>
# Expects "$SRC/<rel>.orig" to be the pristine snapshot and "$SRC/<rel>" the
# edited file. Fails loudly if the transform produced no change (pattern likely
# stale for the new commit). Writes a -p1 patch with root-relative a/ b/ headers.
gen() {
  local rel="$1" out="$2"
  if diff -q "$SRC/$rel.orig" "$SRC/$rel" >/dev/null; then
    echo "ERROR: transform for '$rel' produced no change (pattern no longer matches @ $COMMIT?)" >&2
    exit 1
  fi
  diff -u --label "a/$rel" --label "b/$rel" "$SRC/$rel.orig" "$SRC/$rel" \
    > "$PATCH_DIR/$out" || [ $? -eq 1 ]
  rm -f "$SRC/$rel.orig"
  echo "  wrote patches/$out"
}

# --- transform 1: disable python bindings ---
f="xrt/src/CMake/nativeLnx.cmake"
cp "$SRC/$f" "$SRC/$f.orig"
sed -i 's|xrt_add_subdirectory(python)|# xrt_add_subdirectory(python)|g' "$SRC/$f"
gen "$f" "0001-disable-python-bindings.patch"

# --- transform 2: stub out sys/sdt.h probes ---
f="xrt/src/runtime_src/core/common/detail/linux/trace.h"
cp "$SRC/$f" "$SRC/$f.orig"
sed -i 's|#include <sys/sdt.h>|#define STAP_PROBEV(...)\n#define DTRACE_PROBE(...)\n#define DTRACE_PROBE1(...)\n#define DTRACE_PROBE2(...)|g' "$SRC/$f"
gen "$f" "0002-stub-sdt-probes.patch"

# --- transform 3: xocl include order (include/1_2 before Boost) ---
f="xrt/src/runtime_src/xocl/CMakeLists.txt"
cp "$SRC/$f" "$SRC/$f.orig"
python3 - "$SRC/$f" <<'PY'
import sys
p = sys.argv[1]
c = open(p).read()
c = c.replace(
    "include_directories(\n  ${Boost_INCLUDE_DIRS}\n  ${XRT_SOURCE_DIR}/include/1_2\n)",
    "include_directories(BEFORE\n  ${XRT_SOURCE_DIR}/include/1_2\n)\ninclude_directories(\n  ${Boost_INCLUDE_DIRS}\n)")
open(p, "w").write(c)
PY
gen "$f" "0003-xocl-include-order.patch"

# --- transform 4: force debian package flavor ---
f="CMake/pkg.cmake"
cp "$SRC/$f" "$SRC/$f.orig"
sed -i 's|if("${XDNA_CPACK_LINUX_PKG_FLAVOR}" MATCHES "debian")|set(XDNA_CPACK_LINUX_PKG_FLAVOR "debian")\nif("${XDNA_CPACK_LINUX_PKG_FLAVOR}" MATCHES "debian")|g' "$SRC/$f"
gen "$f" "0004-force-debian-pkg-flavor.patch"

# --- transform 5: archive install dir honors XDG_DATA_HOME (matches xrt-smi platform_repo_path) ---
f="xrt/src/runtime_src/core/tools/xbutil2/smi_install_archive.sh"
cp "$SRC/$f" "$SRC/$f.orig"
sed -i 's|INSTALL_DIR="${HOME}/.local/share/xrt/${XRT_VERSION}/amdxdna/bins"|INSTALL_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/xrt/${XRT_VERSION}/amdxdna/bins"|' "$SRC/$f"
gen "$f" "0005-smi-archive-honor-xdg-data-home.patch"

# --- transform 6: throughput test reads executions[] report format (backport of upstream) ---
f="xrt/src/runtime_src/core/tools/common/tests/TestNPUThroughput.cpp"
cp "$SRC/$f" "$SRC/$f.orig"
python3 - "$SRC/$f" <<'PY'
import sys
p = sys.argv[1]
c = open(p).read()
old = '''    auto report = json::parse(runner.get_report());
    XBValidateUtils::logger(ptree, "Details", boost::str(boost::format("Average throughput: %.1f op/s") % report["cpu"]["throughput"].get<double>()));'''
new = '''    auto report = json::parse(runner.get_report());
    // Newer validation archives report throughput under executions[]; fall back to legacy top-level cpu
    const auto& tput = report.contains("executions") ? report.at("executions").at(0).at("cpu") : report.at("cpu");
    XBValidateUtils::logger(ptree, "Details", boost::str(boost::format("Average throughput: %.1f op/s") % tput.at("throughput").get<double>()));'''
c = c.replace(old, new)
open(p, "w").write(c)
PY
gen "$f" "0006-throughput-test-executions-format.patch"

echo "Done. Regenerated 6 patch(es) in $PATCH_DIR"
