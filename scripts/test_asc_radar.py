#!/usr/bin/env python3
"""Decision-table tests for the release radar.

The radar's only interesting logic is `decide()` — everything else is the
shared API plumbing already exercised by `test_asc_metadata.py`. `decide()`
is pure, so the table is tested exhaustively with no stubbing at all.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc_radar import decide  # noqa: E402

FAILURES = []


def check(name: str, got, want) -> None:
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILURES.append(name)
        print(f"  FAIL {name}: got {got!r}, want {want!r}")


print("radar decision table")

check(
    "no record yet means absent, never a release",
    decide({}, "3.2.1", True),
    ("absent", "no App Store record for 3.2.1"),
)
check(
    "other versions' states do not leak onto the target",
    decide({"2.15.1": "PENDING_DEVELOPER_RELEASE"}, "3.2.1", True)[0],
    "absent",
)
check(
    "waiting for review is wait",
    decide({"3.2.1": "WAITING_FOR_REVIEW"}, "3.2.1", True),
    ("wait", "WAITING_FOR_REVIEW"),
)
check(
    "in review is wait",
    decide({"3.2.1": "IN_REVIEW"}, "3.2.1", True)[0],
    "wait",
)
check(
    "approved releases only when auto-release is on",
    decide({"3.2.1": "PENDING_DEVELOPER_RELEASE"}, "3.2.1", True),
    ("release", "PENDING_DEVELOPER_RELEASE"),
)
check(
    "approved holds when auto-release is off",
    decide({"3.2.1": "PENDING_DEVELOPER_RELEASE"}, "3.2.1", False),
    ("hold", "PENDING_DEVELOPER_RELEASE"),
)
check(
    "ready for sale is live",
    decide({"3.2.1": "READY_FOR_SALE"}, "3.2.1", True)[0],
    "live",
)
check(
    "ready for distribution is live too",
    decide({"3.2.1": "READY_FOR_DISTRIBUTION"}, "3.2.1", True)[0],
    "live",
)
check(
    "a rejection pages a human",
    decide({"3.2.1": "REJECTED"}, "3.2.1", True)[0],
    "rejected",
)
check(
    "metadata rejection pages a human",
    decide({"3.2.1": "METADATA_REJECTED"}, "3.2.1", True)[0],
    "rejected",
)
check(
    "developer rejection pages a human",
    decide({"3.2.1": "DEVELOPER_REJECTED"}, "3.2.1", True)[0],
    "rejected",
)
check(
    "an unknown state fails closed into wait, not release or rejected",
    decide({"3.2.1": "SOME_FUTURE_STATE"}, "3.2.1", True)[0],
    "wait",
)
check(
    "prepare-for-submission is wait, not absent",
    decide({"3.2.1": "PREPARE_FOR_SUBMISSION"}, "3.2.1", True)[0],
    "wait",
)

if FAILURES:
    print(f"\n{len(FAILURES)} failing")
    sys.exit(1)
print("\nall green")
