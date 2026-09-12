#!/usr/bin/env python3
"""Drive the factory's MCP server the way a client does, over stdio.

    python3 Tools/drive-mcp.py <path-to-foreman> [project-path]

Registers an agent, files a task, raises a question, then blocks on escalation_await
until someone decides in the app (or two minutes pass). Prints each response.
"""
import json, subprocess, sys, time

server = sys.argv[1]
project = sys.argv[2] if len(sys.argv) > 2 else "/Users/alexcollins/Foreman"
p = subprocess.Popen([server, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
n = 0

def send(method, params=None, notify=False):
    global n
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        n += 1
        msg["id"] = n
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()
    if notify:
        return None
    line = p.stdout.readline()
    return json.loads(line)

def call(tool, args):
    r = send("tools/call", {"name": tool, "arguments": args})
    text = r["result"]["content"][0]["text"]
    print(f"{tool}: {text}", flush=True)
    return text

def uuid_in(text):
    for w in text.replace(".", " ").split():
        if len(w) == 36:
            return w

init = send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "drive", "version": "0"}})
print("server:", init["result"]["serverInfo"], flush=True)
send("notifications/initialized", notify=True)
tools = send("tools/list")["result"]["tools"]
print("tools:", " ".join(t["name"] for t in tools), flush=True)

agent = uuid_in(call("agent_register", {"name": "drive-lead", "project": project}))
task = uuid_in(call("task_add", {"project": project, "title": "Prove the narrow slice end to end", "kind": "chore"}))
call("task_claim", {"task_id": task, "agent_id": agent})
call("agent_checkin", {"agent_id": agent, "task_id": task, "note": "raising a question from a script"})
esc = uuid_in(call("escalation_raise", {
    "agent_id": agent, "project": project,
    "question": "Which option proves the slice?",
    "context": "A scripted agent raised this. Click any option in the app and the script should print it.",
    "options": [{"title": "The recommended one", "detail": "Marked recommended"},
                {"title": "The other one", "detail": "Not recommended"}],
    "recommended": 0,
}))
t0 = time.time()
answer = call("escalation_await", {"escalation_id": esc, "timeout_seconds": 120})
print(f"await returned after {time.time() - t0:.1f}s", flush=True)
call("task_status", {"task_id": task, "state": "done", "note": "the app answered: " + answer})
call("agent_deregister", {"agent_id": agent})
p.stdin.close()
p.wait(timeout=5)
print("exit", p.returncode, flush=True)
