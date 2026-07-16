#!/usr/bin/env python3
"""Open a new ChatGPT-app (codex) thread at a given directory via deeplink.

Usage: open-codex-thread.py <cwd> [thread-name]

Creates the thread through the bundled `codex app-server`, forces it to
persist by naming it, then opens codex://threads/<id> in the ChatGPT app.
CODEX_HOME must match the app's server home (~/.codex).
"""
import json, os, subprocess, sys, threading, queue, time

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
CWD = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
NAME = sys.argv[2] if len(sys.argv) > 2 else f"chat @ {os.path.basename(CWD)}"

env = {**os.environ, "CODEX_HOME": os.path.expanduser("~/.codex")}
proc = subprocess.Popen(
    [CODEX, "app-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    text=True, bufsize=1, env=env,
)
out_q = queue.Queue()
threading.Thread(target=lambda: [out_q.put(l) for l in proc.stdout], daemon=True).start()

def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()

def wait_for_id(rpc_id, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg = json.loads(out_q.get(timeout=max(0.1, deadline - time.time())))
        except (queue.Empty, json.JSONDecodeError):
            continue
        if msg.get("id") == rpc_id and ("result" in msg or "error" in msg):
            if "error" in msg:
                sys.exit(f"rpc error: {msg['error']}")
            return msg
    sys.exit(f"timed out waiting for response {rpc_id}")

send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
    "clientInfo": {"name": "open-codex-thread", "title": "open-codex-thread", "version": "1.0"}}})
wait_for_id(0)
send({"jsonrpc": "2.0", "method": "initialized"})

send({"jsonrpc": "2.0", "id": 1, "method": "thread/start", "params": {"cwd": CWD}})
tid = wait_for_id(1)["result"]["thread"]["id"]

# a bare thread/start is lazy — naming it forces the rollout to disk
send({"jsonrpc": "2.0", "id": 2, "method": "thread/name/set", "params": {"threadId": tid, "name": NAME}})
wait_for_id(2)

proc.stdin.close()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.terminate()

url = f"codex://threads/{tid}"
print(url)
subprocess.run(["open", url], check=True)
