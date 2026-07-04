#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
FFI_DIR="$REPO_ROOT/floresta-ffi"
SWIFT_PKG_DIR="$(cd "$REPO_ROOT/../floresta-swift" && pwd)"

TARGET_IOS="aarch64-apple-ios"
TARGET_IOS_SIM_ARM64="aarch64-apple-ios-sim"
TARGET_IOS_SIM_X86_64="x86_64-apple-ios"
LIB_NAME="libflorestad_ffi.a"
XCFRAMEWORK_NAME="florestaFFI"

cd "$FFI_DIR"

# Install required Rust targets
rustup target add "$TARGET_IOS" "$TARGET_IOS_SIM_ARM64" "$TARGET_IOS_SIM_X86_64"

# -----------------------------------------------------------------------
# libbitcoinkernel-sys uses the cmake Rust crate, which watches
# CMAKE_TOOLCHAIN_FILE and re-runs cmake when the value changes.
# Create per-target toolchain files that direct cmake to use the iOS SDK
# so that bitcoinkernel.a is compiled for iOS, not macOS.
#
# libbitcoinkernel-sys also emits `cargo:rustc-link-lib=dylib=stdc++`.
# The iOS SDK does not ship libstdc++; C++ stdlib symbols live in libc++.
# Create empty per-arch stubs so the linker satisfies -lstdc++ without
# erroring. Real C++ symbols resolve from libc++ when the app links the
# XCFramework.
# -----------------------------------------------------------------------
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANG="$(xcrun --find clang)"
CLANGXX="$(xcrun --find clang++)"
STUB_BASE="$(mktemp -d)"
TC_BASE="$(mktemp -d)"

# Boost headers are required by libbitcoinkernel cmake (header-only use)
BOOST_PREFIX="$(brew --prefix boost 2>/dev/null || echo '')"
if [ -z "$BOOST_PREFIX" ] || [ ! -d "$BOOST_PREFIX/lib/cmake" ]; then
    echo "Error: Boost not found. Install with: brew install boost" >&2
    exit 1
fi

write_toolchain() {
    local file="$1" arch="$2" sdk="$3" triple="$4"
    cat > "$file" << EOF
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES $arch)
set(CMAKE_OSX_SYSROOT $sdk)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)
set(CMAKE_C_COMPILER $CLANG)
set(CMAKE_CXX_COMPILER $CLANGXX)
set(CMAKE_C_FLAGS "-arch $arch -target $triple -isysroot $sdk")
set(CMAKE_CXX_FLAGS "-arch $arch -target $triple -isysroot $sdk")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# Boost lives on the host (macOS), not in the iOS sysroot
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE NEVER)
list(APPEND CMAKE_PREFIX_PATH "$BOOST_PREFIX/lib/cmake")
EOF
}

write_toolchain "$TC_BASE/ios.cmake"       arm64   "$IOS_SDK" arm64-apple-ios15.0
write_toolchain "$TC_BASE/sim_arm64.cmake" arm64   "$SIM_SDK" arm64-apple-ios15.0-simulator
write_toolchain "$TC_BASE/sim_x86.cmake"   x86_64  "$SIM_SDK" x86_64-apple-ios15.0-simulator

make_stub() {
    local dir="$1" arch="$2" sdk="$3" triple="$4"
    mkdir -p "$dir"
    local tmp_c; tmp_c="$(mktemp /tmp/stub_XXXXXX.c)"
    echo 'static void _stub(void) {}' > "$tmp_c"
    xcrun --sdk "$sdk" clang -arch "$arch" -target "$triple" \
        -c "$tmp_c" -o "$dir/empty.o"
    rm "$tmp_c"
    xcrun ar rcs "$dir/libstdc++.a" "$dir/empty.o"
    rm "$dir/empty.o"
}

make_stub "$STUB_BASE/ios"       arm64   iphoneos        arm64-apple-ios15.0
make_stub "$STUB_BASE/sim_arm64" arm64   iphonesimulator arm64-apple-ios15.0-simulator
make_stub "$STUB_BASE/sim_x86"   x86_64  iphonesimulator x86_64-apple-ios15.0-simulator

# Build each target in a subshell so CMAKE_TOOLCHAIN_FILE is isolated per target
(
    export IPHONEOS_DEPLOYMENT_TARGET=15.0
    export CMAKE_TOOLCHAIN_FILE="$TC_BASE/ios.cmake"
    export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-L$STUB_BASE/ios -l c++ ${CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS:-}"
    cargo build --lib --profile release-smaller --target "$TARGET_IOS"
)
(
    export IPHONEOS_DEPLOYMENT_TARGET=15.0
    export CMAKE_TOOLCHAIN_FILE="$TC_BASE/sim_arm64.cmake"
    export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS="-L$STUB_BASE/sim_arm64 -l c++ ${CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS:-}"
    cargo build --lib --profile release-smaller --target "$TARGET_IOS_SIM_ARM64"
)
(
    export IPHONEOS_DEPLOYMENT_TARGET=15.0
    export CMAKE_TOOLCHAIN_FILE="$TC_BASE/sim_x86.cmake"
    export CARGO_TARGET_X86_64_APPLE_IOS_RUSTFLAGS="-L$STUB_BASE/sim_x86 -l c++ ${CARGO_TARGET_X86_64_APPLE_IOS_RUSTFLAGS:-}"
    cargo build --lib --profile release-smaller --target "$TARGET_IOS_SIM_X86_64"
)

