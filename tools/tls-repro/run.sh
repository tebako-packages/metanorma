#!/usr/bin/env bash
# tls-repro runner — three legs (see README.md):
#   A  tebako check (CI-equivalent invocation)          → expect PASS
#      (host store at the runtime's compiled-in default path)
#   B  the tebako#437 shape: SSL_CERT_FILE=/ssl/cert.pem — the payload
#      ships the bundle AT THAT IN-VFS PATH; ruby sees it (VFS), the
#      native libcrypto reads the HOST path and misses → empty store →
#      "unable to get local issuer certificate" (the windows failure)
#   C  leg B with SSL_CERT_FILE repointed at the HOST copy extracted from
#      the env image (the feedstock workaround)           → expect PASS
# Every byte runs against the pinned, sha256-verified 0.16.6 runtime +
# v0.2.0 CLI (Dockerfile/fetch.sh).
set -euo pipefail

RT=/work/runtime-exe
RTIMG=/work/runtime-env.tfs
WINIMG=/work/win-env.tfs
IMG=/work/tls-probe.tfs

rcA=""; rcB=""; rcC=""; verdicts=()

echo "=================================================================="
echo "== LEG A — tebako check (the CI invocation; host store at defaults)"
echo "=================================================================="
set +e
tebako check "$IMG" --runtime "$RT" --runtime-image "$RTIMG" 2>&1 | tee /tmp/leg-a.log
rcA=${PIPESTATUS[0]}
set -e
if [ "$rcA" -eq 0 ] && grep -q "TLS-PROBE-OK" /tmp/leg-a.log; then
  verdicts+=("A: PASS (baseline green — host CA bundle readable at the default path)")
else
  verdicts+=("A: UNEXPECTED (rc=$rcA) — see /tmp/leg-a.log")
fi

echo "=================================================================="
echo "== LEG B — SSL_CERT_FILE=/ssl/cert.pem (the IN-VFS path — tebako#437)"
echo "==    ruby sees it via the payload mount; the native libcrypto misses"
echo "=================================================================="
set +e
SSL_CERT_FILE=/ssl/cert.pem TEBAKO_RUNTIME_IMAGE="$RTIMG" \
  "$RT" "--tebako-image=$IMG:-:/" "--tebako-entry=/bin/tls-probe" \
  2>&1 | tee /tmp/leg-b.log
rcB=${PIPESTATUS[0]}
set -e
if [ "$rcB" -ne 0 ] \
   && grep -q "unable to get local issuer certificate" /tmp/leg-b.log \
   && grep -q "ruby-side File.file?(/ssl/cert.pem) = true" /tmp/leg-b.log; then
  verdicts+=("B: REPRODUCED (rc=$rcB — VFS-visible store, native miss, empty-store TLS failure)")
else
  verdicts+=("B: NOT REPRODUCED (rc=$rcB) — see /tmp/leg-b.log")
fi

echo "=================================================================="
echo "== LEG C — SSL_CERT_FILE repointed at the HOST copy extracted from"
echo "==    the env image (the feedstock workaround: tfs cat <img> ssl/cert.pem)"
echo "=================================================================="
# The linux env images ship no ssl/cert.pem (that asymmetry is the bug's
# other half), so the bundle comes from the WINDOWS 0.16.6 env image —
# the exact bytes and the exact command the windows CI step runs.
tfs cat "$WINIMG" ssl/cert.pem > /tmp/tebako-ca-cert.pem
echo "   extracted $(wc -c < /tmp/tebako-ca-cert.pem) bytes of CA bundle from $(basename "$WINIMG")"
set +e
SSL_CERT_FILE=/tmp/tebako-ca-cert.pem TEBAKO_RUNTIME_IMAGE="$RTIMG" \
  "$RT" "--tebako-image=$IMG:-:/" "--tebako-entry=/bin/tls-probe" \
  2>&1 | tee /tmp/leg-c.log
rcC=${PIPESTATUS[0]}
set -e
if [ "$rcC" -eq 0 ] && grep -q "TLS-PROBE-OK" /tmp/leg-c.log; then
  verdicts+=("C: PASS (host-copy SSL_CERT_FILE green — the workaround mechanism)")
else
  verdicts+=("C: FAILED (rc=$rcC) — see /tmp/leg-c.log")
fi

echo "=================================================================="
echo "== VERDICTS"
echo "=================================================================="
printf '%s\n' "${verdicts[@]}"
ok=1
for v in "${verdicts[@]}"; do
  case "$v" in
    "A: PASS"*|"B: REPRODUCED"*|"C: PASS"*) ;;
    *) ok=0 ;;
  esac
done
if [ "$ok" -eq 1 ]; then
  echo "TLS-REPRO-OK: in-VFS SSL_CERT_FILE reproduced the windows failure; the host-copy workaround clears it"
else
  echo "TLS-REPRO-MIXED: inspect the leg logs above"
  exit 1
fi
