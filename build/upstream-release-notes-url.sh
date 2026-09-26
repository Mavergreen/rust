#!/bin/sh
# platform: host-agnostic
#   usage: upstream-release-notes-url.sh <upstream-version>     prints Rust's notes URL for it
set -eu
printf 'https://github.com/rust-lang/rust/releases/tag/%s\n' "${1:?usage: upstream-release-notes-url.sh <upstream-version>}"
