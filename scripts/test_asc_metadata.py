#!/usr/bin/env python3
"""Control-flow tests for asc_metadata.py against a stubbed App Store Connect.

The script talks to a live, credentialed API, so it cannot run in CI — which
is precisely why its *control flow* went unexercised and shipped three bugs
that a few minutes of stubbing caught (a 404 aborting `push` on first run, a
silent no-op on app-info creation, and a promised warning that never printed).

These stub the HTTP layer and assert on the calls made. No credentials, no
network. Run: python3 scripts/test_asc_metadata.py
"""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import urllib.parse
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("asc", HERE / "asc_metadata.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

FAILURES: list[str] = []


def check(condition: bool, label: str) -> None:
    print(("  ok   " if condition else "  FAIL ") + label)
    if not condition:
        FAILURES.append(label)


class StubAPI:
    """Records calls and replies from a canned routing table."""

    def __init__(self, routes: dict, missing: tuple = ()):
        self.routes = routes
        self.missing = missing
        self.calls: list[tuple[str, str, dict | None]] = []

    def __call__(self, method, path, body=None, bearer="", allow_missing=False):
        self.calls.append((method, path, body))
        for fragment in self.missing:
            # endswith, not substring: the singular relationship GET
            # ".../appStoreReviewDetail" and the plural create POST
            # "/appStoreReviewDetails" differ only by the final character.
            if path.endswith(fragment):
                if allow_missing:
                    return {}
                # Mirror the real client: a 404 without allow_missing exits.
                asc.die(f"{method} {path} -> HTTP 404")
        # Longest fragment first: "/appInfos/INFO/appInfoLocalizations" also
        # contains "appInfos", and insertion-order matching would hand back the
        # wrong payload.
        for fragment in sorted(self.routes, key=len, reverse=True):
            if fragment in path:
                return self.routes[fragment]
        return {"data": []}

    def paths(self, method: str | None = None) -> list[str]:
        return [p for m, p, _ in self.calls if method is None or m == method]

    def body_for(self, method: str, fragment: str) -> dict | None:
        for m, p, b in self.calls:
            if m == method and fragment in p:
                return b
        return None


def metadata_root() -> Path:
    """A realistic metadata tree in a temp dir."""
    root = Path(tempfile.mkdtemp())
    locale = root / "metadata" / "en-US"
    locale.mkdir(parents=True)
    for name, text in {
        "description": "A reader you can ask.",
        "keywords": "epub,ebook",
        "promotional_text": "Ask your books.",
        "release_notes": "Ask keeps the conversation.",
        "support_url": "https://example.invalid/support",
        "marketing_url": "https://example.invalid/",
        "name": "Readr: AI Ebook Reader",
        "subtitle": "Ask your books questions",
        "privacy_url": "https://example.invalid/privacy",
    }.items():
        (locale / f"{name}.txt").write_text(text + "\n")
    (root / "review_notes.txt").write_text("Reviewer notes.\n")
    return root


APP = {"id": "APPID", "attributes": {"name": "Readr"}}


def run_push(stub: StubAPI, root: Path, first_version: bool = False) -> str:
    original, asc.call = asc.call, stub
    out = io.StringIO()
    try:
        with redirect_stdout(out):
            asc.push(
                "tok", APP, "VERID",
                asc.read_metadata(root), True,
                root=root, first_version=first_version,
            )
    finally:
        asc.call = original
    return out.getvalue()


def test_missing_review_detail_does_not_abort() -> None:
    """The blocker: a fresh version has no review detail, so the GET 404s.
    That must create it, not kill the run after half the listing is written."""
    print("\nreview detail absent (404)")
    root = metadata_root()
    stub = StubAPI(
        routes={
            "appStoreVersionLocalizations": {"data": [
                {"id": "LOC", "attributes": {"locale": "en-US"}}]},
            "appInfos": {"data": [
                {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
            "appInfoLocalizations": {"data": [
                {"id": "ILOC", "attributes": {"locale": "en-US"}}]},
        },
        missing=("appStoreReviewDetail",),
    )
    run_push(stub, root)
    check(
        any(m == "POST" and p == "/appStoreReviewDetails" for m, p, _ in stub.calls),
        "creates the review detail instead of dying",
    )


def test_existing_review_detail_is_patched() -> None:
    print("\nreview detail present")
    root = metadata_root()
    stub = StubAPI(routes={
        "appStoreReviewDetail": {"data": {"id": "RD"}},
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
        "appInfoLocalizations": {"data": [
            {"id": "ILOC", "attributes": {"locale": "en-US"}}]},
    })
    run_push(stub, root)
    check(
        "/appStoreReviewDetails/RD" in stub.paths("PATCH"),
        "patches the existing review detail",
    )


def test_app_info_localization_is_created_when_absent() -> None:
    """Previously printed success and made no call at all."""
    print("\napp-info localization absent")
    root = metadata_root()
    stub = StubAPI(routes={
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
        "appInfoLocalizations": {"data": []},
        "appStoreReviewDetail": {"data": {"id": "RD"}},
    })
    run_push(stub, root)
    check(
        "/appInfoLocalizations" in stub.paths("POST"),
        "creates the missing app-info localization",
    )


def test_whats_new_omitted_on_debut_version() -> None:
    """Apple rejects whatsNew on a first version, and it shared one PATCH with
    everything else — so its rejection emptied the whole listing."""
    print("\ndebut version")
    root = metadata_root()
    stub = StubAPI(routes={
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
        "appInfoLocalizations": {"data": [
            {"id": "ILOC", "attributes": {"locale": "en-US"}}]},
        "appStoreReviewDetail": {"data": {"id": "RD"}},
    })
    run_push(stub, root, first_version=True)
    body = stub.body_for("PATCH", "/appStoreVersionLocalizations/LOC")
    attributes = (body or {}).get("data", {}).get("attributes", {})
    check("whatsNew" not in attributes, "omits whatsNew on a debut version")
    check("description" in attributes, "still writes the rest of the listing")


def test_whats_new_included_on_later_version() -> None:
    print("\nsubsequent version")
    root = metadata_root()
    stub = StubAPI(routes={
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
        "appInfoLocalizations": {"data": [
            {"id": "ILOC", "attributes": {"locale": "en-US"}}]},
        "appStoreReviewDetail": {"data": {"id": "RD"}},
    })
    run_push(stub, root, first_version=False)
    body = stub.body_for("PATCH", "/appStoreVersionLocalizations/LOC")
    attributes = (body or {}).get("data", {}).get("attributes", {})
    check("whatsNew" in attributes, "includes whatsNew when a prior version exists")


def test_live_app_info_is_never_selected() -> None:
    """Fail closed: an unknown state must not be treated as editable."""
    print("\napp-info selection")
    root = metadata_root()
    stub = StubAPI(routes={
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "LIVE", "attributes": {"state": "READY_FOR_DISTRIBUTION"}},
            {"id": "UNKNOWN", "attributes": {}},
        ]},
        "appInfoLocalizations": {"data": []},
        "appStoreReviewDetail": {"data": {"id": "RD"}},
    })
    run_push(stub, root)
    check(
        not any("LIVE" in p for p in stub.paths()),
        "never touches the live app info",
    )
    check(
        not any("UNKNOWN" in p for p in stub.paths()),
        "an absent state fails closed rather than open",
    )


def test_build_query_requires_a_processed_build() -> None:
    print("\nbuild selection")
    stub = StubAPI(routes={"/builds": {"data": []}})
    original, asc.call = asc.call, stub
    try:
        asc.latest_build("tok", "APPID", "2.15.0")
    finally:
        asc.call = original
    # The query is percent-encoded (filter%5B...%5D), so assert on the decoded
    # form rather than on the literal brackets.
    query = urllib.parse.unquote(stub.paths()[0])
    check("filter[processingState]=VALID" in query, "only attaches a processed build")
    check("filter[preReleaseVersion.platform]=IOS" in query, "filters on platform")


def test_missing_review_notes_is_announced() -> None:
    print("\nreview notes absent")
    root = metadata_root()
    (root / "review_notes.txt").unlink()
    stub = StubAPI(routes={
        "appStoreVersionLocalizations": {"data": [
            {"id": "LOC", "attributes": {"locale": "en-US"}}]},
        "appInfos": {"data": [
            {"id": "INFO", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]},
        "appInfoLocalizations": {"data": [
            {"id": "ILOC", "attributes": {"locale": "en-US"}}]},
    })
    output = run_push(stub, root)
    check("skipping" in output, "says so rather than silently skipping")


def test_manual_steps_always_print() -> None:
    """The App Privacy reminder is the one thing no API covers, and the
    early-return plan path used to swallow it."""
    print("\nmanual-steps reminder")
    out = io.StringIO()
    with redirect_stdout(out):
        asc.manual_steps()
    text = out.getvalue()
    check("App Privacy" in text, "names the App Privacy questionnaire")
    check("Age rating" in text, "names the age rating")
    check("Screenshots" in text, "names screenshots")


def test_editable_draft_is_renamed_not_duplicated() -> None:
    """Apple allows one editable version at a time, so POSTing a second is a
    409 naming no cause. An existing PREPARE_FOR_SUBMISSION draft is renamed."""
    print("\nexisting editable draft")
    stub = StubAPI(routes={
        "filter%5BversionString%5D": {"data": []},
        "appStoreVersions": {"data": [
            {"id": "DRAFT", "attributes": {
                "versionString": "1.0",
                "appVersionState": "PREPARE_FOR_SUBMISSION"}}]},
    })
    original, asc.call = asc.call, stub
    out = io.StringIO()
    try:
        with redirect_stdout(out):
            asc.find_or_create_version("tok", "APPID", "2.15.0", True)
    finally:
        asc.call = original
    check("/appStoreVersions/DRAFT" in stub.paths("PATCH"), "renames the draft")
    check("/appStoreVersions" not in stub.paths("POST"), "does not POST a second version")
    body = stub.body_for("PATCH", "/appStoreVersions/DRAFT") or {}
    check(
        body.get("data", {}).get("attributes", {}).get("versionString") == "2.15.0",
        "renames it to the requested version",
    )


def test_submitted_version_is_never_renamed() -> None:
    """A version in review or live must never be renamed out from under it."""
    print("\nnon-editable version present")
    stub = StubAPI(routes={
        "filter%5BversionString%5D": {"data": []},
        "appStoreVersions": {"data": [
            {"id": "LIVE", "attributes": {
                "versionString": "1.0",
                "appVersionState": "READY_FOR_DISTRIBUTION"}}]},
    })
    original, asc.call = asc.call, stub
    out = io.StringIO()
    try:
        with redirect_stdout(out):
            asc.find_or_create_version("tok", "APPID", "2.15.0", True)
    finally:
        asc.call = original
    check(
        not any("LIVE" in p for p in stub.paths("PATCH")),
        "leaves a live version alone",
    )
    check("/appStoreVersions" in stub.paths("POST"), "creates a new version instead")


def test_limits_are_enforced_before_any_call() -> None:
    print("\nfield limits")
    root = metadata_root()
    (root / "metadata" / "en-US" / "keywords.txt").write_text("x" * 200)
    try:
        asc.read_metadata(root)
        check(False, "rejects over-length keywords")
    except SystemExit:
        check(True, "rejects over-length keywords")


def main() -> None:
    for test in [
        test_missing_review_detail_does_not_abort,
        test_existing_review_detail_is_patched,
        test_app_info_localization_is_created_when_absent,
        test_whats_new_omitted_on_debut_version,
        test_whats_new_included_on_later_version,
        test_live_app_info_is_never_selected,
        test_build_query_requires_a_processed_build,
        test_missing_review_notes_is_announced,
        test_manual_steps_always_print,
        test_editable_draft_is_renamed_not_duplicated,
        test_submitted_version_is_never_renamed,
        test_limits_are_enforced_before_any_call,
    ]:
        test()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s):")
        for failure in FAILURES:
            print(f"  - {failure}")
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
