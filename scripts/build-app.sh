#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$project_root/.build/Codex Monitor.app"

cd "$project_root"
swift build -c release
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_root/.build/release/CodexMonitor" "$app_dir/Contents/MacOS/CodexMonitor"
cp "$project_root/Support/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"

echo "$app_dir"
