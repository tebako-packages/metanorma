# syntax=docker/dockerfile:1
# tls-repro — the tebako#437 windows TLS failure + the SSL_CERT_FILE
# workaround, reproduced locally on linux/arm64. See README.md.
#
#   tools/tls-repro/fetch.sh   # host-side: download + sha256-verify .assets/
#   docker build --platform linux/arm64 -t tls-repro tools/tls-repro
#   docker run --rm tls-repro
#
# Assets are fetched on the HOST (fetch.sh), not in-container: this box's
# containers have no usable apt (apt-key/gpgv verify step fails against
# genuine, byte-complete InRelease files — Docker Desktop storage/net
# quirk, root cause not pursued; the harness needs no distro packages).
FROM --platform=linux/arm64 ubuntu:24.04

WORKDIR /work

COPY .assets/tebako /usr/local/bin/tebako
COPY .assets/tfs /usr/local/bin/tfs
COPY .assets/tebako-runtime-0.16.6-3.3.7-linux-gnu-arm64 /work/runtime-exe
COPY .assets/tebako-runtime-0.16.6-3.3.7-linux-gnu-arm64.tfs /work/runtime-env.tfs
COPY .assets/tebako-runtime-0.16.6-3.3.7-windows-ucrt64.tfs /work/win-env.tfs
RUN chmod 755 /usr/local/bin/tebako /usr/local/bin/tfs /work/runtime-exe

# The leg-A host store: the CA bundle the windows 0.16.6 env image ships
# (image sha256-verified by fetch.sh), placed at every standard OpenSSL
# default-FILE location — the base image ships no ca-certificates and
# there is no apt here. The probe prints the runtime's compiled-in
# DEFAULT_CERT_FILE/DIR first, so the coverage is checkable from the log.
RUN tfs cat /work/win-env.tfs ssl/cert.pem > /tmp/cacert.pem \
 && mkdir -p /etc/ssl/certs /usr/lib/ssl /etc/pki/tls /etc/pki/ca-trust/extracted/pem \
 && cp /tmp/cacert.pem /etc/ssl/certs/ca-certificates.crt \
 && cp /tmp/cacert.pem /etc/ssl/cert.pem \
 && cp /tmp/cacert.pem /usr/lib/ssl/cert.pem \
 && cp /tmp/cacert.pem /etc/pki/tls/cert.pem \
 && cp /tmp/cacert.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# --- the minimal TLS-probe payload (imaged in-process; never mkdwarfs) ---
# The payload ships the same CA bundle at /ssl/cert.pem: leg B points
# SSL_CERT_FILE AT THAT IN-VFS PATH — ruby sees it (VFS), the native
# libcrypto does not (host miss) — the exact tebako#437 divergence.
COPY payload/ /work/payload/
RUN mkdir -p /work/payload/ssl && cp /tmp/cacert.pem /work/payload/ssl/cert.pem \
 && rm /tmp/cacert.pem \
 && tfs mkimage --format dwarfs /work/payload --output /work/tls-probe.tfs

COPY run.sh /work/run.sh
RUN chmod 755 /work/run.sh

ENTRYPOINT ["/work/run.sh"]
