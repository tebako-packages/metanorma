#!/usr/bin/env bash
# tools/fetch_verified.sh <url> <dest> <sha256> — fetch with the digest
# as the acceptance. GitHub's release plane sometimes answers 200 with a
# corrupt body (the 2026-11-08 flap killed a release's legs this way);
# a status-code-200 download is not evidence of intact bytes. Up to
# three rounds with backoff; a persistent mismatch is a REAL pin/release
# skew — named, never retried into silence.
set -euo pipefail

url="${1:?usage: fetch_verified.sh <url> <dest> <sha256>}"
dest="$2"
want="$3"

sum() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

for round in 1 2 3; do
  curl -sL --fail --retry 3 --retry-all-errors -o "$dest" "$url"
  got="$(sum "$dest")"
  if [ "$got" = "$want" ]; then
    exit 0
  fi
  echo "::warning:: $dest: digest mismatch on round $round (want $want, got $got) — a corrupt-body download; re-fetching after backoff"
  rm -f "$dest"
  sleep $((round * 15))
done
echo "::error:: $dest: digest mismatch after 3 rounds (want $want) — a pin/release skew, not a flake; refusing the asset"
exit 1
