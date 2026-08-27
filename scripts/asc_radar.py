#!/usr/bin/env python3
"""Watch the App Store review pipeline; optionally press Release on approval.

The metadata script (`asc_metadata.py`) pushes and submits. This one answers
the question that comes *after* submitting: "has Apple decided yet?" — and,
when told to, performs the one write that decision unlocks: releasing a
version that sits in PENDING_DEVELOPER_RELEASE (release type is MANUAL, so
approval alone never makes the app live).

Runs on a schedule in CI, where the APP_STORE_CONNECT_* secrets live. Every
run prints one machine-readable line per version plus a RADAR summary line
for the target version, so both a human reading the log and a script parsing
it get the same facts.

The write is double-gated: it happens only when the target version is
actually releasable AND AUTO_RELEASE=yes is set in the environment. Every
other path is read-only.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_metadata as asc  # noqa: E402  (auth + call plumbing)

RELEASABLE = "PENDING_DEVELOPER_RELEASE"
# Any state Apple uses to say "a human said no". Matched exactly, not by
# substring: a hypothetical future state must fail closed into "wait", where
# a human reads the log, rather than into "rejected", which pages the maker.
REJECTED_STATES = {
    "REJECTED",
    "DEVELOPER_REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}


def decide(states: dict[str, str], target: str, auto_release: bool) -> tuple[str, str]:
    """What to do about `target`, given every version's state.

    Pure — no I/O — so the whole decision table is unit-testable without the
    API. Returns (action, detail):

      absent           no App Store record for the target version yet
      release-blocker  the target cannot even be created because a DIFFERENT
                       approved version is parked in PENDING_DEVELOPER_RELEASE
                       (Apple refuses new-version creation in that state);
                       detail names the parked version, and main() releases it
      wait             submitted / in review / preparing — nothing to do
      hold             approved and releasable, but AUTO_RELEASE is off
      release          approved and releasable, and AUTO_RELEASE is on
      live             already on the App Store
      rejected         Apple (or a developer action) rejected it — needs a human
    """
    state = states.get(target)
    if state is None:
        blocker = next((v for v, s in states.items() if s == RELEASABLE), None)
        if blocker is not None and auto_release:
            return "release-blocker", blocker
        return "absent", f"no App Store record for {target}"
    if state in asc.LIVE_STATES:
        return "live", state
    if state in REJECTED_STATES:
        return "rejected", state
    if state == RELEASABLE:
        return ("release" if auto_release else "hold"), state
    return "wait", state


def release(bearer: str, version_id: str) -> str:
    """POST the release request — the API's 'press Release' button.

    Returns 'released', 'already-pressed', or 'failed'. The distinction
    matters: Apple keeps the version in PENDING_DEVELOPER_RELEASE for a while
    after a release request is accepted, so the next scheduled run WILL see
    the same state and try again — that duplicate must stay quiet. But a
    genuinely failed press (expired key, lapsed agreement, 500) must NOT be
    swallowed as "already pressed", or the app silently never goes live while
    every run reports success. This does its own HTTP call instead of
    `asc.call` precisely because it needs the error body to tell the two
    apart.
    """
    body = json.dumps({
        "data": {
            "type": "appStoreVersionReleaseRequests",
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            },
        }
    }).encode()
    request = urllib.request.Request(
        f"{asc.API}/appStoreVersionReleaseRequests", data=body, method="POST"
    )
    request.add_header("Authorization", f"Bearer {bearer}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request):
            return "released"
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        # A duplicate press comes back as a conflict/state error naming the
        # version's state. Anything else is a real failure and must page.
        if error.code in (409, 422) and "STATE_ERROR" in detail:
            print("  release request rejected as a state conflict — most "
                  "likely already pressed on a previous run")
            return "already-pressed"
        print(f"  release request FAILED: HTTP {error.code}\n{detail[:800]}")
        return "failed"
    except urllib.error.URLError as error:
        print(f"  release request FAILED: {error}")
        return "failed"


def main() -> None:
    target = os.environ.get("TARGET_VERSION", "").strip()
    if not target:
        asc.die("TARGET_VERSION is not set")
    auto_release = os.environ.get("AUTO_RELEASE", "").strip().lower() == "yes"

    # A hung connection must fail the run (the schedule is the retry), not
    # stall the job until the Actions six-hour kill.
    socket.setdefaulttimeout(30)

    bearer = asc.token()
    app = asc.find_app(bearer)

    # limit=50 matches has_prior_version: the target must never fall off the
    # page and read as "absent" while it sits approved.
    query = urllib.parse.urlencode({"filter[platform]": asc.PLATFORM, "limit": "50"})
    versions = asc.call(
        "GET", f"/apps/{app['id']}/appStoreVersions?{query}", bearer=bearer
    )["data"]

    # version string -> (state, record id). One dict so state and id cannot
    # come from different records; first record wins if Apple ever returns a
    # duplicate version string.
    records: dict[str, tuple[str, str]] = {}
    for entry in versions:
        attrs = entry["attributes"]
        name = attrs.get("versionString") or "?"
        state = attrs.get("appVersionState") or attrs.get("appStoreState") or "unknown"
        records.setdefault(name, (state, entry["id"]))
        print(f"  version {name}: state={state}")

    states = {name: state for name, (state, _) in records.items()}
    action, detail = decide(states, target, auto_release)

    if action == "release":
        outcome = release(bearer, records[target][1])
        if outcome == "released":
            print(f"  RELEASED — requested release of {target}")
        elif outcome == "failed":
            # Surfaces in the issue title and reopens a closed issue — the
            # mirror step treats release-failed like a rejection.
            action = "release-failed"
    elif action == "release-blocker":
        # `detail` is the parked version standing in the target's way.
        outcome = release(bearer, records[detail][1])
        if outcome == "released":
            print(f"  RELEASED — {detail} was blocking {target}'s creation")
        elif outcome == "failed":
            action = "release-failed"

    # The one line consumers parse. Stable format; append, don't reshape.
    print(f"RADAR target={target} action={action} detail={detail}")

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"action={action}\nstate={detail}\ntarget={target}\n")


if __name__ == "__main__":
    main()
