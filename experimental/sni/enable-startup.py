#!/usr/bin/env python3
"""Produce a reviewable startup script; never install/restart a router here."""
import argparse
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('original', type=Path, help='copy of /koolshare/scripts/tailscale_config')
p.add_argument('output', type=Path)
a = p.parse_args()
if a.output.exists():
    raise SystemExit('Output already exists; refusing to overwrite')
s = a.original.read_text()
anchor = '  check_binaries || return 1'
if s.count(anchor) != 1:
    raise SystemExit('Unrecognized controller script; manual review required')
addition = '''  # Experimental direct TLS is opt-in by a root-owned JSON config file.
  unset TS_MERLIN_TLS_CONFIG
  if [ -f /koolshare/configs/tailscale/merlin-tls/config.json ]; then
    export TS_MERLIN_TLS_CONFIG=/koolshare/configs/tailscale/merlin-tls/config.json
  fi

'''
a.output.write_text(s.replace(anchor, addition + anchor, 1))
print('Created', a.output, '(not installed)')
