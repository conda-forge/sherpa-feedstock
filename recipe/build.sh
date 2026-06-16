#!/usr/bin/env bash

set -x

# Get an updated config.sub and config.guess
cp ${BUILD_PREFIX}/share/gnuconfig/config.* .

# For Sherpa v2, remove specific linker flags from LDFLAGS to ensure all libraries
# have symbols defined after the packaging step
if [[ "${build_platform}" == linux-* ]]; then
    # On Linux remove '--as-needed' flag
    # c.f. https://linux.die.net/man/1/ld
    export LDFLAGS="$(echo $LDFLAGS | sed 's/ -Wl,--as-needed//g')"
else
    # On macOS remove '-dead_strip_dylibs' flag
    # c.f. https://github.com/AnacondaRecipes/intel_repack-feedstock/issues/8
    export LDFLAGS="$(echo $LDFLAGS | sed 's/ -Wl,-dead_strip_dylibs//g')"
fi

autoreconf --install

./configure --help

# Sherpa v2 is Python 2 only, so disable Python
./configure \
    --prefix=$PREFIX \
    --enable-hepmc2=$PREFIX \
    --enable-lhapdf=$PREFIX \
    --with-sqlite3=$PREFIX \
    CXX="$CXX" \
    CXXFLAGS="$CXXFLAGS" \
    LDFLAGS="$LDFLAGS" \
    PYTHON=""

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
  make check --jobs="${CPU_COUNT}"
fi

make install

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
