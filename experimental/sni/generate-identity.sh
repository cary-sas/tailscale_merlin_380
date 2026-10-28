#!/bin/sh
# Run separately on each router (or a trusted computer); exchange .crt only.
set -eu
role=${1:-}
case "$role" in server|client) ;; *) echo "Usage: sh generate-identity.sh server|client" >&2; exit 1;; esac
if [ -e "$role.key" ] || [ -e "$role.crt" ]; then
  echo "Refusing to overwrite an existing TLS identity." >&2
  exit 1
fi
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -nodes -days 365 -subj "/CN=merlin-tls-$role" \
  -keyout "$role.key" -out "$role.crt"
echo "Created $role.key and $role.crt. Copy only $role.crt to the other router."
