#!/usr/bin/env bash
set -euo pipefail

# SDL3 Cross-compile script for wer

TARGET="${1:-}"
if [[ "$TARGET" == "macos" ]]; then
    TARGET="macos-aarch64"
fi

if [[ "$TARGET" != "linux" && "$TARGET" != "windows" && "$TARGET" != "macos-aarch64" && "$TARGET" != "macos-x64" ]]; then
    echo "Usage: $0 <linux|windows|macos-aarch64|macos-x64>"
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDL_SRC="$ROOT_DIR/deps/sdl_src"
BUILD_DIR="$ROOT_DIR/deps/build_sdl3_$TARGET"
INSTALL_DIR="$ROOT_DIR/deps/sdl3-$TARGET"

# 1. Shallow clone latest master if not present
if [ ! -d "$SDL_SRC" ]; then
    echo "Cloning SDL (depth 1)..."
    git clone --depth 1 https://github.com/libsdl-org/SDL.git "$SDL_SRC"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 2. Platform toolchain configuration using Clang and CMake
if [ "$TARGET" = "linux" ]; then
    cmake "$SDL_SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DSDL_STATIC=ON \
        -DSDL_SHARED=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF

    cmake --build . -j"$(nproc)"
    cmake --install .

elif [ "$TARGET" = "windows" ]; then
    MSVC_SDK="${HOME}/.cache/c3/msvc_sdk"
    if [ ! -d "$MSVC_SDK" ]; then
        echo "Error: MSVC SDK not found at $MSVC_SDK"
        exit 1
    fi

    # Set up symlink in deps if not present
    if [ ! -e "$ROOT_DIR/deps/msvc_sdk" ]; then
        ln -s "$MSVC_SDK" "$ROOT_DIR/deps/msvc_sdk"
    fi

    TARGET_CFLAGS="--target=x86_64-pc-windows-msvc -fno-pie -idirafter $MSVC_SDK/include/crt -idirafter $MSVC_SDK/include/x64/ucrt -idirafter $MSVC_SDK/include/x64/shared -idirafter $MSVC_SDK/include/x64/um"
    TARGET_LDFLAGS="--target=x86_64-pc-windows-msvc -fuse-ld=lld -L$MSVC_SDK/x64"

    cmake "$SDL_SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_FLAGS="$TARGET_CFLAGS" \
        -DCMAKE_CXX_FLAGS="$TARGET_CFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$TARGET_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$TARGET_LDFLAGS" \
        -DCMAKE_AR=llvm-ar \
        -DCMAKE_RANLIB=llvm-ranlib \
        -DSDL_STATIC=ON \
        -DSDL_SHARED=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF

    cmake --build . -j"$(nproc)"
    cmake --install .

    # Produce .lib copies for MSVC linker compatibility
    for lib in "$INSTALL_DIR/lib"/lib*.a; do
        [ -f "$lib" ] || continue
        name="$(basename "$lib")"
        name="${name#lib}"
        name="${name%.a}.lib"
        cp "$lib" "$INSTALL_DIR/lib/$name"
    done

elif [[ "$TARGET" =~ ^macos ]]; then
    MACOS_SDK="${HOME}/.cache/c3/MacOSX.sdk"
    if [ ! -d "$MACOS_SDK" ]; then
        echo "Error: MacOS SDK not found at $MACOS_SDK"
        exit 1
    fi

    # Set up symlink in deps if not present
    if [ ! -e "$ROOT_DIR/deps/MacOSX.sdk" ]; then
        ln -s "$MACOS_SDK" "$ROOT_DIR/deps/MacOSX.sdk"
    fi

    DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    if [[ "$TARGET" == "macos-x64" ]]; then
        ARCH="x86_64"
        OSX_ARCH="x86_64"
        CLANG_TARGET="x86_64-apple-macos${DEPLOY_TARGET}"
    else
        ARCH="arm64"
        OSX_ARCH="arm64"
        CLANG_TARGET="arm64-apple-macos${DEPLOY_TARGET}"
    fi

    cmake "$SDL_SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_SYSTEM_NAME=Darwin \
        -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_OBJC_COMPILER=clang \
        -DCMAKE_C_COMPILER_TARGET="$CLANG_TARGET" \
        -DCMAKE_CXX_COMPILER_TARGET="$CLANG_TARGET" \
        -DCMAKE_OBJC_COMPILER_TARGET="$CLANG_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
        -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
        -DCMAKE_FIND_ROOT_PATH="$MACOS_SDK" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DSDL_LIBUSB=OFF \
        -DSDL_HIDAPI_LIBUSB=OFF \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_AR=llvm-ar \
        -DCMAKE_RANLIB=llvm-ranlib \
        -DSDL_STATIC=ON \
        -DSDL_SHARED=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF

    cmake --build . -j"$(nproc)"
    cmake --install .
fi

echo "SDL3 $TARGET static build completed at: $INSTALL_DIR"
