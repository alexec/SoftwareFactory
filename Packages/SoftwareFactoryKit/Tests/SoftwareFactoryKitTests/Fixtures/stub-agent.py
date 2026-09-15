#!/usr/bin/env python3
"""An ACP agent with no model in it, for testing everything below the socket.

It answers initialize and session/new, and for a prompt it says what it was told, runs
one tool call, and optionally asks permission first. The first argument picks the
behaviour:
  plain       say it back and finish
  permission  ask before the tool call
  slow        take a while, so cancel has something to cancel
  crash       exit as soon as a session is made
"""
import json, sys, time

# An argument and not an environment variable: the tests run in parallel and setenv is
# process-global, so a mode set by one test was read by another.
mode = sys.argv[1] if len(sys.argv) > 1 else "plain"
session = "stub-session-1"
turns = 0

def out(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def update(body):
    out({"jsonrpc": "2.0", "method": "session/update",
         "params": {"sessionId": session, "update": body}})

# readline rather than `for line in sys.stdin`: the iterator reads ahead into an 8K
# buffer and blocks until it fills, so a JSON-RPC peer sending one line at a time gets
# no answer at all.
while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    ident = message.get("id")

    if method == "initialize":
        out({"jsonrpc": "2.0", "id": ident, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": True},
            "agentInfo": {"name": "stub", "version": "1"}}})
    elif method == "session/new":
        out({"jsonrpc": "2.0", "id": ident, "result": {"sessionId": session}})
        if mode == "crash":
            sys.exit(3)
    elif method == "session/load":
        session = message["params"]["sessionId"]
        out({"jsonrpc": "2.0", "id": ident, "result": {}})
    elif method == "session/prompt":
        words = message["params"]["prompt"][0]["text"]
        if mode == "permission":
            out({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission",
                 "params": {"sessionId": session,
                            "toolCall": {"toolCallId": "t1", "title": "Write notes.md", "kind": "edit",
                                         "status": "pending"},
                            "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                                        {"optionId": "allow_always", "name": "Always allow", "kind": "allow_always"},
                                        {"optionId": "no", "name": "Deny", "kind": "reject_once"}]}})
            # Wait for the answer before going on, exactly as a real agent does.
            answer = sys.stdin.readline()
            picked = json.loads(answer)["result"]["outcome"].get("optionId")
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "picked:" + str(picked)}})
        if mode == "slow":
            time.sleep(30)
        # A fresh id each turn, as a real agent gives: the same id twice is the same call
        # being updated, and the transcript is right to fold it into one row.
        turns += 1
        call = "t%d" % turns
        update({"sessionUpdate": "tool_call", "toolCallId": call, "title": "Reading README.md",
                "kind": "read", "status": "pending"})
        update({"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed"})
        for word in words.split(" "):
            update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": word + " "}})
        out({"jsonrpc": "2.0", "id": ident, "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        pass
    elif ident is not None:
        out({"jsonrpc": "2.0", "id": ident, "result": {}})
