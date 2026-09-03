#!/usr/bin/env python3
"""
ViboGram - badge "equip" choice, server-authoritative like game_sync.py.

badges.json (Swiftgram/SGBadges) is a static, CI-published, owner-curated
file -- there's no live per-user write path into it, and rightly so (it's
published from a repo secret, which a workflow's default token can't write
back to anyway). But which badge a peer with *more than one* wants shown as
their primary one needs to be visible to every viewer, not just the owner's
own device -- a local-only setting on one phone can't do that.

Same shape as game_sync.py's players/<game>/<username>.json: CI is the sole
writer, the client only ever *requests* (opens a pre-filled GitHub Issue,
same as .opull/.ocraft/.obattle), and this script independently decides
whether the request is valid before writing anything. Written here to
data/badge_equip.json (peer id -> equipped badge title), a plain git-committed
file SGBadges.swift fetches alongside badges.json itself and uses to reorder
which entry primaryBadge() returns first for a peer with multiple badges.

Identity: badges.json is entirely owner-curated (see its own README section --
"whoever builds their own fork picks their own people"), so unlike the game's
per-username claiming, an equip request is only ever valid from the repo
owner's own GitHub account (github.event.issue.user.login, authenticated by
GitHub itself -- REPO_OWNER is github.repository_owner from the workflow,
not anything the issue text could forge). Anyone else's request is rejected,
same spirit as game_sync.py's impersonation check but simpler: there's
exactly one trusted identity here, not a per-username claim table.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

GH_API_BASE = "https://api.github.com"
TITLE_RE = re.compile(r"^\[badge-equip\]\s+(\d+)\s*$")
BADGE_EQUIP_PATH = "data/badge_equip.json"
# MARK: ViboGram - the published release asset, same URL SGBadges.swift
# itself fetches -- read-only, no auth needed, and always reflects
# whatever's actually live right now (not whatever this script might
# otherwise assume). Used only to verify the requested title really exists
# for the requested peer before writing anything.
BADGES_JSON_URL = "https://github.com/vibeDN/ViboGram/releases/download/data/badges.json"


def gh_api(method, path, token, payload=None):
    req = urllib.request.Request(GH_API_BASE + path, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=20) as resp:
        return json.load(resp)


def reject(token, repo, issue_number, reason):
    gh_api("POST", f"/repos/{repo}/issues/{issue_number}/comments", token, {"body": f"❌ Rejected: {reason}"})
    gh_api("PATCH", f"/repos/{repo}/issues/{issue_number}", token, {"state": "closed"})
    print(f"Rejected #{issue_number}: {reason}")


def accept(token, repo, issue_number, message):
    gh_api("POST", f"/repos/{repo}/issues/{issue_number}/comments", token, {"body": f"✅ {message}"})
    gh_api("PATCH", f"/repos/{repo}/issues/{issue_number}", token, {"state": "closed"})
    print(f"Accepted #{issue_number}: {message}")


def parse_body(body):
    fields = {}
    for line in (body or "").splitlines():
        line = line.strip()
        m = re.match(r"^(title)=(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2).strip()
    return fields


def fetch_live_badges():
    with urllib.request.urlopen(BADGES_JSON_URL, timeout=20) as resp:
        return json.load(resp)


def load_equip_map():
    if not os.path.exists(BADGE_EQUIP_PATH):
        return {}
    with open(BADGE_EQUIP_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_and_push(equip_map):
    os.makedirs(os.path.dirname(BADGE_EQUIP_PATH), exist_ok=True)
    with open(BADGE_EQUIP_PATH, "w", encoding="utf-8") as f:
        json.dump(equip_map, f, indent=2, sort_keys=True)
        f.write("\n")
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"], check=True)
    subprocess.run(["git", "add", BADGE_EQUIP_PATH], check=True)
    result = subprocess.run(["git", "commit", "-m", "badge-sync: update equipped badge [skip ci]"], capture_output=True, text=True)
    if result.returncode == 0:
        subprocess.run(["git", "push", "origin", "HEAD:main"], check=True)


def main():
    token = os.environ["GH_TOKEN"]
    repo = os.environ["GH_REPO"]
    issue_number = os.environ["ISSUE_NUMBER"]
    title = os.environ.get("ISSUE_TITLE", "")
    body = os.environ.get("ISSUE_BODY", "")
    github_author = os.environ.get("ISSUE_AUTHOR", "")
    repo_owner = os.environ.get("REPO_OWNER", "")

    match = TITLE_RE.match(title.strip())
    if not match:
        print("Title doesn't match a badge-equip request, ignoring.")
        return

    peer_id = match.group(1)

    if not github_author or not repo_owner or github_author != repo_owner:
        reject(token, repo, issue_number, "badges.json is owner-curated -- only the repo owner's own GitHub account can change which badge is equipped.")
        return

    fields = parse_body(body)
    requested_title = fields.get("title", "")
    if not requested_title:
        reject(token, repo, issue_number, "missing title= in the issue body.")
        return

    try:
        live_badges = fetch_live_badges()
    except Exception as e:
        reject(token, repo, issue_number, f"couldn't fetch the live badges.json to verify this request: {e}")
        return

    matching_titles = [b.get("title") for b in live_badges if str(b.get("peer")) == peer_id]
    if requested_title not in matching_titles:
        reject(token, repo, issue_number, f"peer {peer_id} has no badge titled {requested_title!r} in the live badges.json (has: {matching_titles}).")
        return

    equip_map = load_equip_map()
    equip_map[peer_id] = requested_title
    save_and_push(equip_map)

    accept(token, repo, issue_number, f"Equipped {requested_title!r} for peer {peer_id}.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"badge_sync.py error: {e}", file=sys.stderr)
        sys.exit(1)
