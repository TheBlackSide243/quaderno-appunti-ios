"""Downloads the crash reports and feedback that TestFlight testers sent, for one app.

Writes out/summary.txt, out/crash-<n>.txt (the crash log text) and out/feedback.json.
Only crashes the tester chose to share show up here (TestFlight asks after a crash).
"""
import json
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
out = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(out, exist_ok=True)

now = int(time.time())
token = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
    os.environ["ASC_KEY_P8"],
    algorithm="ES256",
    headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
)
H = {"Authorization": "Bearer " + token}


def get(path, **params):
    r = requests.get(API + path, headers=H, params=params, timeout=60)
    if r.status_code >= 400:
        print("GET", path, r.status_code, r.text[:400])
        return None
    return r.json()


summary = []
apps = get("/v1/apps", **{"filter[bundleId]": os.environ["BUNDLE"]})
if not apps or not apps["data"]:
    sys.exit("app not found")
app = apps["data"][0]["id"]
summary.append("app %s (%s)" % (app, os.environ["BUNDLE"]))

crashes = get("/v1/apps/%s/betaFeedbackCrashSubmissions" % app, limit=50) or {"data": []}
summary.append("crash submissions: %d" % len(crashes["data"]))
for n, c in enumerate(crashes["data"], 1):
    a = c["attributes"]
    summary.append("#%d %s device=%s os=%s build=%s comment=%r" % (
        n, a.get("createdDate"), a.get("deviceModel"), a.get("osVersion"),
        a.get("buildBundleId") or "", a.get("comment")))
    log = get("/v1/betaFeedbackCrashSubmissions/%s/crashLog" % c["id"])
    if log:
        text = log["data"]["attributes"].get("logText") or ""
        with open(os.path.join(out, "crash-%d.txt" % n), "w", encoding="utf-8") as f:
            f.write(text)

fb = get("/v1/apps/%s/betaFeedbackScreenshotSubmissions" % app, limit=50) or {"data": []}
summary.append("screenshot feedback: %d" % len(fb["data"]))
for f in fb["data"]:
    a = f["attributes"]
    summary.append("  %s %s %r" % (a.get("createdDate"), a.get("deviceModel"), a.get("comment")))
with open(os.path.join(out, "feedback.json"), "w", encoding="utf-8") as f:
    json.dump({"crashes": crashes["data"], "screenshots": fb["data"]}, f, indent=1)

text = "\n".join(summary)
print(text)
with open(os.path.join(out, "summary.txt"), "w", encoding="utf-8") as f:
    f.write(text + "\n")
