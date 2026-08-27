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

import os
import socket
import sys
import urllib.parse
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

      absent    no App Store record for the target version yet
      wait      submitted / in review / preparing — nothing to do
      hold      approved and releasable, but AUTO_RELEASE is off
      release   approved and releasable, and AUTO_RELEASE is on
      live      already on the App Store
      rejected  Apple (or a developer action) rejected it — needs a human
    """
    state = states.get(target)
    if state is None:
        return "absent", f"no App Store record for {target}"
    if state in asc.LIVE_STATES:
        return "live", state
    if state in REJECTED_STATES:
        return "rejected", state
    if state == RELEASABLE:
        return ("release" if auto_release else "hold"), state
    return "wait", state


def release(bearer: str, version_id: str) -> bool:
    """POST the release request — the API's 'press Release' button.

    Apple keeps the version in PENDING_DEVELOPER_RELEASE for a while after a
    release request is accepted, so on a 30-minute schedule the next run WILL
    see the same state and try again. Apple answers the duplicate with an
    error; treat that as "already pressed" rather than letting `die()` turn
    the happy path into a wall of red runs. `call()` exits via SystemExit on
    any HTTP error — catching it here is the same tolerate-and-report shape
    the review-submission probe used.
    """
    try:
        asc.call(
            "POST",
            "/appStoreVersionReleaseRequests",
            body={
                "data": {
                    "type": "appStoreVersionReleaseRequests",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
            bearer=bearer,
        )
        return True
    except SystemExit:
        print("  release request rejected — most likely already pressed on a "
              "previous run; leaving the version to transition on its own")
        return False


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
        if release(bearer, records[target][1]):
            print(f"  RELEASED — requested release of {target}")

    # The one line consumers parse. Stable format; append, don't reshape.
    print(f"RADAR target={target} action={action} detail={detail}")

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"action={action}\nstate={detail}\ntarget={target}\n")


if __name__ == "__main__":
    main()
