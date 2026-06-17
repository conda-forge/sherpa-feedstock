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

# Sherpa's CMakeLists.txt re-validates every token of CMAKE_{C,CXX,Fortran}_FLAGS
# through check_<lang>_compiler_flag(), splitting the flags on whitespace first.
# This breaks conda's two-token "-isystem ${PREFIX}/include": the lone "-isystem"
# fails the check and is dropped, orphaning the bare "${PREFIX}/include" path.
# That bare path both hides headers like libzip's <zip.h> at compile time and is
# handed to the linker ("ld: ${PREFIX}/include: Is a directory") at link time.
# Collapse it to the joined single-token form "-isystem${PREFIX}/include" (gcc
# and clang accept -isystem with no space); this survives the filter intact and
# preserves the original -isystem semantics. CMAKE_FORCE_FLAGS=ON additionally
# tells Sherpa to keep the flags verbatim (otherwise the filter also drops
# conda's -fdebug-prefix-map).
search="-isystem ${PREFIX}/include"
replace="-isystem${PREFIX}/include"
export CFLAGS="${CFLAGS//${search}/${replace}}"
export CXXFLAGS="${CXXFLAGS//${search}/${replace}}"
export FFLAGS="${FFLAGS//${search}/${replace}}"

# On macOS, Sherpa links every shared library with "-undefined dynamic_lookup"
# (CMakeLists.txt), so cross-library references such as MODEL::as are emitted as
# flat-namespace undefined symbols rather than recorded two-level dependencies.
# conda's default "-Wl,-dead_strip_dylibs" then strips the load command for the
# dylib that actually provides such a symbol (e.g. libModelMain, which defines
# MODEL::as) because it sees no two-level use of it -- so at runtime dyld aborts
# with "symbol not found in flat namespace '__ZN5MODEL2asE'". Drop the flag so
# the linked dylibs stay loaded. No-op on Linux (its LDFLAGS lack the flag).
export LDFLAGS="${LDFLAGS//-Wl,-dead_strip_dylibs/}"

cmake ${CMAKE_ARGS} \
    -G Ninja \
    -DCMAKE_FORCE_FLAGS=ON \
    -DSHERPA_ENABLE_HEPMC3=ON \
    -DSHERPA_ENABLE_PYTHON=ON \
    -DCMAKE_CXX_STANDARD=17 \
    -S "${SRC_DIR}" \
    -B build
cmake build -LH
cmake --build build --parallel "${CPU_COUNT}"
cmake --install build

# Skip ctest when cross-compiling
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
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
