#!/usr/bin/env bash
# tls-repro fetch — download the pinned assets into .assets/ (gitignored)
# and verify every byte against the sha256 digests published by the two
# releases (the v0.2.0 CLI SHA256SUMS; the 0.16.6 runtime's canonical
# manifest.json / SHA256SUMS.txt). Idempotent: re-running re-verifies.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p .assets
cd .assets

TEBAKO_BASE="https://github.com/tamatebako/tebako/releases/download/v0.2.0"
TRR_BASE="https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v0.16.6"

# name sha256 url-base — digests are literal pins (feedstock convention),
# cross-checked against the releases' own sum files.
cat > PINS <<'EOF'
0dea602117b316dfef8d83572b2893248477d4e3cc2e5fc4f1787a254cfc87f1  tebako-0.2.0-linux-gnu-arm64
c5674a530963cb07ecd01a4a1053c1def7ca69b792b14b3d38d8fd919342a4ec  tfs-0.2.0-linux-gnu-arm64
a4959b878d7d65f3eebdbe639779edb0afdec7109383c89be8cf6a4379c70fb1  tebako-runtime-0.16.6-3.3.7-linux-gnu-arm64
9182227497199022c8b4376f2330a1390ed5dc3865edf5b18e3755c018dc91f8  tebako-runtime-0.16.6-3.3.7-linux-gnu-arm64.tfs
10ac408aa3206d819cc8d31824adbdf5e9de191ef973b6723d5f46b3af0ba483  tebako-runtime-0.16.6-3.3.7-windows-ucrt64.tfs
EOF

while read -r sha name; do
  case "$name" in
    tebako-0.2.0-*|tfs-0.2.0-*) base="$TEBAKO_BASE" ;;
    *)                            base="$TRR_BASE" ;;
  esac
  [ -f "$name" ] || curl -fsSLO "$base/$name"
  echo "$sha  $name" | { sha256sum -c - 2>/dev/null || shasum -a 256 -c -; }
done < PINS

# the build context names
cp tebako-0.2.0-linux-gnu-arm64 tebako
cp tfs-0.2.0-linux-gnu-arm64 tfs
chmod 755 tebako tfs tebako-runtime-0.16.6-3.3.7-linux-gnu-arm64

echo "assets ready in $(pwd)"
