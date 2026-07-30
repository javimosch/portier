#!/bin/sh
# Build the RELEASE artifact — a different binary from ./build.sh.
#
# build.sh links against whatever the build host has: libssl, libcrypto,
# libsqlite3 and glibc. machin links those into every binary unless you pass
# --static, so a binary built that way carries a glibc floor and will not start
# on Debian 11, Ubuntu 20.04, RHEL 8, Alpine, or a slim container.
#
# Until now portier published no binary at all: the only documented way in was
# ./build.sh, which needs the machin toolchain. That is a real barrier for
# anyone who just wants to self-host — see the estate-wide install audit
# (https://github.com/javimosch/stranger).
set -e
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
"$MACHIN" encode framework/machweb.src src/*.src > app.mfl
"$MACHIN" build app.mfl -o portier-linux-x86_64 --static
# ldd EXITS 1 on a static binary, so capture and match rather than piping into
# grep — under `set -e`/pipefail that pattern rejects a correct binary.
LDD_OUT=$(ldd portier-linux-x86_64 2>&1 || true)
case "$(file portier-linux-x86_64)" in *"statically linked"*) ;; *) echo "not static — refusing"; exit 1 ;; esac
case "$LDD_OUT" in *"not a dynamic executable"*) ;; *) echo "has dynamic deps — refusing: $LDD_OUT"; exit 1 ;; esac
./portier-linux-x86_64 help >/dev/null 2>&1 || { echo "release binary does not run — refusing"; exit 1; }
echo "release ok: $(wc -c < portier-linux-x86_64) bytes, static"
