#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
derived_data_path="/private/tmp/inf6-cli-derived-data"
build_output_path="$derived_data_path/Build"
lock_path="/private/tmp/inf6-cli-derived-data.lock"

if ! mkdir "$lock_path" 2>/dev/null; then
    if [[ -f "$lock_path/pid" ]]; then
        lock_pid="$(<"$lock_path/pid")"
        if [[ "$lock_pid" == <-> ]] && kill -0 "$lock_pid" 2>/dev/null; then
            print -u2 "CLI build is already running; refusing to share its DerivedData/build.db."
            exit 73
        fi
        rm -f "$lock_path/pid"
        rmdir "$lock_path" 2>/dev/null || {
            print -u2 "Stale CLI build lock is not empty; refusing to reuse its DerivedData/build.db."
            exit 73
        }
        mkdir "$lock_path"
    else
        print -u2 "CLI build lock exists without an owner; refusing to share its DerivedData/build.db."
        exit 73
    fi
fi
print "$" > "$lock_path/pid"
trap 'rm -f "$lock_path/pid"; rmdir "$lock_path"' EXIT HUP INT TERM

cd "$project_root"
xcodebuild \
    -project "$project_root/ArcaneDerivation.xcodeproj" \
    -scheme inf6 \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' \
    -derivedDataPath "$derived_data_path" \
    SYMROOT="$build_output_path" \
    OBJROOT="$build_output_path" \
    "$@"
