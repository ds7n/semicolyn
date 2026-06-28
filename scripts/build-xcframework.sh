#!/usr/bin/env bash
set -euo pipefail

LIB_NAME="libsemicolyn_ssh_core.a"
BUILD_DIR="target/xcframework"
OUT="SemicolynSSHCore.xcframework"

DEVICE="aarch64-apple-ios"
SIM_ARM="aarch64-apple-ios-sim"
SIM_X86="x86_64-apple-ios"

# 1. Compile the staticlib for each iOS triple.
for triple in "$DEVICE" "$SIM_ARM" "$SIM_X86"; do
  cargo build --release -p semicolyn-ssh-core --target "$triple"
done

# 2. Lipo the two simulator slices into one fat archive.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/sim"
lipo -create \
  "target/$SIM_ARM/release/$LIB_NAME" \
  "target/$SIM_X86/release/$LIB_NAME" \
  -output "$BUILD_DIR/sim/$LIB_NAME"

# 3. Generate the Swift bindings + module map from the built library.
mkdir -p "$BUILD_DIR/Headers"
cargo run --release -p semicolyn-ssh-core --bin uniffi-bindgen -- generate \
  --library "target/$DEVICE/release/$LIB_NAME" \
  --language swift \
  --out-dir "$BUILD_DIR/Generated"

# UniFFI emits <module>.swift, <module>FFI.h, <module>FFI.modulemap.
cp "$BUILD_DIR"/Generated/*.h "$BUILD_DIR/Headers/"
cp "$BUILD_DIR"/Generated/*.modulemap "$BUILD_DIR/Headers/module.modulemap"

# 4. Assemble the XCFramework (device slice + fat sim slice).
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/$DEVICE/release/$LIB_NAME" -headers "$BUILD_DIR/Headers" \
  -library "$BUILD_DIR/sim/$LIB_NAME"          -headers "$BUILD_DIR/Headers" \
  -output "$OUT"

# 5. Place the generated Swift wrapper where the SwiftPM target expects it.
mkdir -p Sources/SemicolynSSHCoreFFI
cp "$BUILD_DIR"/Generated/*.swift Sources/SemicolynSSHCoreFFI/
echo "Built $OUT and copied Swift bindings to Sources/SemicolynSSHCoreFFI/"
