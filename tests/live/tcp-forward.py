#!/usr/bin/env python3
"""Forward 127.0.0.1:LISTEN to 127.0.0.1:TARGET, so a dead provider can come back.

    tcp-forward.py LISTEN TARGET

tests/live/opencode-smoke.sh points opencode at LISTEN with nothing listening
there, which is a provider that cannot be reached. Starting this afterwards is
how the same opencode PROCESS sees that provider recover, which is what the
recovery half of the dead-turn fix has to be tested against: the suppression
lives in one plugin instance, so a fresh pane would prove nothing about it.

Rewriting opencode.json under a live TUI does NOT work, and that is why this
file exists rather than a one-line `write_config`. Measured on opencode 1.18.20:
the config was repointed at a working ollama between two turns of one session,
and the next turn still retried the old address five times and ended in the same
APIError. The provider client is resolved once and cached, so the address
opencode knows is fixed for the life of the process. Moving a listener onto that
address is the only lever left from outside it.

Raw bytes both ways, with no HTTP parsing: the ollama endpoint speaks
OpenAI-compatible HTTP/1.1, and responses stream. Anything this proxy tried to
understand it could also get wrong, and a test harness that corrupts the traffic
it is meant to be neutral about is worse than no test.
"""
import socket
import sys
import threading


def pipe(src, dst):
    """Copy one direction until it closes, then half-close the far side.

    The half-close matters: a request body ends by the client shutting down its
    write side, and a proxy that swallowed that would leave ollama waiting for
    bytes that are never coming, which reads as a hung provider rather than a
    working one.
    """
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        # A peer that goes away mid-copy is normal here -- opencode closes
        # connections it has finished with. It must not take the proxy down
        # with it, because later turns still need to connect.
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def main(listen_port, target_port):
    server = socket.socket()
    # The smoke test picks this port by binding port 0 and closing it, so the
    # port is in TIME_WAIT from that probe when we get here.
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", listen_port))
    server.listen(64)
    while True:
        client, _ = server.accept()
        try:
            upstream = socket.create_connection(("127.0.0.1", target_port))
        except OSError:
            # Refusing one connection is right if ollama itself is down; the
            # proxy stays up so the next attempt can still succeed.
            client.close()
            continue
        # Daemon threads: the smoke test kills this process at the end of the
        # run, and an in-flight copy must not keep it alive past that.
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(64)
main(int(sys.argv[1]), int(sys.argv[2]))
