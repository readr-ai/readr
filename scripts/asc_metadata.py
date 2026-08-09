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

What this CANNOT do: the **App Privacy questionnaire** and the **age-rating
questionnaire** have no public API and must be answered once by hand in the
web UI. Screenshots DO have an API — an earlier revision of this file claimed
otherwise and was wrong; see `upload_screenshots`.

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
    # Apple rejects tokens expiring MORE than 20 minutes out, so sitting
    # exactly on the boundary makes any runner clock skew ahead of Apple's
    # produce a 401 that reads as "credentials are missing or invalid".
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"},
        p8,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(
    method: str,
    path: str,
    body: dict | None = None,
    bearer: str = "",
    allow_missing: bool = False,
) -> dict:
    """One ASC API call.

    `allow_missing` turns a 404 into an empty result instead of a hard exit.
    Singular relationships — `appStoreReviewDetail` above all — 404 when the
    resource has not been created yet, which is the *normal* state for a fresh
    version. Treating that as fatal aborted `push` on its first run for every
    new version, which is exactly when it needs to work.
    """
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
        if error.code == 404 and allow_missing:
            return {}
        detail = error.read().decode(errors="replace")
        # Apple's errors are specific and worth surfacing verbatim — they name
        # the offending attribute, which guessing from a status code would not.
        # The bearer token is never echoed here: it rides in a request header,
        # and Apple's error bodies describe the request, not its credentials.
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


def has_prior_version(bearer: str, app_id: str, version: str) -> bool:
    """Whether any App Store version other than this one exists.

    Decides the `whatsNew` question: a debut listing has no previous release
    to describe changes from, and Apple rejects the field outright.
    """
    query = urllib.parse.urlencode({"filter[platform]": PLATFORM, "limit": "50"})
    versions = call(
        "GET", f"/apps/{app_id}/appStoreVersions?{query}", bearer=bearer
    )["data"]
    return any(v["attributes"].get("versionString") != version for v in versions)


def find_app(bearer: str) -> dict:
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID})
    apps = call("GET", f"/apps?{query}", bearer=bearer)["data"]
    if not apps:
        die(f"no app with bundle id {BUNDLE_ID} on this account")
    return apps[0]


# The only version state safe to rename. Anything submitted, in review, or
# live must be left alone.
EDITABLE_STATE = "PREPARE_FOR_SUBMISSION"


def editable_draft(bearer: str, app_id: str) -> dict | None:
    """An existing unsubmitted version record, if there is one."""
    query = urllib.parse.urlencode({"filter[platform]": PLATFORM, "limit": "20"})
    versions = call(
        "GET", f"/apps/{app_id}/appStoreVersions?{query}", bearer=bearer
    )["data"]
    for existing in versions:
        attrs = existing["attributes"]
        state = attrs.get("appVersionState") or attrs.get("appStoreState")
        if state == EDITABLE_STATE:
            return existing
    return None


def report_app_state(bearer: str, app_id: str) -> None:
    """What state the app record and its versions are actually in.

    Apple refuses to create a version with a bare "You cannot create a new
    version of the App in the current state", naming no cause. This prints the
    facts that usually explain it, so `plan` diagnoses instead of leaving a
    409 to be guessed at.
    """
    infos = call("GET", f"/apps/{app_id}/appInfos", bearer=bearer)["data"]
    for info in infos:
        attrs = info["attributes"]
        state = attrs.get("state") or attrs.get("appStoreState") or "unknown"
        print(f"  appInfo {info['id']}: state={state}")

    query = urllib.parse.urlencode({"limit": "10"})
    versions = call(
        "GET", f"/apps/{app_id}/appStoreVersions?{query}", bearer=bearer
    )["data"]
    if not versions:
        print("  no App Store version records exist at all")
    for existing in versions:
        attrs = existing["attributes"]
        state = attrs.get("appVersionState") or attrs.get("appStoreState") or "unknown"
        print(
            f"  version {attrs.get('versionString')} "
            f"({attrs.get('platform')}): state={state}"
        )


