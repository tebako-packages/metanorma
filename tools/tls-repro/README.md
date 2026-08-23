# tools/tls-repro — the tebako#437 TLS repro + workaround proof, locally

The metanorma windows leg died with `certificate verify failed (unable to
get local issuer certificate)`: with the runtime image passed as a bare
path (no store sidecar), the windows exe shim's store-less fallback sets
`SSL_CERT_FILE` to the IN-VFS `A:/t/ssl/cert.pem`. Ruby sees the file
through the VFS; the native libcrypto reads the HOST path via CRT IO and
misses → empty OpenSSL store (tamatebako/tebako#437).

This harness reproduces that exact VFS/native divergence on linux/arm64
and proves the feedstock workaround (extract the CA bundle from the
runtime env image, export `SSL_CERT_FILE` at the HOST copy — the shim
honors a user-set `SSL_CERT_FILE`, "user wins"; shipped in
build-payload.yml's windows check step, green in run 32639696120).

## Run

```sh
tools/tls-repro/fetch.sh   # downloads + sha256-verifies .assets/ (once)
docker build --platform linux/arm64 -t tls-repro tools/tls-repro
docker run --rm tls-repro
```

Expected tail:

```
A: PASS (baseline green — host CA bundle readable at the default path)
B: REPRODUCED (rc=1 — VFS-visible store, native miss, empty-store TLS failure)
C: PASS (host-copy SSL_CERT_FILE green — the workaround mechanism)
TLS-REPRO-OK: in-VFS SSL_CERT_FILE reproduced the windows failure; the host-copy workaround clears it
```

Assets are fetched on the host by `fetch.sh`, not in-container: the
harness needs no distro packages, and this box's containers have no
usable apt (the `apt-key`/gpgv verify step fails against genuine,
byte-complete InRelease files — a Docker Desktop quirk, not pursued).
`.assets/` is gitignored; every byte is checked against literal digest
pins (the v0.2.0 CLI SHA256SUMS; the 0.16.6 release's canonical
`manifest.json`/`SHA256SUMS.txt`).

The leg-A host store is the CA bundle the windows 0.16.6 env image
ships, extracted at image-build time and placed at every standard
OpenSSL default-file location (the base image ships no ca-certificates).

## The three legs

- **A — baseline, CI-equivalent.** `tebako check tls-probe.tfs
  --runtime <0.16.6 exe> --runtime-image <0.16.6 env.tfs>` — the exact
  build-payload.yml invocation. The probe loads its store from the host
  `/etc/ssl/cert.pem` (the runtime's compiled-in `DEFAULT_CERT_FILE`)
  and the GET verifies. Proves the runtime + payload + probe are sound,
  isolating the store-path variable.
- **B — the repro.** The spec-17 driver handoff directly
  (`TEBAKO_RUNTIME_IMAGE=… <exe> --tebako-image=<img>:-:/
  --tebako-entry=/bin/tls-probe`, the same shape `tools/boot_smoke`
  uses) with `SSL_CERT_FILE=/ssl/cert.pem` — the payload image ships the
  CA bundle AT THAT IN-VFS PATH. The probe prints the divergence in two
  lines: `File.file?(/ssl/cert.pem) = true` (ruby, via the VFS) vs
  `X509_LOOKUP_load_file: BIO lib` (native miss) → empty store →
  `certificate verify failed (unable to get local issuer certificate)`,
  the windows failure string.
- **C — the workaround.** Leg B with `SSL_CERT_FILE` repointed at the
  host copy extracted with `tfs cat <env image> ssl/cert.pem` — the
  identical command the windows check step runs. The linux env images
  ship no `ssl/cert.pem` (that asymmetry is the bug's other half), so
  the bundle source here is the windows 0.16.6 env image — the same
  bytes the CI step extracts. Green ⇒ the mechanism (user-set
  `SSL_CERT_FILE` pointing at a HOST copy) closes the gap.

### Why not a jail for leg B?

The original plan hid `/etc/ssl` via `TEBAKO_JAIL=deny` + grants.
Empirically impossible on linux, and the negative result is itself a
finding: **the jail's choke point does not cover libcrypto's own file
IO.** Under a bound deny policy (jail-deny journal entries flowing),
`File.binread("/etc/ssl/cert.pem")` → `Errno::EPERM`, but
`OpenSSL::X509::Store#add_file("/etc/ssl/cert.pem")` → loads fine
(repro: `payload/bin/tls-probe-deep`'s canary section). The in-VFS store
path reproduces the windows failure MORE faithfully than a jail could —
same divergence, same mechanism — so the harness uses it instead.

## Bonus finding 2 — CRL_CHECK_ALL × OpenSSL 3.6 (orthogonal to #437)

Stock ruby 3.3.7's bundled openssl gem sets
`DEFAULT_CERT_STORE.flags = V_FLAG_CRL_CHECK_ALL`
(ruby/ruby v3_3_7 `ext/openssl/lib/openssl/ssl.rb:95`; removed in later
gems — openssl gem 4.0.2 doesn't have it). Under OpenSSL ≤ 3.5 that flag
is benign; **under OpenSSL 3.6 it hard-fails every chain whose certs
carry CRL Distribution Points** — i.e. effectively all real-world https:
`verify -> false err=3 (unable to get certificate CRL)` (observed on
Sectigo/GTS/GlobalSign chains). The 0.16.6 POSIX runtimes link OpenSSL
3.6.x (linux-gnu: 3.6.0; macos: 3.6.2) → their `Net::HTTP` with the
default store is broken for https in general. The windows runtime links
the msys2 OpenSSL (3.5.x, tolerant) → the windows leg is unaffected by
this and green with the CA-bundle workaround alone. The probe therefore
builds its own store (`add_file`, flags 0) — same file-IO surface the
bug lives on, without the orthogonal CRL landmine. Evidence matrix:
`payload/bin/tls-probe-deep` (runs against any URL via `TLS_PROBE_URL`).

## Notes

- Everything downloaded is sha256-pinned (fetch.sh / Dockerfile).
- The payload is the fontist TLS class without the fontist weight: one
  `Net::HTTP` GET (`TLS_PROBE_URL` to override), printing the store
  configuration before the verdict.
- x86_64 hosts: swap the two `linux-gnu-arm64` digests/artifacts for the
  `linux-gnu-x86_64` ones in `fetch.sh` and drop `--platform`.
