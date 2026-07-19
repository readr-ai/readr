#!/usr/bin/env python3
"""One-shot TestFlight external-beta setup via the App Store Connect API.

Configures everything the TestFlight plan's ASC steps require, idempotently:

  1. Test Information (beta app description + feedback email, en-US).
  2. A "Public Beta" external group with the public link enabled.
  3. The requested build attached to that group.
  4. The build submitted to Beta App Review (skipped gracefully when the
     build is already in/past review).

It deliberately does NOT touch Beta App Review contact details
(betaAppReviewDetails) — those are maintained by hand in ASC.

Auth comes from the same App Store Connect API key the TestFlight upload
workflow uses (env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64). The key
never leaves the environment; API error bodies are printed verbatim but
contain no credentials.
"""

import argparse
import base64
import os
import sys
import time

import jwt  # PyJWT
import requests

API = "https://api.appstoreconnect.apple.com"

BETA_DESCRIPTION = """Readr is a native ebook reader for DRM-free EPUB, PDF, and text/Markdown files — with an AI twist: select any passage and ask the book a question, and the answer streams in with citations grounded in the whole book. Your highlights and notes can be composed into an editable Markdown article. Bring your own AI: paste an Anthropic or OpenAI API key in Settings → AI Providers (the app links you to the key consoles). No account, no telemetry — books and notes stay on your device and keys live in the Keychain.

What to test: import an EPUB or PDF (Files app or the in-app importer), read in the paged layouts, make highlights, open the Notes panel, and — with your own API key — ask the book a question and compose an article from your highlights. We'd love feedback on iPad split-view and rotation."""


def token() -> str:
    key = base64.b64decode(os.environ["ASC_KEY_P8_BASE64"]).decode()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 19 * 60,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]},
    )


def api(method: str, path: str, *, params=None, body=None, ok=(200, 201, 204),
        tolerate=()):
    """Call the ASC API. Exits non-zero on unexpected status; returns the
    parsed JSON (or None for 204). `tolerate` lists extra statuses to accept,
    returning the error body instead of failing — used for idempotent re-runs
    (409 duplicate submission etc.)."""
    resp = requests.request(
        method, API + path, params=params, json=body,
        headers={"Authorization": f"Bearer {token()}"}, timeout=60,
    )
    if resp.status_code not in ok and resp.status_code not in tolerate:
        print(f"::error::{method} {path} -> HTTP {resp.status_code}")
        print(resp.text)
        sys.exit(1)
    if resp.status_code == 204 or not resp.text:
        return None
    try:
        payload = resp.json()
    except ValueError:
        return {"_status": resp.status_code}
    payload["_status"] = resp.status_code
    return payload


def find_app(bundle_id: str) -> str:
    data = api("GET", "/v1/apps", params={"filter[bundleId]": bundle_id})["data"]
    if not data:
        print(f"::error::No app found for bundle id {bundle_id}")
        sys.exit(1)
    return data[0]["id"]


def set_test_information(app_id: str, feedback_email: str) -> None:
    locs = api("GET", f"/v1/apps/{app_id}/betaAppLocalizations")["data"]
    attrs = {"description": BETA_DESCRIPTION, "feedbackEmail": feedback_email,
             "marketingUrl": "https://readr-ai.github.io/readr/",
             "privacyPolicyUrl": "https://readr-ai.github.io/readr/privacy.html"}
    en = next((l for l in locs if l["attributes"]["locale"] == "en-US"), None)
    if en:
        api("PATCH", f"/v1/betaAppLocalizations/{en['id']}",
            body={"data": {"type": "betaAppLocalizations", "id": en["id"],
                           "attributes": attrs}})
        print("Test information: updated en-US localization.")
    else:
        api("POST", "/v1/betaAppLocalizations",
            body={"data": {"type": "betaAppLocalizations",
                           "attributes": {"locale": "en-US", **attrs},
                           "relationships": {"app": {"data": {
                               "type": "apps", "id": app_id}}}}})
        print("Test information: created en-US localization.")


