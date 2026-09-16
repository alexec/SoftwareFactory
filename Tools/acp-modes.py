"""What modes each agent offers, measured rather than read.

The start bar offers the modes of the CLI you have picked before it is started, and
nothing knows them until an agent has handshaken and made a session. So they are measured
here, once, and written into `LaunchAgent.modesOffered`. Run it again when a CLI updates:

    python3 Tools/acp-modes.py

Each agent is started, handshaken, given a session in a scratch folder, and the
`availableModes` off that answer is what it offers. An agent that will not get that far
says so, and "not tried" is written down as itself rather than as "none". (T466.)
"""
import json, subprocess, sys, tempfile, threading

AGENTS = {
    "claudeCode": ["claude-agent-acp"],
    "copilot": ["copilot", "--acp"],
    "grok": ["grok", "agent", "stdio"],
    "cursor": ["cursor-agent", "acp"],
}

def rpc(id, method, params):
    return json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\n"

def probe(argv, cwd, seconds=45):
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, bufsize=1)
    except Exception as e:
        return {"error": "could not start: %s" % e}

    answers, done = {}, threading.Event()

    def read():
        for line in p.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if "id" in row and ("result" in row or "error" in row):
                answers[row["id"]] = row
                if row["id"] == 2:
                    done.set()
                    return
                if row["id"] == 1 and "error" in row:
                    done.set()
                    return

    threading.Thread(target=read, daemon=True).start()
    try:
        p.stdin.write(rpc(1, "initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": False, "writeTextFile": False},
                "terminal": False,
            },
        }))
        p.stdin.flush()
        # A session, which is where the modes are. No MCP servers: this is about the
        # agent's own modes and nothing else.
        p.stdin.write(rpc(2, "session/new", {"cwd": cwd, "mcpServers": []}))
        p.stdin.flush()
    except Exception as e:
        p.kill()
        return {"error": "would not take a request: %s" % e}

    got = done.wait(seconds)
    stderr = ""
    p.kill()
    try:
        stderr = (p.stderr.read() or "").strip().splitlines()[-1] if p.stderr else ""
    except Exception:
        pass
    if not got:
        return {"error": "no answer in %ss" % seconds, "stderr": stderr}
    if 1 in answers and "error" in answers[1]:
        return {"error": "initialize: %s" % answers[1]["error"].get("message"), "stderr": stderr}
    if 2 not in answers:
        return {"error": "no session", "stderr": stderr}
    if "error" in answers[2]:
        return {"error": "session/new: %s" % answers[2]["error"].get("message"), "stderr": stderr}
    modes = (answers[2]["result"] or {}).get("modes") or {}
    return {"currentModeId": modes.get("currentModeId"),
            "availableModes": modes.get("availableModes") or []}


def main():
    cwd = tempfile.mkdtemp(prefix="acp-modes-")
    out = {}
    for name, argv in AGENTS.items():
        sys.stderr.write("%s ...\n" % name)
        out[name] = probe(argv, cwd)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
