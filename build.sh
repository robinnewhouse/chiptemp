#!/bin/sh
# Builds Chip Temps.app and installs it in /Applications.
set -e
cd "$(dirname "$0")"
APP="build/Chip Temps.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"
clang -c -O2 sensors.c -o build/sensors.o -Wno-deprecated-declarations
swiftc -O -parse-as-library -import-objc-header sensors.h ChipTemps.swift build/sensors.o \
  -framework IOKit -framework CoreFoundation -o "$APP/Contents/MacOS/ChipTemps"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
pkill -x ChipTemps 2>/dev/null || true
rm -rf "/Applications/Chip Temps.app" && cp -R "$APP" /Applications/
open "/Applications/Chip Temps.app"