def find_or_create_version(bearer: str, app_id: str, version: str, write: bool) -> dict:
    query = urllib.parse.urlencode(
        {"filter[versionString]": version, "filter[platform]": PLATFORM}
    )
    found = call("GET", f"/apps/{app_id}/appStoreVersions?{query}", bearer=bearer)["data"]
    if found:
        return found[0]

    # Apple allows exactly ONE editable version at a time, so POSTing a new one
    # while another sits in PREPARE_FOR_SUBMISSION fails with a 409 that names
    # no cause: "You cannot create a new version of the App in the current
    # state." Readr's record had an empty 1.0 placeholder doing precisely that.
    #
    # Retargeting it is what you would do by hand in the web UI — rename the
    # unsubmitted draft rather than make a second one. Only PREPARE_FOR_
    # SUBMISSION qualifies: a submitted or live version must never be renamed
    # out from under a review.
    editable = editable_draft(bearer, app_id)
    if editable:
        current = editable["attributes"].get("versionString")
        if not write:
            print(
                f"  version {version} does not exist, but draft {current} is "
                f"editable — would rename it to {version}"
            )
            return {}
        print(f"  renaming editable draft {current} → {version}")
        return call(
            "PATCH", f"/appStoreVersions/{editable['id']}",
            {"data": {"type": "appStoreVersions", "id": editable["id"],
                      "attributes": {"versionString": version,
                                     "releaseType": "MANUAL"}}},
            bearer=bearer,
        )["data"]

    if not write:
        print(f"  version {version} does not exist yet (would be created)")
        return {}
    print(
        "  creating the version record…\n"
        "  (if this 409s with \"cannot create a new version in the current\n"
        "   state\", the app record is not submission-ready yet — see the\n"
        "   manual steps printed below; App Privacy and the agreements have to\n"
        "   be completed in the web UI before ANY version can be created,\n"
        "   by API or otherwise)"
    )
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
            "filter[preReleaseVersion.platform]": PLATFORM,
            # Only a processed build can be attached. Without this the script
            # happily picks one still PROCESSING moments after a tag upload,
            # and Apple rejects the attach mid-run.
            "filter[processingState]": "VALID",
            "sort": "-uploadedDate",
            "limit": "1",
        }
    )
    builds = call("GET", f"/builds?{query}", bearer=bearer)["data"]
    return builds[0] if builds else None


