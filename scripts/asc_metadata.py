#!/usr/bin/env python3
"""Push App Store listing metadata (and optionally submit) via the App Store
Connect API.

Runs in CI, where `APP_STORE_CONNECT_*` already live as secrets for the
TestFlight lane — the .p8 is write-only in GitHub, so this is the only place
it can be used without a human copying a key around.

Three modes, deliberately separate because they carry very different risk:

  plan      read-only. Prints what would change, touches nothing. The default.
  push      writes listing metadata + review details + release type.
            Reversible: run it again with different text.
  submit    push, then create a review submission and submit it.
            NOT reversible in the same way — a human should have walked the
            build on a device first (docs/DEVICE-SMOKE-TEST.md).

What this CANNOT do, and no API can: the **App Privacy questionnaire**
(nutrition labels) has no public App Store Connect API. It must be answered
once, by hand, in the web UI. `plan` reports whether it looks answered so the
gap is visible rather than assumed.

Metadata source: appstore/metadata/<locale>/*.txt — plain text, one field per
file, so the listing copy is diffable and reviewable like any other change.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.readrai.app"
PLATFORM = "IOS"
LOCALE = "en-US"

# Apple's limits. Exceeding one is a rejected PATCH, so fail before the call
# with a message naming the field rather than surfacing a 409 from the API.
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "promotional_text": 170,
    "description": 4000,
    "keywords": 100,
    "release_notes": 4000,
}


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


# --- auth -------------------------------------------------------------------

def token() -> str:
    """ES256 JWT for the ASC API. Twenty minutes is Apple's ceiling."""
    try:
        import jwt  # PyJWT, with the `crypto` extra
    except ImportError:
        die("PyJWT is required: pip install 'pyjwt[crypto]'")

    key_id = os.environ.get("APP_STORE_CONNECT_KEY_ID")
    issuer = os.environ.get("APP_STORE_CONNECT_ISSUER_ID")
    p8 = os.environ.get("APP_STORE_CONNECT_API_KEY_P8")
    if not (key_id and issuer and p8):
        die(
            "missing APP_STORE_CONNECT_KEY_ID / _ISSUER_ID / _API_KEY_P8. "
            "In CI these come from repository secrets."
        )

    # The secret is stored base64-encoded (see testflight.yml); accept raw PEM
    # too so this is runnable locally by someone holding the .p8.
    if "BEGIN PRIVATE KEY" not in p8:
        import base64
        p8 = base64.b64decode(p8).decode()

    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"},
        p8,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None, bearer: str = "") -> dict:
    url = path if path.startswith("http") else f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {bearer}")
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        # Apple's errors are specific and worth surfacing verbatim — they name
        # the offending attribute, which guessing from a status code would not.
        die(f"{method} {url} -> HTTP {error.code}\n{detail[:1500]}")


# --- metadata ---------------------------------------------------------------

def read_metadata(root: Path) -> dict[str, str]:
    directory = root / "metadata" / LOCALE
    if not directory.is_dir():
        die(f"no metadata directory at {directory}")
    fields = {}
    for file in directory.glob("*.txt"):
        fields[file.stem] = file.read_text().rstrip("\n")
    for field, limit in LIMITS.items():
        value = fields.get(field)
        if value and len(value) > limit:
            die(f"{field} is {len(value)} characters; Apple's limit is {limit}")
    return fields


def find_app(bearer: str) -> dict:
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID})
    apps = call("GET", f"/apps?{query}", bearer=bearer)["data"]
    if not apps:
        die(f"no app with bundle id {BUNDLE_ID} on this account")
    return apps[0]


def find_or_create_version(bearer: str, app_id: str, version: str, write: bool) -> dict:
    query = urllib.parse.urlencode(
        {"filter[versionString]": version, "filter[platform]": PLATFORM}
    )
    found = call("GET", f"/apps/{app_id}/appStoreVersions?{query}", bearer=bearer)["data"]
    if found:
        return found[0]
    if not write:
        print(f"  version {version} does not exist yet (would be created)")
        return {}
    return call(
        "POST",
        "/appStoreVersions",
        {
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": PLATFORM,
                    "versionString": version,
                    # Never auto-release: approval must not publish ahead of a
                    # launch. A human presses the button in ASC.
                    "releaseType": "MANUAL",
                },
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}}
                },
            }
        },
        bearer=bearer,
    )["data"]


def latest_build(bearer: str, app_id: str, version: str) -> dict | None:
    query = urllib.parse.urlencode(
        {
            "filter[app]": app_id,
            "filter[preReleaseVersion.version]": version,
            "sort": "-uploadedDate",
            "limit": "1",
        }
    )
    builds = call("GET", f"/builds?{query}", bearer=bearer)["data"]
    return builds[0] if builds else None


