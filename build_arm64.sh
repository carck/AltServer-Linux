#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
JOBS="${JOBS:-3}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build_output}"
DEPS_DIR="${DEPS_DIR:-$ROOT_DIR/.buildenv}"
PREFIX="${PREFIX:-/usr/local}"
SKIP_DEPENDENCIES="${SKIP_DEPENDENCIES:-0}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build AltServer natively on the current host.

Options:
  -j, --jobs N       Number of make jobs (default: $JOBS)
  -o, --output DIR   Copy built AltServer binaries to DIR
    --skip-dependencies Skip native dependency installation/build
  -h, --help         Show this help

Environment overrides: JOBS, BUILD_DIR, OUTPUT_DIR, DEPS_DIR, PREFIX,
SKIP_DEPENDENCIES.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--jobs)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            JOBS="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-dependencies)
            SKIP_DEPENDENCIES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

HOST_ARCH="$(uname -m)"
echo "Building natively for host architecture: $HOST_ARCH"

run_privileged() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_native_packages() {
    command -v apt-get >/dev/null || {
        echo "This dependency setup currently supports apt-based native environments." >&2
        exit 1
    }

    run_privileged apt-get update
    run_privileged apt-get install -y \
        build-essential clang cmake curl git ninja-build pkg-config unzip \
        uuid-dev libboost-filesystem-dev libboost-system-dev libssl-dev zlib1g-dev
}

build_corecrypto() {
    local archive="$DEPS_DIR/corecrypto.zip"
    local cmake_file
    local source_dir
    local build_dir="$DEPS_DIR/corecrypto-build"

    [[ -f "$PREFIX/include/corecrypto/ccsrp.h" && -f "$PREFIX/lib/libcorecrypto_static.a" ]] && return

    mkdir -p "$DEPS_DIR"
    curl -fL --retry 3 \
        -H 'Referer: https://developer.apple.com/security/' \
        -o "$archive" \
        'https://developer.apple.com/file/?file=security&agree=Yes'
    rm -rf "$DEPS_DIR/corecrypto-src" "$build_dir"
    mkdir -p "$DEPS_DIR/corecrypto-src"
    unzip -q "$archive" -d "$DEPS_DIR/corecrypto-src"
    cmake_file="$(find "$DEPS_DIR/corecrypto-src" -type f -name CMakeLists.txt -print -quit)"
    [[ -n "$cmake_file" ]] || { echo "Could not find extracted corecrypto CMakeLists.txt" >&2; exit 1; }
    source_dir="${cmake_file%/CMakeLists.txt}"

    sed -i '/^[[:space:]]*include(scripts\/code-coverage\.cmake)[[:space:]]*$/d' \
        "$source_dir/CMakeLists.txt"
    if [[ -f "$source_dir/ccrng_static.c" && ! -f "$source_dir/corecrypto_static/ccrng_static.c" ]]; then
        sed -i 's|"corecrypto_static/ccrng_static.c"|"ccrng_static.c"|' \
            "$source_dir/CoreCryptoSources.cmake"
    fi
    cmake -S "$source_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCODE_COVERAGE=OFF
    sed -i -E '/^all: CMakeFiles\/(corecrypto_perf|corecrypto_test)/d' \
        "$build_dir/CMakeFiles/Makefile2"
    cmake --build "$build_dir" --parallel "$JOBS"
    run_privileged cmake --install "$build_dir"
}

build_cpprestsdk() {
    local source_dir="$DEPS_DIR/cpprestsdk"
    local build_dir="$source_dir/build"

    [[ -f "$PREFIX/lib/libcpprest.a" ]] && return

    rm -rf "$source_dir"
    git clone --depth 1 --recursive https://github.com/microsoft/cpprestsdk "$source_dir"
    if [[ -f "$source_dir/Release/CMakeLists.txt" ]]; then
        sed -i 's|-Wcast-align||g' "$source_dir/Release/CMakeLists.txt"
    fi
    cmake -S "$source_dir" -B "$build_dir" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-Wno-error=format-truncation" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build "$build_dir" -j"$JOBS"
    run_privileged cmake --install "$build_dir"
}

build_libzip() {
    local source_dir="$DEPS_DIR/libzip"
    local build_dir="$source_dir/build"

    [[ -f "$PREFIX/lib/libzip.a" ]] && return

    rm -rf "$source_dir"
    git clone --depth 1 https://github.com/nih-at/libzip "$source_dir"
    cmake -S "$source_dir" -B "$build_dir" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build "$build_dir" -j"$JOBS"
    run_privileged cmake --install "$build_dir"
}

apply_git_patches() {
    local repo_dir
    local patch_file

    while read -r repo_dir patch_file; do
        patch_file="$ROOT_DIR/patches/$patch_file"
        [[ -f "$patch_file" ]] || continue
        if git -C "$ROOT_DIR/$repo_dir" apply --check "$patch_file"; then
            git -C "$ROOT_DIR/$repo_dir" apply "$patch_file"
        elif git -C "$ROOT_DIR/$repo_dir" apply --reverse --check "$patch_file"; then
            echo "Patch already applied: $patch_file"
        else
            echo "Patch does not apply cleanly: $patch_file" >&2
            exit 1
        fi
    done <<'PATCHES'
upstream_repo altserver-windows-62a7a2b.patch
upstream_repo libplist-api-compatibility.patch
libraries/libimobiledevice libimobiledevice-plist-format.patch
PATCHES
}

if [[ "$SKIP_DEPENDENCIES" != 1 ]]; then
    install_native_packages
    build_corecrypto
    build_cpprestsdk
    build_libzip
fi

for command_name in make gcc g++ clang clang++ cmake curl git python3 unzip; do
    command -v "$command_name" >/dev/null || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

apply_git_patches

mkdir -p "$BUILD_DIR"

case "$BUILD_DIR" in
    "$ROOT_DIR"/*)
        ;;
    *)
        echo "BUILD_DIR must be inside the repository: $ROOT_DIR" >&2
        exit 2
        ;;
esac

make -C "$BUILD_DIR" -f "$ROOT_DIR/Makefile" -j"$JOBS"

shopt -s nullglob
artifacts=("$BUILD_DIR"/AltServer-*)
if [[ ${#artifacts[@]} -eq 0 ]]; then
    echo "Build completed without producing an AltServer-* artifact." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp -f "${artifacts[@]}" "$OUTPUT_DIR/"
chmod +x "$OUTPUT_DIR"/AltServer-*
echo "Built artifacts:"
for artifact in "$OUTPUT_DIR"/AltServer-*; do
    echo "  $artifact"
done