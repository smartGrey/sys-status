#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the same stable signing identity on rebuilds so macOS recognizes the login item.
identity="${NETRATE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ && !found {print $2; found=1}')}"
xcodebuild -project NetRate.xcodeproj -scheme NetRate -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/release \
    CLANG_ENABLE_CODE_COVERAGE=NO ENABLE_TESTABILITY=NO CODE_SIGN_IDENTITY="${identity:--}" build
codesign --verify --deep --strict build/release/Build/Products/Release/状态栏扩展.app

# Publish a complete signed bundle at the project root on every successful build.
stage=$(mktemp -d build/publish.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto build/release/Build/Products/Release/状态栏扩展.app "$stage/状态栏扩展.app"
codesign --verify --strict "$stage/状态栏扩展.app/Contents/MacOS/NetRateSleepHelper"
codesign --verify --deep --strict "$stage/状态栏扩展.app"
swift - "$stage/状态栏扩展.app" "$PWD/状态栏扩展.app" <<'SWIFT'
import Foundation
import Darwin
let files = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
if files.fileExists(atPath: output.path) {
    guard Bundle(url: output)?.bundleIdentifier == Bundle(url: source)?.bundleIdentifier else {
        FileHandle.standardError.write(Data("根目录已有同名文件，请先移开该文件再构建。\n".utf8))
        exit(EX_CANTCREAT)
    }
    _ = try files.replaceItemAt(output, withItemAt: source)
} else {
    try files.moveItem(at: source, to: output)
}
SWIFT
codesign --verify --deep --strict ./状态栏扩展.app
echo "$PWD/状态栏扩展.app"
