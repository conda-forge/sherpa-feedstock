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

# Sherpa's autoconf-generated wrapper scripts (Sherpa-config, make2scons,
# Sherpa-generate-model, makelibs) bake the values of CXX, CC, FC,
# CXXFLAGS, etc. directly into the installed files. Conda relocates the
# host-prefix placeholder at install time, but the build-prefix paths
# (cross-compiler binaries and -fdebug-prefix-map entries pointing at
# the source tree) are not rewritten and would survive into the
# packaged scripts as references to the now-gone build sandbox.
# Replace the cross-compiler paths with their generic command names
# and drop the build-only -fdebug-prefix-map flags so the scripts work
# on a user's system after install.
declare -a generated_scripts=(
    "${PREFIX}/bin/Sherpa-config"
    "${PREFIX}/bin/Sherpa-generate-model"
    "${PREFIX}/bin/make2scons"
    "${PREFIX}/share/SHERPA-MC/makelibs"
)
for script in "${generated_scripts[@]}"; do
    [[ -f "${script}" ]] || continue
    sed -i \
        -e "s|${BUILD_PREFIX}/bin/${HOST}-c++|c++|g" \
        -e "s|${BUILD_PREFIX}/bin/${HOST}-gcc|cc|g" \
        -e "s|${BUILD_PREFIX}/bin/${HOST}-cc|cc|g" \
        -e "s|${BUILD_PREFIX}/bin/${HOST}-gfortran|gfortran|g" \
        -e "s| -Wl,--no-as-needed||g" \
        -e "s| -fdebug-prefix-map=[^ '\"]*||g" \
        "${script}"
done
