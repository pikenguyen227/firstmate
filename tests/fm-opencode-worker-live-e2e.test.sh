#!/usr/bin/env bash
# Opt-in real OpenCode 2 worker lifecycle check with a disposable home and
# local scripted model. The generated worker plugin is installed by fm-spawn.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_OPENCODE_WORKER_LIVE_E2E opencode python3 node git

version=$(opencode --version)
[ "$version" = 'opencode v2.3.2' ] || fail "OpenCode worker guard needs pinned 2.3.2; found $version"
opencode_bin=$(command -v opencode)
lab=$(fm_test_tmproot fm-opencode-worker-live)
home="$lab/fmhome"
worker="$lab/worker"
id=opencode-worker-live

fm_test_spawn_home "$home" opencode
fm_git_worktree "$lab/project" "$worker" fm-opencode-worker-live
fm_test_spawn_brief "$home" "$id"
fakebin=$(make_spawn_fakebin "$lab/fake" opencode)
out=$(fm_test_run_spawn "$home" "$worker" "$fakebin" "$id" "$lab/project" --mode no-mistakes --yolo off) \
  || fail "OpenCode worker spawn failed: $out"
[ -f "$worker/.opencode/plugins/fm-busy-state.js" ] || fail 'OpenCode worker plugin was not installed'

OPENCODE_BIN="$opencode_bin" LAB="$lab" WORKER="$worker" FM_HOME="$home" TASK_ID="$id" python3 - <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import pty
import signal
import subprocess
import sys
import threading
import time

lab = Path(os.environ["LAB"])
worker = Path(os.environ["WORKER"])
home = Path(os.environ["FM_HOME"])
task_id = os.environ["TASK_ID"]
state = home / "state" / f"{task_id}.busy-state"
turn_end = home / "state" / f"{task_id}.turn-ended"
requests = []


class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        payload = b'{"object":"list","data":[{"id":"local-test","object":"model"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0")))
        requests.append(json.loads(body))
        time.sleep(5)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for delta, finish in [
            ({"role": "assistant", "content": "WORKER_READY"}, None),
            ({}, "stop"),
        ]:
            chunk = {
                "id": "chatcmpl-local",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": "local-test",
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
config = {
    "model": "local/test",
    "permission": {"*": "allow"},
    "providers": {"local": {
        "name": "Local scripted model",
        "package": "@opencode/ai/providers/openai-compatible",
        "settings": {"baseURL": f"http://127.0.0.1:{port}/v1"},
        "models": {"test": {
            "modelID": "local-test",
            "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
            "limit": {"context": 200000, "output": 8192},
        }},
    }},
}
(worker / ".opencode" / "opencode.json").write_text(json.dumps(config))
env = os.environ.copy()
for name, suffix in [
    ("HOME", "user-home"),
    ("XDG_CONFIG_HOME", "xdg-config"),
    ("XDG_DATA_HOME", "xdg-data"),
    ("XDG_CACHE_HOME", "xdg-cache"),
]:
    path = lab / suffix
    path.mkdir()
    env[name] = str(path)
env["FM_HOME"] = str(home)
env["TERM"] = "xterm-256color"
env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
env.pop("OPENCODE_CONFIG_CONTENT", None)
master, slave = pty.openpty()
proc = subprocess.Popen(
    [os.environ["OPENCODE_BIN"], "--standalone", "--auto", "--prompt", "Reply WORKER_READY once."],
    cwd=worker, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
)
os.close(slave)


def drain():
    with (lab / "terminal.log").open("wb") as log:
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            log.write(chunk)


reader = threading.Thread(target=drain, daemon=True)
reader.start()


def wait_for(predicate, label):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if predicate():
            return
        if proc.poll() is not None:
            raise RuntimeError(f"OpenCode exited before {label}: code {proc.returncode}")
        time.sleep(0.1)
    raise RuntimeError(f"OpenCode 2.3.2 did not reach {label}; state={state.read_text() if state.exists() else 'absent'}")


try:
    wait_for(lambda: "state=busy source=opencode-plugin event=session-execution-started" in state.read_text(), "busy")
    if turn_end.exists():
        raise RuntimeError("turn-end marker appeared before the real execution settled")
    wait_for(lambda: "state=idle source=opencode-plugin event=session.execution.succeeded" in state.read_text() and turn_end.exists(), "idle and turn-ended")
    if not requests:
        raise RuntimeError("the local model received no request")
    print("ok - OpenCode 2.3.2 worker TUI reports busy, then idle, and touches .turn-ended")
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
    proc.wait(timeout=10)
    os.close(master)
    reader.join(timeout=2)
    server.shutdown()
    server.server_close()
PY
