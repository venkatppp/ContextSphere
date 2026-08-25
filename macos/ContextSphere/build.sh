#!/bin/bash
set -euo pipefail

# Build script for the native macOS ContextSphere frontend (no Xcode —
# uses CLT swiftc + macOS 26 SDK, same recipe as ContextSphereLiquidGlassDemo).
# Builds the Rust core daemon and bundles it into the .app.
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path --sdk macosx)
APP_NAME="ContextSphere"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CORE_DIR="../../src-tauri"

PROFILE="${CONTEXTSPHERE_PROFILE:-release}"
if [ "$PROFILE" = "debug" ]; then
  CORE_BIN="$CORE_DIR/target/debug/contextsphere_core"
  CORE_FLAGS=""
else
  CORE_BIN="$CORE_DIR/target/release/contextsphere_core"
  CORE_FLAGS="--release"
fi

echo "==> SDK: $SDK"
echo "==> Building Rust core daemon ($PROFILE)"
(cd "$CORE_DIR" && cargo build --bin contextsphere_core $CORE_FLAGS)

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

echo "==> Compiling Swift sources"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macosx26.0 \
  -sdk "$SDK" \
  Sources/ContextSphereApp.swift \
  Sources/CoreBridge.swift \
  Sources/RPCModels.swift \
  Sources/Theme.swift \
  Sources/AppShell.swift \
  Sources/TimelineViewModel.swift \
  Sources/SearchViewModel.swift \
  Sources/SettingsViewModel.swift \
  Sources/MemoryViewModel.swift \
  Sources/LearningViewModel.swift \
  Sources/GraphLayout.swift \
  Sources/GraphViewModel.swift \
  Sources/Views/DashboardView.swift \
  Sources/Views/TimelineView.swift \
  Sources/Views/WorkspacesView.swift \
  Sources/Views/WorkspaceListRow.swift \
  Sources/Views/WorkspaceDetailView.swift \
  Sources/Views/WorkspaceSheets.swift \
  Sources/Views/SearchView.swift \
  Sources/Views/GraphView.swift \
  Sources/Views/GraphInspectorView.swift \
  Sources/Views/SettingsView.swift \
  Sources/Views/MemoryView.swift \
  Sources/Views/MemoryDetailView.swift \
  Sources/Views/LearningView.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Assembling bundle"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp "$CORE_BIN" "$APP_DIR/Contents/MacOS/contextsphere_core"
codesign --force --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Launch with: open $APP_DIR"
