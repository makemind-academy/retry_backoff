#!/usr/bin/env python3
"""retry-backoff: four callers hit one outage twice; retrying at once and backing off both get through, and the gateway counts the difference."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from appplayer import AppPlayer  # noqa: E402
from mcpclient import Server  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "gateway_server")
CAP = os.path.join(HERE, "captures")
SERVER_ID = "com.makemind.sample.retry"

with Server(["dart", "run", "bin/server.dart"], cwd=SERVER) as s:
    hammer = s.call("gate.run", {"strategy": "hammer"})
    polite = s.call("gate.run", {"strategy": "backoff"})
    assert hammer["accepted"] == 4 and polite["accepted"] == 4, "everybody must get through"
    assert polite["attempts"] < hammer["attempts"], (polite["attempts"], hammer["attempts"])
    assert polite["peak"] < hammer["peak"], (polite["peak"], hammer["peak"])

ap = AppPlayer()
ap.register_server(SERVER_ID, "Retries", cwd=SERVER)
ap.restart()
ap.open_server(SERVER_ID)
ap.wait_text("ATTEMPTS")
ap.tap("Run: retry at once")
ap.wait_text("Retry at once")
ap.wait_text("4 accepted")
ap.shot(f"{CAP}/01_hammering.png")
ap.tap("Run: back off with jitter")
ap.wait_text("Back off with jitter")
ap.wait_text("when retrying at once")
ap.shot(f"{CAP}/02_backoff.png")
print("retry-backoff: both strategies through, fewer attempts and a lower peak with backoff")
