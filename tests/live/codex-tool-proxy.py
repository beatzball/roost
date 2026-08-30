#!/usr/bin/env python3
"""Strip the tool definitions ollama cannot parse out of codex's requests.

    codex-tool-proxy.py LISTEN UPSTREAM [LOGFILE]

Codex cannot drive ollama out of the box, and this file is the whole reason
tests/live/codex-smoke.sh needs more scaffolding than the opencode one did.
Measured on codex-cli 0.150.1 and again on 0.151.0, the tools array codex sends
on every turn is:

    ['function', 'function', 'function', 'function', 'function',
     'namespace', 'function', 'function', 'function', 'web_search']

ollama rejects the two that are not `function` and answers HTTP 500 with a
precise parse error. `--disable multi_agent` removes the `namespace` one;
`[tools] web_search = false` does NOT remove the other. Codex's own built-in
provider (`--oss --local-provider ollama`) sends the same array and fails the
same way, so there is no supported path around this either.

What makes it worth a file rather than a comment is what codex prints when it
happens:

    ERROR: We're currently experiencing high demand, which may cause temporary
    errors.

That is ollama's 500 with a specific, actionable parse error underneath it,
reported as a load problem on someone else's servers. Anyone debugging a codex
smoke test without this proxy chases the wrong thing for as long as they believe
the message.

The filter is the narrowest one that works: drop every entry of `tools` whose
`type` is not `"function"`, forward the request otherwise byte-for-byte, and
stream the response back unread. Everything this proxy tried to understand it
could also get wrong, and a rig that corrupts the traffic it is meant to be
neutral about is worse than no rig — the same rule tests/live/tcp-forward.py
states for its own raw byte piping.
"""
import http.server
import json
import sys
import urllib.error
import urllib.request

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2].rstrip("/")
LOG = sys.argv[3] if len(sys.argv) > 3 else None


def log(msg):
    if not LOG:
        return
    with open(LOG, "a") as f:
        f.write(msg + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1 so the streamed chunked response below is legal; codex reads the
    # turn as a stream and a 1.0 response would have to be buffered whole.
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        # BaseHTTPRequestHandler logs every request to stderr, which in a smoke
        # test run is noise on top of the model's own output.
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except Exception:
            # Not JSON, or not JSON we understand: forward it untouched rather
            # than fail. The filter is an allowance for one known bug, not a
            # validator.
            body = None
        if isinstance(body, dict) and isinstance(body.get("tools"), list):
            before = [t.get("type") for t in body["tools"] if isinstance(t, dict)]
            body["tools"] = [
                t for t in body["tools"]
                if isinstance(t, dict) and t.get("type") == "function"
            ]
            log("REQ %s tools before=%s after=%s"
                % (self.path, before, [t.get("type") for t in body["tools"]]))
            raw = json.dumps(body).encode()
        else:
            log("REQ %s (no tools array)" % self.path)

        req = urllib.request.Request(
            UPSTREAM + self.path, data=raw, method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": self.headers.get("Accept", "*/*"),
                # ollama ignores the value but codex always sends one; passing
                # a placeholder through keeps this proxy usable with an
                # upstream that does check.
                "Authorization": self.headers.get("Authorization", "Bearer local"),
            },
        )
        try:
            up = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            payload = e.read()
            # The upstream's REAL error, logged in full. This is the line that
            # tells a human what codex's "high demand" message was hiding.
            log("UPSTREAM %d: %r" % (e.code, payload[:2000]))
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        except Exception as e:
            log("UPSTREAM ERROR: %r" % (e,))
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(up.status)
        self.send_header("Content-Type", up.headers.get("Content-Type", "application/json"))
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                chunk = up.read(1024)
                if not chunk:
                    break
                # Flush per chunk. Codex renders the turn as it streams, and a
                # buffered proxy turns a live TUI into a long pause followed by
                # everything at once — which reads exactly like a hung model
                # when a smoke test is waiting on a readiness string.
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except Exception as e:
            log("STREAM ERROR: %r" % (e,))

    def do_GET(self):
        # /v1/models and friends. No filtering applies; this exists so codex's
        # startup probes do not fail against the proxy.
        try:
            up = urllib.request.urlopen(UPSTREAM + self.path)
            payload = up.read()
            self.send_response(up.status)
            self.send_header("Content-Type", up.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as e:
            log("GET ERROR %s: %r" % (self.path, e))
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