def push(
    bearer: str, app: dict, version_id: str, fields: dict, write: bool,
    root: Path, first_version: bool,
) -> None:
    app_id = app["id"]

    # Version-level copy: description, keywords, what's new, promo, URLs.
    localizations = call(
        "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        bearer=bearer,
    )["data"]
    target = next((l for l in localizations if l["attributes"].get("locale") == LOCALE), None)
    attributes = {
        "description": fields.get("description"),
        "keywords": fields.get("keywords"),
        "promotionalText": fields.get("promotional_text"),
        "whatsNew": fields.get("release_notes"),
        "supportUrl": fields.get("support_url"),
        "marketingUrl": fields.get("marketing_url"),
    }
    attributes = {k: v for k, v in attributes.items() if v}
    # "What's New" describes a change from a previous version, so Apple
    # rejects it on an app's first one — and because every field ships in a
    # single PATCH, that rejection would take the description, keywords and
    # URLs down with it and leave the listing empty.
    if first_version and "whatsNew" in attributes:
        del attributes["whatsNew"]
        print("  (skipping whatsNew — Apple rejects it on a debut version)")
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

    # Apple refuses a submission without this:
    #   ENTITY_ERROR.ATTRIBUTE.REQUIRED — 'contentRightsDeclaration'
    # Readr bundles and downloads no content; it opens only DRM-free files the
    # user already has, and refuses DRM-protected ones. So it does not use
    # third-party content, and saying so is the accurate answer rather than the
    # convenient one.
    rights = fields.get("content_rights") or "DOES_NOT_USE_THIRD_PARTY_CONTENT"
    print(f"  content rights: {rights}")
    if write:
        # On the APP, not the version. Apple's submit error named the
        # attribute but not its resource, and the obvious guess was wrong:
        #   'contentRightsDeclaration' is not an attribute on the resource
        #   'appStoreVersions'
        # It is app-wide — whether the app uses third-party content at all —
        # so it does not belong to a single version.
        call(
            "PATCH", f"/apps/{app_id}",
            {"data": {"type": "apps", "id": app_id,
                      "attributes": {"contentRightsDeclaration": rights}}},
            bearer=bearer,
        )

    # App-level copy: name, subtitle, privacy policy. Lives on appInfo, not on
    # the version — it is not version-specific.
    infos = call("GET", f"/apps/{app_id}/appInfos", bearer=bearer)["data"]
    # `appStoreState` is deprecated in favour of `state`; prefer the new name.
    # Fail CLOSED when neither is present: the old `.get()` returned None,
    # which is not in the live-states tuple, so the guard inverted and would
    # have selected the shipped listing the day Apple drops the attribute.
    live = ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
    def editable_info(info: dict) -> bool:
        attrs = info["attributes"]
        state = attrs.get("state") or attrs.get("appStoreState")
        return state is not None and state not in live
    editable = next((i for i in infos if editable_info(i)), None)
    if editable:
        # Categories are a *relationship* on appInfo, not an attribute, and
        # Apple refuses a submission without a primary one:
        #   ENTITY_ERROR.RELATIONSHIP.REQUIRED — 'primaryCategory'
        # It is not part of the localized copy, so it is set once here rather
        # than per locale. Ids are the documented appCategories ids.
        categories = {}
        if fields.get("primary_category"):
            categories["primaryCategory"] = {
                "data": {"type": "appCategories", "id": fields["primary_category"]}
            }
        if fields.get("secondary_category"):
            categories["secondaryCategory"] = {
                "data": {"type": "appCategories", "id": fields["secondary_category"]}
            }
        if categories:
            names = ", ".join(f"{k}={v['data']['id']}" for k, v in sorted(categories.items()))
            print(f"  categories: {names}")
            if write:
                call(
                    "PATCH", f"/appInfos/{editable['id']}",
                    {"data": {"type": "appInfos", "id": editable["id"],
                              "relationships": categories}},
                    bearer=bearer,
                )
        info_locs = call(
            "GET", f"/appInfos/{editable['id']}/appInfoLocalizations", bearer=bearer
        )["data"]
        info_target = next(
            (l for l in info_locs if l["attributes"].get("locale") == LOCALE), None
        )
        info_attributes = {
            "name": fields.get("name"),
            "subtitle": fields.get("subtitle"),
            "privacyPolicyUrl": fields.get("privacy_url"),
        }
        info_attributes = {k: v for k, v in info_attributes.items() if v}
        if write:
            if info_target:
                call(
                    "PATCH", f"/appInfoLocalizations/{info_target['id']}",
                    {"data": {"type": "appInfoLocalizations",
                              "id": info_target["id"],
                              "attributes": info_attributes}},
                    bearer=bearer,
                )
            else:
                # A locale with no existing localization needs creating, not
                # skipping — the previous version printed success and made no
                # call at all.
                call(
                    "POST", "/appInfoLocalizations",
                    {"data": {"type": "appInfoLocalizations",
                              "attributes": {**info_attributes, "locale": LOCALE},
                              "relationships": {"appInfo": {
                                  "data": {"type": "appInfos",
                                           "id": editable["id"]}}}}},
                    bearer=bearer,
                )
        print(f"  app info ({LOCALE}): {', '.join(sorted(info_attributes))}")

    # Reviewer notes — the field that preempts a BYO-credential rejection.
    notes_file = root / "review_notes.txt"
    if not notes_file.exists():
        print(f"  review details: no {notes_file} — skipping")
    else:
        notes = notes_file.read_text().rstrip("\n")
        print(f"  review details: notes ({len(notes)} chars)")
        if write:
            existing = call(
                "GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail",
                bearer=bearer, allow_missing=True,
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


# Apple's display types, and the directory each is sourced from. The first
# submit attempt failed with SCREENSHOT_REQUIRED for exactly these two, which
# is how we learned they are mandatory for this app.
SCREENSHOT_SETS = {
    "APP_IPHONE_65": "iphone-6.5",
    "APP_IPAD_PRO_3GEN_129": "ipad-12.9",
}


def upload_screenshots(bearer: str, version_id: str, root: Path, write: bool) -> None:
    """Create each required screenshot set and upload its images.

    Contrary to what this script said for several revisions, screenshots ARE
    covered by the API. It is a three-step dance per image rather than a plain
    POST, which is presumably why it reads as unsupported: reserve (Apple
    returns pre-signed upload operations), PUT the bytes, then PATCH
    `uploaded: true` with an MD5 of the file so Apple can verify it landed
    intact.
    """
    import hashlib

    existing_sets = call(
        "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        bearer=bearer,
    )["data"]
    localization = next(
        (l for l in existing_sets if l["attributes"].get("locale") == LOCALE), None
    )
    if not localization:
        print("  screenshots: no en-US localization yet — skipping")
        return

    for display_type, folder in SCREENSHOT_SETS.items():
        directory = root / "screenshots" / folder
        images = sorted(directory.glob("*.png"))
        if not images:
            print(f"  screenshots: nothing in {directory} for {display_type}")
            continue
        print(f"  screenshots {display_type}: {len(images)} from {folder}")
        if not write:
            continue

        sets = call(
            "GET",
            f"/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets",
            bearer=bearer,
        )["data"]
        target = next(
            (s for s in sets
             if s["attributes"].get("screenshotDisplayType") == display_type),
            None,
        )
        if target is None:
            target = call(
                "POST", "/appScreenshotSets",
                {"data": {"type": "appScreenshotSets",
                          "attributes": {"screenshotDisplayType": display_type},
                          "relationships": {"appStoreVersionLocalization": {
                              "data": {"type": "appStoreVersionLocalizations",
                                       "id": localization["id"]}}}}},
                bearer=bearer,
            )["data"]

        # Re-uploading into a populated set duplicates images, so only fill it
        # when empty. Delete in ASC to re-do a set.
        already = call(
            "GET", f"/appScreenshotSets/{target['id']}/appScreenshots", bearer=bearer
        )["data"]
        if already:
            print(f"    already has {len(already)} — leaving alone")
            continue

        for image in images:
            payload = image.read_bytes()
            reserved = call(
                "POST", "/appScreenshots",
                {"data": {"type": "appScreenshots",
                          "attributes": {"fileSize": len(payload),
                                         "fileName": image.name},
                          "relationships": {"appScreenshotSet": {
                              "data": {"type": "appScreenshotSets",
                                       "id": target["id"]}}}}},
                bearer=bearer,
            )["data"]

            for operation in reserved["attributes"]["uploadOperations"]:
                request = urllib.request.Request(
                    operation["url"], data=payload, method=operation["method"]
                )
                for header in operation.get("requestHeaders", []):
                    request.add_header(header["name"], header["value"])
                try:
                    urllib.request.urlopen(request).read()
                except urllib.error.HTTPError as error:
                    die(f"screenshot upload failed for {image.name}: {error.code}")

            call(
                "PATCH", f"/appScreenshots/{reserved['id']}",
                {"data": {"type": "appScreenshots", "id": reserved["id"],
                          "attributes": {
                              "uploaded": True,
                              "sourceFileChecksum": hashlib.md5(payload).hexdigest()}}},
                bearer=bearer,
            )
            print(f"    uploaded {image.name}")


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


def set_pricing(bearer: str, app_id: str, write: bool) -> None:
    """Put the app on the free tier.

    Surfaced by a submit attempt, not by any checklist:
      STATE_ERROR.APP_PRICING_REQUIRED — "App is not eligible for submission
      until pricing has been set."

    Readr sells nothing and has no in-app purchases, so this is the free price
    point in the base territory. An app with no price schedule at all is not
    "free" to Apple — it is unpriced, which blocks submission.
    """
    existing = call(
        "GET", f"/apps/{app_id}/appPriceSchedule", bearer=bearer, allow_missing=True
    ).get("data")
    if existing:
        print(f"  pricing: already scheduled ({existing['id']})")
        return

    # The free price point for the base territory.
    query = urllib.parse.urlencode(
        {"filter[territory]": "USA", "include": "territory", "limit": "200"}
    )
    points = call(
        "GET", f"/apps/{app_id}/appPricePoints?{query}", bearer=bearer,
        allow_missing=True,
    ).get("data", [])
    free = next(
        (p for p in points
         if str(p["attributes"].get("customerPrice", "")) in ("0", "0.00", "0.0")),
        None,
    )
    if not free:
        print(f"  pricing: no zero price point among {len(points)} — set it in the web UI")
        return

    print(f"  pricing: free tier ({free['id']})")
    if write:
        call(
            "POST", "/appPriceSchedules",
            {"data": {"type": "appPriceSchedules",
                      "relationships": {
                          "app": {"data": {"type": "apps", "id": app_id}},
                          "baseTerritory": {
                              "data": {"type": "territories", "id": "USA"}},
                          "manualPrices": {
                              "data": [{"type": "appPrices", "id": "${price}"}]}}},
             "included": [{"type": "appPrices", "id": "${price}",
                           "relationships": {
                               "appPricePoint": {
                                   "data": {"type": "appPricePoints",
                                            "id": free["id"]}}}}]},
            bearer=bearer,
        )


def set_age_rating(
    bearer: str, app_info_id: str, version_id: str, root: Path, write: bool
) -> None:
    """Answer the age-rating questionnaire.

    This file twice declared age rating "manual, no API" — and Apple then
    refused a submission naming one of its attributes outright:

      ENTITY_ERROR.ATTRIBUTE.REQUIRED — 'violenceCartoonOrFantasy'

    Apple asking for it by name meant it was reachable; the earlier GET simply
    looked in the wrong place. The declaration hangs off `appInfo`, not the
    version, which is why querying the version returned nothing and the wrong
    conclusion stuck. Answers live in `appstore/age_rating.json` so they are
    reviewable rather than buried in code.
    """
    answers_file = root / "age_rating.json"
    if not answers_file.exists():
        print(f"  age rating: no {answers_file} — skipping")
        return
    answers = {
        k: v for k, v in json.loads(answers_file.read_text()).items()
        if not k.startswith("_")
    }

    # The declaration lives on appInfo; the version relationship is the one
    # that returns nothing. Try both rather than assume again.
    declaration = call(
        "GET", f"/appInfos/{app_info_id}/ageRatingDeclaration",
        bearer=bearer, allow_missing=True,
    ).get("data")
    if not declaration:
        declaration = call(
            "GET", f"/appStoreVersions/{version_id}/ageRatingDeclaration",
            bearer=bearer, allow_missing=True,
        ).get("data")
    if not declaration:
        print("  age rating: no declaration on appInfo or version — "
              "answer it in the web UI")
        return

    print(f"  age rating: {len(answers)} answers -> {declaration['id']}")
    if write:
        call(
            "PATCH", f"/ageRatingDeclarations/{declaration['id']}",
            {"data": {"type": "ageRatingDeclarations",
                      "id": declaration["id"], "attributes": answers}},
            bearer=bearer,
        )


def report_age_rating(bearer: str, version_id: str) -> None:
    """Print the version's age-rating declaration, if the API exposes one.

    Read-only. This exists because the script twice asserted something was
    "manual, no API" and was wrong once already (screenshots). Asking the API
    what it actually returns beats reasoning about it.
    """
    found = call(
        "GET", f"/appStoreVersions/{version_id}/ageRatingDeclaration",
        bearer=bearer, allow_missing=True,
    ).get("data")
    if not found:
        print("  age rating: no declaration exposed on this version")
        return
    attributes = found.get("attributes", {})
    unanswered = [k for k, v in attributes.items() if v is None]
    answered = {k: v for k, v in attributes.items() if v is not None}
    print(f"  age rating declaration {found['id']}: "
          f"{len(answered)} answered, {len(unanswered)} unanswered")
    if answered:
        for key, value in sorted(answered.items())[:8]:
            print(f"      {key} = {value}")
    if unanswered:
        print(f"      unanswered: {', '.join(sorted(unanswered)[:12])}")


def manual_steps() -> None:
    """No public API covers these. Printed on EVERY run — including the
    early-return plan path, which is the first-run case where the gap matters
    most — so a green tick never reads as "the listing is complete"."""
    print(
        "\nNOT handled by any API — do this once in the ASC web UI:\n"
        "  * App Privacy questionnaire (answer: Data Not Collected)\n"
        "  * Age rating questionnaire"
    )


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

    report_app_state(bearer, app["id"])
    version = find_or_create_version(bearer, app["id"], args.version, write)
    if not version:
        print("\nplan only — nothing further to inspect without creating the version")
        manual_steps()
        return
    if fields.get("copyright") and write:
        # Required at submission time — the first submit attempt failed with
        # ENTITY_ERROR.ATTRIBUTE.REQUIRED for exactly this. It lives on the
        # version, not the localization, which is why it was missed.
        call(
            "PATCH", f"/appStoreVersions/{version['id']}",
            {"data": {"type": "appStoreVersions", "id": version["id"],
                      "attributes": {"copyright": fields["copyright"]}}},
            bearer=bearer,
        )
        print(f"  copyright: {fields['copyright']}")
    state = version["attributes"].get("appStoreState")
    print(f"version {args.version}: {version['id']} state={state}")

    first_version = not has_prior_version(bearer, app["id"], args.version)
    if first_version:
        print("  this is the app's first App Store version")
    push(
        bearer, app, version["id"], fields, write,
        root=args.root, first_version=first_version,
    )

    # The editable appInfo owns the age-rating declaration.
    infos = call("GET", f"/apps/{app['id']}/appInfos", bearer=bearer)["data"]
    live_states = ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
    app_info = next(
        (i for i in infos
         if (i["attributes"].get("state") or i["attributes"].get("appStoreState"))
         not in live_states),
        None,
    )
    set_pricing(bearer, app["id"], write)
    if app_info:
        set_age_rating(bearer, app_info["id"], version["id"], args.root, write)
    report_age_rating(bearer, version["id"])
    upload_screenshots(bearer, version["id"], args.root, write)

    build = latest_build(bearer, app["id"], args.version)
    if build:
        attach_build(bearer, version["id"], build, write)
    else:
        print(f"  no processed build for {args.version} yet "
              "(Apple takes a few minutes after upload)")

    manual_steps()

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
