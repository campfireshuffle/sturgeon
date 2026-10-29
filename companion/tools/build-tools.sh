#!/bin/zsh
# build-tools.sh — the AX inspection helper used by the proof (no synthetic clicks).
set -eu
HERE=${0:A:h}
xcrun swiftc -O -target arm64-apple-macosx14.0 -o $HERE/axui $HERE/axui.swift
print -r -- "built $HERE/axui"