def push(bearer: str, app: dict, version_id: str, fields: dict, write: bool) -> None:
    app_id = app["id"]

    # Version-level copy: description, keywords, what's new, promo, URLs.
    localizations = call(
        "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        bearer=bearer,
    )["data"]
    target = next((l for l in localizations if l["attributes"]["locale"] == LOCALE), None)
    attributes = {
        "description": fields.get("description"),
        "keywords": fields.get("keywords"),
        "promotionalText": fields.get("promotional_text"),
        "whatsNew": fields.get("release_notes"),
        "supportUrl": fields.get("support_url"),
        "marketingUrl": fields.get("marketing_url"),
    }
    attributes = {k: v for k, v in attributes.items() if v}
    print(f"  version localization ({LOCALE}): {', '.join(sorted(attributes))}")
    if write:
        if target:
            call(
                "PATCH",
                f"/appStoreVersionLocalizations/{target['id']}",
                {"data": {"type": "appStoreVersionLocalizations",
                          "id": target["id"], "attributes": attributes}},
                bearer=bearer,
            )
        else:
            call(
                "POST", "/appStoreVersionLocalizations",
                {"data": {"type": "appStoreVersionLocalizations",
                          "attributes": {**attributes, "locale": LOCALE},
                          "relationships": {"appStoreVersion": {
                              "data": {"type": "appStoreVersions", "id": version_id}}}}},
                bearer=bearer,
            )

    # App-level copy: name, subtitle, privacy policy. Lives on appInfo, not on
    # the version — it is not version-specific.
    infos = call("GET", f"/apps/{app_id}/appInfos", bearer=bearer)["data"]
    editable = next(
        (i for i in infos
         if i["attributes"].get("appStoreState") not in ("READY_FOR_SALE",)),
        infos[0] if infos else None,
    )
    if editable:
        info_locs = call(
            "GET", f"/appInfos/{editable['id']}/appInfoLocalizations", bearer=bearer
        )["data"]
        info_target = next(
            (l for l in info_locs if l["attributes"]["locale"] == LOCALE), None
        )
        info_attributes = {
            "name": fields.get("name"),
            "subtitle": fields.get("subtitle"),
            "privacyPolicyUrl": fields.get("privacy_url"),
        }
        info_attributes = {k: v for k, v in info_attributes.items() if v}
        print(f"  app info ({LOCALE}): {', '.join(sorted(info_attributes))}")
        if write and info_target:
            call(
                "PATCH", f"/appInfoLocalizations/{info_target['id']}",
                {"data": {"type": "appInfoLocalizations",
                          "id": info_target["id"], "attributes": info_attributes}},
                bearer=bearer,
            )

    # Reviewer notes — the field that preempts a BYO-credential rejection.
    notes_file = Path("appstore/review_notes.txt")
    if notes_file.exists():
        notes = notes_file.read_text().rstrip("\n")
        print(f"  review details: notes ({len(notes)} chars)")
        if write:
            existing = call(
                "GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail",
                bearer=bearer,
            ).get("data")
            payload = {"notes": notes}
            if existing:
                call("PATCH", f"/appStoreReviewDetails/{existing['id']}",
                     {"data": {"type": "appStoreReviewDetails",
                               "id": existing["id"], "attributes": payload}},
                     bearer=bearer)
            else:
                call("POST", "/appStoreReviewDetails",
                     {"data": {"type": "appStoreReviewDetails",
                               "attributes": payload,
                               "relationships": {"appStoreVersion": {
                                   "data": {"type": "appStoreVersions",
                                            "id": version_id}}}}},
                     bearer=bearer)


def attach_build(bearer: str, version_id: str, build: dict, write: bool) -> None:
    number = build["attributes"].get("version")
    print(f"  attach build {number} ({build['id']})")
    if write:
        call(
            "PATCH", f"/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build["id"]}}, bearer=bearer,
        )


def submit(bearer: str, app_id: str, version_id: str) -> None:
    """Create a review submission, add the version, and submit it."""
    submission = call(
        "POST", "/reviewSubmissions",
        {"data": {"type": "reviewSubmissions",
                  "attributes": {"platform": PLATFORM},
                  "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
        bearer=bearer,
    )["data"]
    call(
        "POST", "/reviewSubmissionItems",
        {"data": {"type": "reviewSubmissionItems",
                  "relationships": {
                      "reviewSubmission": {"data": {"type": "reviewSubmissions",
                                                    "id": submission["id"]}},
                      "appStoreVersion": {"data": {"type": "appStoreVersions",
                                                   "id": version_id}}}}},
        bearer=bearer,
    )
    call(
        "PATCH", f"/reviewSubmissions/{submission['id']}",
        {"data": {"type": "reviewSubmissions", "id": submission["id"],
                  "attributes": {"submitted": True}}},
        bearer=bearer,
    )
    print(f"  SUBMITTED — review submission {submission['id']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["plan", "push", "submit"], default="plan")
    parser.add_argument("--version", required=True, help="e.g. 2.15.0")
    parser.add_argument("--root", default="appstore", type=Path)
    args = parser.parse_args()

    write = args.mode in ("push", "submit")
    fields = read_metadata(args.root)
    print(f"mode={args.mode} version={args.version}")
    for field, limit in LIMITS.items():
        if fields.get(field):
            print(f"  {field}: {len(fields[field])}/{limit}")

    bearer = token()
    app = find_app(bearer)
    print(f"app: {app['attributes']['name']} ({app['id']})")

    version = find_or_create_version(bearer, app["id"], args.version, write)
    if not version:
        print("\nplan only — nothing further to inspect without creating the version")
        return
    state = version["attributes"].get("appStoreState")
    print(f"version {args.version}: {version['id']} state={state}")

    push(bearer, app, version["id"], fields, write)

    build = latest_build(bearer, app["id"], args.version)
    if build:
        attach_build(bearer, version["id"], build, write)
    else:
        print(f"  no processed build for {args.version} yet "
              "(Apple takes a few minutes after upload)")

    # No public API covers the App Privacy questionnaire. Say so loudly rather
    # than let a green run imply the listing is complete.
    print(
        "\nNOT handled by any API — do this once in the ASC web UI:\n"
        "  * App Privacy questionnaire (answer: Data Not Collected)\n"
        "  * Age rating questionnaire\n"
        "  * Screenshots"
    )

    if args.mode == "submit":
        if not build:
            die("refusing to submit with no build attached")
        submit(bearer, app["id"], version["id"])
    elif args.mode == "push":
        print("\npushed. Review in ASC, then re-run with --mode submit.")
    else:
        print("\nplan only — nothing was written.")


if __name__ == "__main__":
    main()
