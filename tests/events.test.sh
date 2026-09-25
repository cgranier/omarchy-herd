#!/bin/bash
# Tests for bin/herd-events against a fake herdr socket. Run with: bash tests/events.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BRIDGE="$HERE/../bin/herd-events"
T=$(mktemp -d); trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi; }

# A fake server: answers the subscribe, then plays the scenario named in its argument.
server() { # socket scenario
  python3 - "$1" "$2" <<'EOF' &
import socket, sys, os, time
path, scenario = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); s.listen(1)
c, _ = s.accept()
req = b""
while not req.endswith(b"\n"):
    req += c.recv(4096)
c.sendall(b'{"id":"herd-events","result":{"ok":true}}\n')
if scenario == "events":
    for i in range(3):
        c.sendall(b'{"type":"pane.agent_status_changed","pane_id":"w1:p%d"}\n' % i); time.sleep(0.05)
elif scenario == "bigframe":
    c.sendall(b'{"type":"x","junk":"' + b"A" * 200000 + b'"}\n')
elif scenario == "unterminated":
    c.sendall(b"B" * 200000); time.sleep(0.5)
elif scenario == "flood":
    line = b'{"type":"pane.created","pane_id":"w1:p1"}\n'
    for _ in range(3000):
        try: c.sendall(line)
        except OSError: break
elif scenario == "refuse":
    pass
time.sleep(0.3); c.close(); s.close()
EOF
  sleep 0.3
}
REQ='{"id":"herd-events","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.created"}]}}'

server "$T/a.sock" events; out=$(timeout 5 python3 "$BRIDGE" "$T/a.sock" "$REQ"); rc=$?
check "subscribe reply and three events come through, server close ends with 0" '[[ $rc == 0 && $(wc -l <<<"$out") == 4 && $(head -1 <<<"$out") == *herd-events* ]]'

server "$T/b.sock" bigframe; out=$(timeout 5 python3 "$BRIDGE" "$T/b.sock" "$REQ" 2>/dev/null); rc=$?
check "a 200 KB frame ends the bridge with 3 before it is printed" '[[ $rc == 3 && $(wc -l <<<"$out") == 1 ]]'

server "$T/c.sock" unterminated; out=$(timeout 5 python3 "$BRIDGE" "$T/c.sock" "$REQ" 2>/dev/null); rc=$?
check "an unterminated 200 KB frame ends the bridge with 3" '[[ $rc == 3 ]]'

server "$T/d.sock" flood; out=$(HERD_EVENTS_MAX_TOTAL=20000 timeout 5 python3 "$BRIDGE" "$T/d.sock" "$REQ" 2>/dev/null); rc=$?
check "the byte budget ends the bridge with 4" '[[ $rc == 4 ]]'

out=$(timeout 5 python3 "$BRIDGE" "$T/nope.sock" "$REQ" 2>/dev/null); rc=$?
check "no socket: exit 2, nothing printed" '[[ $rc == 2 && -z $out ]]'

big=$(head -c 70000 /dev/zero | tr '\0' 'x'); out=$(timeout 5 python3 "$BRIDGE" "$T/a.sock" "$big" 2>/dev/null); rc=$?
check "an oversized subscribe request is refused before connecting" '[[ $rc == 1 ]]'

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