def wait_for_build(app_id: str, version: str, timeout_s: int = 1800) -> dict:
    """Newest build of `version` (e.g. 2.10.0), waiting out PROCESSING."""
    deadline = time.time() + timeout_s
    while True:
        pre = api("GET", "/v1/preReleaseVersions",
                  params={"filter[app]": app_id, "filter[version]": version,
                          "filter[platform]": "IOS"})["data"]
        builds = []
        if pre:
            builds = api("GET", "/v1/builds",
                         params={"filter[preReleaseVersion]": pre[0]["id"],
                                 "sort": "-uploadedDate", "limit": 1})["data"]
        if builds:
            state = builds[0]["attributes"]["processingState"]
            if state == "VALID":
                print(f"Build {builds[0]['attributes']['version']} "
                      f"({version}) is processed and VALID.")
                return builds[0]
            if state in ("FAILED", "INVALID"):
                print(f"::error::Build processing ended in {state}. Check "
                      "App Store Connect for the processing report.")
                sys.exit(1)
            print(f"Build state: {state}; waiting…")
        else:
            print(f"No build for {version} visible yet; waiting…")
        if time.time() > deadline:
            print("::error::Timed out waiting for a VALID build.")
            sys.exit(1)
        time.sleep(30)


def ensure_group(app_id: str, name: str) -> dict:
    groups = api("GET", "/v1/betaGroups",
                 params={"filter[app]": app_id, "filter[name]": name})["data"]
    if groups:
        group = groups[0]
        if not group["attributes"].get("publicLinkEnabled"):
            group = api("PATCH", f"/v1/betaGroups/{group['id']}",
                        body={"data": {"type": "betaGroups", "id": group["id"],
                                       "attributes": {"publicLinkEnabled": True,
                                                      "publicLinkLimitEnabled": False}}})["data"]
            print(f'Group "{name}": existed; enabled the public link.')
        else:
            print(f'Group "{name}": already exists with public link enabled.')
        return group
    group = api("POST", "/v1/betaGroups",
                body={"data": {"type": "betaGroups",
                               "attributes": {"name": name,
                                              "publicLinkEnabled": True,
                                              "publicLinkLimitEnabled": False},
                               "relationships": {"app": {"data": {
                                   "type": "apps", "id": app_id}}}}})["data"]
    print(f'Group "{name}": created with public link enabled.')
    return group


def attach_build(group_id: str, build_id: str) -> None:
    api("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
        body={"data": [{"type": "builds", "id": build_id}]},
        tolerate=(409, 422))
    print("Build attached to the group (or already was).")


def submit_for_review(build_id: str) -> str:
    result = api("POST", "/v1/betaAppReviewSubmissions",
                 body={"data": {"type": "betaAppReviewSubmissions",
                                "relationships": {"build": {"data": {
                                    "type": "builds", "id": build_id}}}}},
                 tolerate=(409,))
    if result and result["_status"] == 201:
        state = result["data"]["attributes"]["betaReviewState"]
        print(f"Submitted to Beta App Review: {state}")
        return state
    existing = api("GET", f"/v1/builds/{build_id}/betaAppReviewSubmission",
                   tolerate=(404,))
    state = (existing or {}).get("data", {}).get("attributes", {}) \
        .get("betaReviewState", "UNKNOWN")
    print(f"Build was already submitted; current review state: {state}")
    return state


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="e.g. v2.10.0")
    parser.add_argument("--bundle-id", default="com.readrai.app")
    parser.add_argument("--group-name", default="Public Beta")
    parser.add_argument("--feedback-email", required=True)
    args = parser.parse_args()
    version = args.version.lstrip("v")

    app_id = find_app(args.bundle_id)
    set_test_information(app_id, args.feedback_email)
    build = wait_for_build(app_id, version)
    group = ensure_group(app_id, args.group_name)
    attach_build(group["id"], build["id"])
    state = submit_for_review(build["id"])

    group = api("GET", f"/v1/betaGroups/{group['id']}")["data"]
    link = group["attributes"].get("publicLink") or "(appears after approval)"
    summary = (
        f"## TestFlight beta setup — {args.version}\n\n"
        f"- Test information: set (en-US)\n"
        f"- Group: {args.group_name} (public link enabled)\n"
        f"- Build: {version} ({build['attributes']['version']}) attached\n"
        f"- Beta App Review: {state}\n"
        f"- **Public link**: {link}\n"
    )
    print("\n" + summary)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as fh:
            fh.write(summary)


if __name__ == "__main__":
    main()
