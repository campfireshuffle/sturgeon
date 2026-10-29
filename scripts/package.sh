#!/bin/zsh
# Convenience wrapper: build the app and the tool tree, then package them.
#
#   ./scripts/package.sh [version] [build]        # default 1.0.0 / 35
#
# Signing:
#   SIGN_IDENTITY="Developer ID Application: …"   sign for distribution
#   SIGN_IDENTITY=-                               ad-hoc (local proof only)
#   unset                                         pick the first Developer ID in the keychain,
#                                                 otherwise fall back to ad-hoc
#
# Notarization credentials are read from $STURGEON_CREDS (default ~/.sturgeon-signing):
#   AuthKey_*.p8, key-id.txt, issuer-id.txt.  Nothing is copied into the repository.
set -eu
cd "$(dirname "$0")/.."
exec ./pack/package.sh "$@"
