#!/usr/bin/env python3
"""Apply the direct TLS experiment to the pinned Tailscale v1.104.1 source."""
import argparse
from pathlib import Path
import shutil

p = argparse.ArgumentParser()
p.add_argument('source', type=Path)
args = p.parse_args()
root = args.source
overlay = Path(__file__).parent / 'overlay'

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit('Unexpected upstream layout (or patch already applied): ' + old[:80])
    return text.replace(old, new, 1)

main_path = root / 'wgengine/magicsock/magicsock.go'
ep_path = root / 'wgengine/magicsock/endpoint.go'
main = main_path.read_text()
ep = ep_path.read_text()
main = replace_once(main, 'type Conn struct {', 'type Conn struct {\n\tmerlinTLS atomic.Pointer[merlinTLS] // experimental, scoped to one node key\n')
main = replace_once(main, '\tc.closed = false\n\tvar fns []conn.ReceiveFunc', '''\ttlsTransport, err := c.Conn.openMerlinTLS()
\tif err != nil {
\t\treturn nil, 0, err
\t}
\tc.closed = false
\tvar fns []conn.ReceiveFunc''')
main = replace_once(main, '\t// TODO: Combine receiveIPv4 and receiveIPv6', '''\tif tlsTransport != nil {
\t\tfns = append(fns, c.Conn.merlinTLSReceive(tlsTransport))
\t}
\t// TODO: Combine receiveIPv4 and receiveIPv6''')
main = replace_once(main, '\tc.closed = true\n\t// Unblock all outstanding receives.', '''\tc.closed = true
\tif t := c.Conn.merlinTLS.Swap(nil); t != nil {
\t\tt.Close()
\t}
\t// Unblock all outstanding receives.''')
main = replace_once(main, 'func (c *Conn) Close() error {', '''func (c *Conn) Close() error {
\tif t := c.merlinTLS.Swap(nil); t != nil {
\t\tt.Close()
\t}''')
# Insert after the existing key-expiry check, before selecting UDP or DERP.
ep = replace_once(ep, '''func (de *endpoint) send(buffs [][]byte, offset int) error {
\tde.mu.Lock()
\tif de.expired {
\t\tde.mu.Unlock()
\t\treturn errExpired
\t}
''', '''func (de *endpoint) send(buffs [][]byte, offset int) error {
\tde.mu.Lock()
\tif de.expired {
\t\tde.mu.Unlock()
\t\treturn errExpired
\t}
\tif t := de.c.merlinTLS.Load(); t != nil && t.peer == de.publicKey {
\t\tnow := mono.Now()
\t\tde.noteTxActivityExtTriggerLocked(now)
\t\tde.lastSendAny = now
\t\tde.mu.Unlock()
\t\treturn t.send(buffs, offset)
\t}
''')
# Only write once all integration anchors have been verified.
main_path.write_text(main)
ep_path.write_text(ep)
for src in overlay.rglob('*.go'):
    dest = root / src.relative_to(overlay)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
print('Applied direct TLS + custom SNI transport (experimental, one peer)')