# Generate Swift bindings from the device library
SWIFT_GEN_DIR="$(mktemp -d)"
cargo run --bin uniffi-bindgen generate \
    --library "target/$TARGET_IOS/release-smaller/$LIB_NAME" \
    --language swift \
    --out-dir "$SWIFT_GEN_DIR" \
    --no-format

# Combine both simulator slices into a universal binary
SIM_FAT_DIR="$(mktemp -d)"
lipo -create \
    "target/$TARGET_IOS_SIM_ARM64/release-smaller/$LIB_NAME" \
    "target/$TARGET_IOS_SIM_X86_64/release-smaller/$LIB_NAME" \
    -output "$SIM_FAT_DIR/$LIB_NAME"

# Stage headers: XCFramework requires module.modulemap alongside the C header
HEADERS_DIR="$(mktemp -d)"
cp "$SWIFT_GEN_DIR/${XCFRAMEWORK_NAME}.h"           "$HEADERS_DIR/"
cp "$SWIFT_GEN_DIR/${XCFRAMEWORK_NAME}.modulemap"   "$HEADERS_DIR/module.modulemap"

# Create XCFramework
XCFRAMEWORK_PATH="$SWIFT_PKG_DIR/$XCFRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK_PATH"
xcodebuild -create-xcframework \
    -library "target/$TARGET_IOS/release-smaller/$LIB_NAME" \
    -headers "$HEADERS_DIR" \
    -library "$SIM_FAT_DIR/$LIB_NAME" \
    -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK_PATH"

# Copy generated Swift sources into the SPM package
mkdir -p "$SWIFT_PKG_DIR/Sources/Floresta"
rm -f "$SWIFT_PKG_DIR/Sources/Floresta/"*.swift
cp "$SWIFT_GEN_DIR/floresta.swift" "$SWIFT_PKG_DIR/Sources/Floresta/"

# Zip the XCFramework and compute the SPM checksum for Package.swift
ZIP_PATH="$SWIFT_PKG_DIR/$XCFRAMEWORK_NAME.xcframework.zip"
rm -f "$ZIP_PATH"
(cd "$SWIFT_PKG_DIR" && zip -r "$XCFRAMEWORK_NAME.xcframework.zip" "$XCFRAMEWORK_NAME.xcframework" -x "*.DS_Store")
CHECKSUM="$(swift package compute-checksum "$ZIP_PATH")"

# Update Package.swift:
#  - If RELEASE_URL is set (CI mode): rewrite the binaryTarget block to url+checksum form.
#  - Otherwise (local mode): only patch the checksum value, leave the rest unchanged.
if [ -n "${RELEASE_URL:-}" ]; then
    TMPPY="$(mktemp /tmp/patch_pkg_XXXXXX.py)"
    cat > "$TMPPY" << 'PYEOF'
import re, sys
pkg_path, url, checksum = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(pkg_path).read()
new_target = (
    '        .binaryTarget(\n'
    f'            name: "florestaFFI",\n'
    f'            url: "{url}",\n'
    f'            checksum: "{checksum}"\n'
    '        ),'
)
content = re.sub(
    r'\.binaryTarget\(.*?name:\s*"florestaFFI".*?\),',
    new_target,
    content,
    flags=re.DOTALL,
)
open(pkg_path, 'w').write(content)
PYEOF
    python3 "$TMPPY" "$SWIFT_PKG_DIR/Package.swift" "$RELEASE_URL" "$CHECKSUM"
    rm "$TMPPY"
    echo "Package.swift updated with URL: $RELEASE_URL"
else
    sed -i '' "s|checksum: \"[^\"]*\"|checksum: \"$CHECKSUM\"|" "$SWIFT_PKG_DIR/Package.swift"
fi

# Cleanup temp dirs
rm -rf "$SWIFT_GEN_DIR" "$SIM_FAT_DIR" "$HEADERS_DIR" "$STUB_BASE" "$TC_BASE"

echo ""
echo "Done! Swift package ready at: $SWIFT_PKG_DIR"
echo "XCFramework zip: $ZIP_PATH"
echo "Checksum: $CHECKSUM"
if [ -z "${RELEASE_URL:-}" ]; then
    echo ""
    echo "Next steps:"
    echo "  1. Create a GitHub Release on your floresta-swift repo"
    echo "  2. Upload $XCFRAMEWORK_NAME.xcframework.zip as the release asset"
    echo "  3. Update the 'url:' in Package.swift to match the release asset URL"
    echo "  4. Commit Package.swift + Sources/ and push"
fi
