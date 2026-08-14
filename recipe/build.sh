#!/usr/bin/env bash

set -x
set -e
set -u
set -o pipefail

# A release tarball has no .git, so Sherpa's CMakeLists.txt records the build's
# git branch as "unknownurl". At runtime Sherpa then prints
#   "WARNING: You are using an unsupported development branch."
# because it only treats branches whose name starts with "rel-" as releases
# (c.f. ATOOLS/Org/Run_Parameter.C::PrintGitVersion). Set ${PKG_VERSION} as the
# release.
if ! grep -q 'set(GITURL "unknownurl")' "${SRC_DIR}/CMakeLists.txt"; then
    echo "ERROR: Sherpa git-info fallback not found; the dev-branch warning fix needs updating" >&2
    exit 1
fi
sed -i \
    -e "s|set(GITURL \"unknownurl\")|set(GITURL \"rel-${PKG_VERSION}\")|" \
    -e "s|set(GITREV \"unknownrevision\")|set(GITREV \"v${PKG_VERSION}\")|" \
    "${SRC_DIR}/CMakeLists.txt"

# Sherpa's shared libraries have incomplete inter-library link dependencies and
# rely on the executable loading every library into one global symbol scope (its
# libs are built with undefined symbols left to resolve at runtime). conda's
# default link-time GC flags prune libraries whose symbols a given object does
# not *directly* reference, which breaks any isolated consumer that must resolve
# those cross-library symbols on its own:
#   * Linux "-Wl,--as-needed" drops e.g. libYFSCEEX from _Sherpa.so's DT_NEEDED,
#     so "import Sherpa" fails with
#     "libYFSMain.so: undefined symbol: YFS::Ceex_Base::Ceex_Base(...)".
#   * macOS "-Wl,-dead_strip_dylibs" drops e.g. libModelMain, so Sherpa aborts
#     with "symbol not found in flat namespace '__ZN5MODEL2asE'" (MODEL::as).
# Drop both so the linked libraries stay in DT_NEEDED / load commands. Each
# substitution is a no-op on the platform whose LDFLAGS lack that flag.
export LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"
export LDFLAGS="${LDFLAGS//-Wl,-dead_strip_dylibs/}"

cmake ${CMAKE_ARGS} \
    -G Ninja \
    -DCMAKE_FORCE_FLAGS=ON \
    -DSHERPA_ENABLE_HEPMC3=ON \
    -DSHERPA_ENABLE_GZIP=ON \
    -DSHERPA_ENABLE_PYTHON=ON \
    -DCMAKE_CXX_STANDARD=17 \
    -DSHERPA_ENABLE_TESTING=ON \
    -S "${SRC_DIR}" \
    -B build
cmake build -LH
cmake --build build --parallel "${CPU_COUNT}"
cmake --install build

# Skip ctest when cross-compiling
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
  export CMAKE_GENERATOR="Ninja"
  ctest --test-dir build
fi

# Sherpa's autoconf-generated wrapper scripts bake CXX/CC in as the build
# compiler (e.g. arm64-apple-darwin20.0.0-clang++). Rewrite these to the
# generic name (clang++/g++) so they resolve at runtime via the clangxx/gxx
# run-deps, strip build-prefix paths, and drop build-only flags.
declare -a generated_scripts=(
    "${PREFIX}/bin/Sherpa-config"
    "${PREFIX}/bin/Sherpa-generate-model"
    "${PREFIX}/bin/make2scons"
    "${PREFIX}/share/SHERPA-MC/makelibs"
)
for script in "${generated_scripts[@]}"; do
    [[ -f "${script}" ]] || continue
    sed -i \
        -e "s|${BUILD_PREFIX}/bin/||g" \
        -e "s|${HOST}-||g" \
        -e "s| -Wl,--no-as-needed||g" \
        -e "s| -fdebug-prefix-map=[^ '\"]*||g" \
        "${script}"
done

# Sanity check: fail loudly if any build-sandbox path survived the scrub
# above (e.g. a -I/-L/--sysroot entry we did not anticipate), rather than
# silently shipping a reference to the now-gone build environment.
if grep -l -e "${BUILD_PREFIX}" -e "${SRC_DIR}" "${generated_scripts[@]}" 2>/dev/null; then
    echo "ERROR: build-sandbox paths survived in the generated scripts listed above" >&2
    exit 1
fi
