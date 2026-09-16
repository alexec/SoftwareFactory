import json, subprocess, sys, threading, time

AGENTS = {
    "Claude Code": ["/opt/homebrew/bin/claude-agent-acp"],
    "Copilot": ["/opt/homebrew/bin/copilot", "--acp"],
    "Grok": ["/Users/alexcollins/.grok/bin/grok", "agent", "stdio"],
    "Cursor": ["/Users/alexcollins/.local/bin/cursor-agent", "acp"],
}

INIT = {
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": {"readTextFile": False, "writeTextFile": False},
            "terminal": False,
            "elicitation": {"form": {}},
        },
    },
}

def probe(name, argv, seconds=20):
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, bufsize=1)
    except Exception as e:
        return {"error": "could not start: %s" % e}
    out = {}
    def read():
        for line in p.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get("id") == 1 and "result" in row:
                out["result"] = row["result"]
                return
            if row.get("id") == 1 and "error" in row:
                out["error"] = row["error"]
                return
    t = threading.Thread(target=read, daemon=True)
    t.start()
    p.stdin.write(json.dumps(INIT) + "\n")
    p.stdin.flush()
    t.join(seconds)
    if not out:
        out["error"] = "no answer in %ds" % seconds
        try:
            p.stderr.close()
        except Exception:
            pass
    p.kill()
    return out

results = {}
for name, argv in AGENTS.items():
    sys.stderr.write("probing %s...\n" % name)
    results[name] = probe(name, argv)
print(json.dumps(results, indent=1))
