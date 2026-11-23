#!/usr/bin/env bash
# Opt-in real OpenCode 2 worker lifecycle check with a disposable home and
# local scripted model. fm-spawn installs the worker plugin and stages the launch
# command; the guard runs that staged command unchanged, so its env config,
# model, effort variant, and permission posture are the ones a worker gets.
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
out=$(FM_FAKE_LAUNCH_LOG="$lab/launch.sh" fm_test_run_spawn "$home" "$worker" "$fakebin" "$id" "$lab/project" \
  --mode no-mistakes --yolo off --model openai/local-test --effort high) \
  || fail "OpenCode worker spawn failed: $out"
[ -f "$worker/.opencode/plugins/fm-busy-state.js" ] || fail 'OpenCode worker plugin was not installed'
[ -s "$lab/launch.sh" ] || fail 'fm-spawn staged no OpenCode launch command'

OPENCODE_DIR="${opencode_bin%/*}" LAB="$lab" WORKER="$worker" FM_HOME="$home" TASK_ID="$id" python3 - <<'PY'
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
tool_file = worker / "tool-ran.txt"
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
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))))
        turn = body.get("tools")
        if turn:
            requests.append(body)
            time.sleep(3)
        if turn and not any(m.get("role") == "tool" for m in body["messages"]):
            call = {"index": 0, "id": "call_fm_live", "type": "function", "function": {
                "name": "shell",
                "arguments": json.dumps({"command": f"printf ran > {tool_file.name}", "description": "Write marker"}),
            }}
            frames = [({"role": "assistant", "tool_calls": [call]}, None), ({}, "tool_calls")]
        else:
            frames = [({"role": "assistant", "content": "WORKER_READY"}, None), ({}, "stop")]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for delta, finish in frames:
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
    "providers": {"openai": {
        "name": "Local scripted model",
        "package": "@opencode/ai/providers/openai-compatible",
        "settings": {"baseURL": f"http://127.0.0.1:{port}/v1"},
        "models": {"local-test": {
            "modelID": "local-test",
            "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
            "limit": {"context": 200000, "output": 8192},
        }},
    }},
}
env = os.environ.copy()
for name, suffix in [
    ("HOME", "user-home"),
    ("XDG_CONFIG_HOME", "xdg-config"),
    ("XDG_DATA_HOME", "xdg-data"),
    ("XDG_CACHE_HOME", "xdg-cache"),
    ("XDG_STATE_HOME", "xdg-state"),
]:
    path = lab / suffix
    path.mkdir(exist_ok=True)
    env[name] = str(path)
(lab / "xdg-config" / "opencode").mkdir()
(lab / "xdg-config" / "opencode" / "opencode.json").write_text(json.dumps(config))
env["FM_HOME"] = str(home)
env["TERM"] = "xterm-256color"
env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
env["PATH"] = os.environ["OPENCODE_DIR"] + os.pathsep + env["PATH"]
env.pop("OPENCODE_CONFIG_CONTENT", None)
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["/bin/sh", str(lab / "launch.sh")],
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
    first = requests[0]
    if first.get("model") != "local-test" or first.get("reasoning_effort") != "high":
        raise RuntimeError(f"launch config did not select the model and effort variant: model={first.get('model')} reasoning_effort={first.get('reasoning_effort')}")
    if not tool_file.exists() or tool_file.read_text() != "ran":
        raise RuntimeError("the shell tool call did not run without a permission prompt")
    if not any(any(m.get("role") == "tool" for m in r["messages"]) for r in requests):
        raise RuntimeError("the model never received the shell tool result")
    print("ok - fm-spawn's OpenCode 2.3.2 worker launch honours its config, runs a tool unprompted, reports busy then idle, and touches .turn-ended")
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
    proc.wait(timeout=10)
    os.close(master)
    reader.join(timeout=2)
    server.shutdown()
    server.server_close()
PY
