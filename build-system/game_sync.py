#!/usr/bin/env python3
"""
ViboGram - card_pull.vibo / phone_pull.vibo server-authoritative economy.

Runs from .github/workflows/game-sync.yml on every opened issue. A plugin
can't safely hold write credentials (anything embedded in a downloadable
plugin file is public), so it can't commit to the repo itself -- opening a
pre-filled GitHub Issue is the only thing it can safely trigger that ends
up processed here, where the real git-writing token lives only in CI.

Design: CI is the SOLE owner of player state (players/<game>/<username>.json,
an inventory of {card_index: count} plus last_pull_date/wins/losses/draws).
The plugin never submits a final snapshot to accept on faith -- it only
submits REQUESTS (pull / craft), and this script independently decides the
outcome and applies it. That's what makes duplicate-inflation ("накрутили
10к самых крутых") and history-rewriting impossible from the client side:
the client literally cannot say what card it got, only that it wants to
pull.

Identity: GitHub issues have no cryptographic link to a Telegram username --
anyone with a GitHub account could open `[pull:card_pull] someone_elses_name`
otherwise. Each request must include a `secret` field the plugin generates
once and keeps locally. The FIRST request CI ever sees for a given username
claims it (stores that secret); every later request for that username must
supply the same secret or is rejected as impersonation. This is a casual
bearer-token scheme, not real auth -- good enough to stop drive-by
impersonation in a small hobby-project community, not a bank.

Trades are intentionally NOT implemented here yet -- a safe trade needs
mutual consent from both players (a propose/accept handshake), which this
first pass doesn't have. Only pull and craft, both single-player operations
with no risk of moving another player's cards, ship in this version.
"""
import json
import os
import re
import secrets as pysecrets
import subprocess
import sys
from datetime import date

# MARK: ViboGram - must match CARD_POOL in plugins/card_pull.vibo and
# plugins/phone_pull.vibo exactly. Only rarity (for craft recipes) and
# pool size (for bounds checking) matter here -- CI does its own weighted
# roll independently of whatever the client's local practice-pull showed,
# so the actual RNG never has to match, only the pool shape.
CARD_POOLS = {
    "card_pull": {
        "Common": list(range(0, 10)),
        "Rare": list(range(10, 16)),
        "Epic": list(range(16, 21)),
        "Legendary": list(range(21, 24)),
    },
    "phone_pull": {
        # MARK: ViboGram - +[25] -- Fairphone appended after the
        # Legendary tier additions, so its index isn't contiguous with
        # the original 0-9 Common range. Append-only per
        # phone_pull.vibo's own CARD_POOL comment.
        "Common": list(range(0, 10)) + [25],
        "Rare": list(range(10, 16)),
        "Epic": list(range(16, 21)),
        # 21-24 now (was 21-23) -- Pixel 11 Pro XL 16GB/1TB appended as
        # index 24.
        "Legendary": list(range(21, 25)),
    },
}
RARITY_WEIGHTS = {"Common": 60, "Rare": 25, "Epic": 12, "Legendary": 3}
RARITY_ORDER = ["Common", "Rare", "Epic", "Legendary"]
# MARK: ViboGram - fixed duplicate-fusion recipe, same idea in both games:
# N copies of any ONE card at a given tier -> 1 random card from the NEXT
# tier up. Cost escalates per tier so climbing to Legendary via crafting
# alone is a real grind, not a shortcut around the daily pull.
CRAFT_COST = {"Common": 3, "Rare": 5, "Epic": 7}

# MARK: ViboGram - real, mechanical passives, tied to RARITY TIER rather
# than to each individual card (48 unique hand-balanced passives across
# both games is its own project; a shared 4-entry table is tractable to
# actually balance and test). Escalates with rarity, same spirit as
# CRAFT_COST -- a Legendary should feel meaningfully stronger than a
# Common, but nothing here ever guarantees a win or a free craft, only
# softens bad luck, once a day.
#   Common  "Budget Grind"    -- craft cost for this tier is 1 cheaper
#                                (a real economy nudge: commons are ~60%
#                                of pulls, so make them worth using)
#   Rare    (none)            -- deliberately the plain middle tier
#   Epic    "Second Wind"     -- the first battle LOSS with an Epic card
#                                each day doesn't count against your
#                                losses tally (still costs the attempt)
#   Legendary "Always Charged" -- the first battle LOSS with a Legendary
#                                card each day doesn't count against your
#                                losses tally AND is refunded (doesn't
#                                consume one of the 3 daily attempts)
PASSIVE_CRAFT_DISCOUNT = {"Common": 1}
PASSIVE_LOSS_MITIGATION = {"Epic": "count_only", "Legendary": "refund"}

# MARK: ViboGram - a single "power" number per card index, indexed to
# match CARD_POOL's order in the corresponding .vibo file exactly
# (card_pull: ATK+DEF: phone_pull: the benchmark score itself). Needed
# server-side for battle matchmaking/resolution -- kept here rather than
# re-derived from the .vibo source so this script has no dependency on
# parsing Python out of another file. MUST be updated by hand alongside
# the .vibo files if their CARD_POOL stats ever change.
CARD_POWERS = {
    "card_pull": [700, 750, 700, 800, 730, 720, 750, 750, 760, 750,
                  1200, 1250, 1200, 1350, 1250, 1220,
                  1900, 1950, 1900, 2100, 2000,
                  3200, 3300, 3500],
    "phone_pull": [280, 220, 240, 200, 150, 300, 190, 230, 260, 210,
                   650, 680, 700, 720, 750, 600,
                   1600, 1550, 1400, 1580, 1650,
                   2000, 1, 9999, 2100, 120],
}
# MARK: ViboGram - "искалось +- похожих в колодах картах": an opponent is
# picked from cards within this fraction band of the battler's own power,
# not a flat random pick from the whole pool (which could pit a fresh
# Common against a Legendary). Falls back to the whole pool only if the
# band is somehow empty.
MATCH_BAND = (0.6, 1.6)
BATTLE_DAILY_LIMIT = 3

USERNAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{4,31}$")
TITLE_RE = re.compile(r"^\[(pull|craft|battle):(card_pull|phone_pull)\]\s+(\S+)\s*$")

GH_API_BASE = "https://api.github.com"


def gh_api(method, path, token, payload=None):
    import urllib.request
    req = urllib.request.Request(GH_API_BASE + path, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=20) as resp:
        return json.load(resp)


def parse_body(body):
    """Plain `key=value` lines -- one regex-bounded format, nothing the
    issue body's free-form text could smuggle code into."""
    fields = {}
    for line in (body or "").splitlines():
        line = line.strip()
        m = re.match(r"^(secret|card_index)=(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2).strip()
    return fields


def reject(token, repo, issue_number, reason):
    gh_api("POST", f"/repos/{repo}/issues/{issue_number}/comments", token, {"body": f"❌ Rejected: {reason}"})
    gh_api("PATCH", f"/repos/{repo}/issues/{issue_number}", token, {"state": "closed"})
    print(f"Rejected #{issue_number}: {reason}")


def accept(token, repo, issue_number, message):
    gh_api("POST", f"/repos/{repo}/issues/{issue_number}/comments", token, {"body": f"✅ {message}"})
    gh_api("PATCH", f"/repos/{repo}/issues/{issue_number}", token, {"state": "closed"})
    print(f"Accepted #{issue_number}: {message}")


def rarity_of(game, idx):
    for rarity, indices in CARD_POOLS[game].items():
        if idx in indices:
            return rarity
    return None


def roll_card(game, rarity=None):
    if rarity is None:
        rarity = pysecrets.SystemRandom().choices(list(RARITY_WEIGHTS.keys()), weights=list(RARITY_WEIGHTS.values()))[0]
    return pysecrets.SystemRandom().choice(CARD_POOLS[game][rarity])


def roll_matched_opponent(game, my_power):
    powers = CARD_POWERS[game]
    low, high = my_power * MATCH_BAND[0], my_power * MATCH_BAND[1]
    candidates = [idx for idx, power in enumerate(powers) if low <= power <= high]
    if not candidates:
        candidates = list(range(len(powers)))
    return pysecrets.SystemRandom().choice(candidates)


def load_player(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return None


def save_player(path, player):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(player, f, indent=2, sort_keys=True)


def commit_and_push(path, message):
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"], check=True)
    subprocess.run(["git", "add", path], check=True)
    result = subprocess.run(["git", "commit", "-m", message + " [skip ci]"], capture_output=True, text=True)
    if result.returncode == 0:
        subprocess.run(["git", "push", "origin", "HEAD:main"], check=True)


def check_identity(player, secret):
    """Returns None if OK, or a rejection reason string."""
    if not secret:
        return "missing secret field -- this plugin build is out of date, or the request was tampered with."
    if player is not None and player.get("secret") != secret:
        return "secret doesn't match -- this username is already claimed by a different install. If this is really you, your local secret got reset; nothing can recover the old one (that's the point)."
    return None


def handle_pull(token, repo, issue_number, game, username, fields):
    player_path = f"players/{game}/{username}.json"
    player = load_player(player_path)
    secret = fields.get("secret", "")

    identity_error = check_identity(player, secret)
    if identity_error:
        reject(token, repo, issue_number, identity_error)
        return

    if player is None:
        player = {"username": username, "secret": secret, "inventory": {}, "last_pull_date": "", "wins": 0, "losses": 0, "draws": 0}

    today = date.today().isoformat()
    if player["last_pull_date"] == today:
        reject(token, repo, issue_number, "already pulled today -- come back tomorrow.")
        return

    idx = roll_card(game)
    player["inventory"][str(idx)] = player["inventory"].get(str(idx), 0) + 1
    player["last_pull_date"] = today
    save_player(player_path, player)
    commit_and_push(player_path, f"game-sync: {game}/{username} pull -> card {idx}")

    rarity = rarity_of(game, idx)
    accept(token, repo, issue_number, f"You pulled card #{idx} ({rarity}). Your `{game}` inventory: `{player_path}`")


def handle_craft(token, repo, issue_number, game, username, fields):
    player_path = f"players/{game}/{username}.json"
    player = load_player(player_path)
    secret = fields.get("secret", "")

    identity_error = check_identity(player, secret)
    if identity_error:
        reject(token, repo, issue_number, identity_error)
        return
    if player is None:
        reject(token, repo, issue_number, "no inventory on record yet -- pull at least one card first.")
        return

    try:
        consume_idx = int(fields.get("card_index", ""))
    except ValueError:
        reject(token, repo, issue_number, "card_index isn't a valid number.")
        return

    rarity = rarity_of(game, consume_idx)
    if rarity is None:
        reject(token, repo, issue_number, "card_index isn't a real card in this game's pool.")
        return
    if rarity not in CRAFT_COST:
        reject(token, repo, issue_number, f"{rarity} cards can't be crafted further -- that's already the top tier.")
        return

    have = player["inventory"].get(str(consume_idx), 0)
    # MARK: ViboGram - "Budget Grind" passive (see PASSIVE_CRAFT_DISCOUNT
    # above): Common-tier crafting costs 1 fewer copy, floored at 1 so a
    # future lower CRAFT_COST entry can never hit 0.
    cost = max(1, CRAFT_COST[rarity] - PASSIVE_CRAFT_DISCOUNT.get(rarity, 0))
    if have < cost:
        reject(token, repo, issue_number, f"you have {have}x card #{consume_idx}, crafting needs {cost}x.")
        return

    next_rarity = RARITY_ORDER[RARITY_ORDER.index(rarity) + 1]
    produced_idx = roll_card(game, rarity=next_rarity)

    player["inventory"][str(consume_idx)] = have - cost
    if player["inventory"][str(consume_idx)] == 0:
        del player["inventory"][str(consume_idx)]
    player["inventory"][str(produced_idx)] = player["inventory"].get(str(produced_idx), 0) + 1
    save_player(player_path, player)
    commit_and_push(player_path, f"game-sync: {game}/{username} craft {cost}x#{consume_idx} -> #{produced_idx}")

    accept(token, repo, issue_number, f"Crafted {cost}x card #{consume_idx} ({rarity}) into 1x card #{produced_idx} ({next_rarity}). Your `{game}` inventory: `{player_path}`")


def handle_battle(token, repo, issue_number, game, username, fields):
    player_path = f"players/{game}/{username}.json"
    player = load_player(player_path)
    secret = fields.get("secret", "")

    identity_error = check_identity(player, secret)
    if identity_error:
        reject(token, repo, issue_number, identity_error)
        return
    if player is None:
        reject(token, repo, issue_number, "no inventory on record yet -- pull at least one card first.")
        return

    try:
        my_idx = int(fields.get("card_index", ""))
    except ValueError:
        reject(token, repo, issue_number, "card_index isn't a valid number.")
        return

    if player["inventory"].get(str(my_idx), 0) < 1:
        reject(token, repo, issue_number, "you don't own that card.")
        return

    today = date.today().isoformat()
    if player.get("last_battle_date") != today:
        player["battles_today"] = 0
        player["last_battle_date"] = today
        # MARK: ViboGram - loss-mitigation passives (Second Wind / Always
        # Charged) reset on the same daily boundary as the battle-attempt
        # counter -- one softened loss per real day, not per card, not
        # per battle.
        player["mitigation_used_date"] = None
    if player["battles_today"] >= BATTLE_DAILY_LIMIT:
        reject(token, repo, issue_number, f"already used all {BATTLE_DAILY_LIMIT} official battles today -- come back tomorrow.")
        return

    my_power = CARD_POWERS[game][my_idx]
    opp_idx = roll_matched_opponent(game, my_power)
    opp_power = CARD_POWERS[game][opp_idx]
    my_rarity = rarity_of(game, my_idx)

    player["battles_today"] += 1
    if my_power > opp_power:
        # MARK: ViboGram - the actual "призы за победы": a win grants one
        # extra card at the SAME rarity you battled with (re-rolled, not a
        # guaranteed specific card) -- a real but bounded reward, doesn't
        # let anyone farm straight to Legendary through battling alone.
        prize_idx = roll_card(game, rarity=my_rarity)
        player["inventory"][str(prize_idx)] = player["inventory"].get(str(prize_idx), 0) + 1
        player["wins"] = player.get("wins", 0) + 1
        save_player(player_path, player)
        commit_and_push(player_path, f"game-sync: {game}/{username} battle win, prize #{prize_idx}")
        accept(token, repo, issue_number, f"Your #{my_idx} (power {my_power}) beat #{opp_idx} (power {opp_power})! Prize: card #{prize_idx} ({my_rarity}). Your `{game}` inventory: `{player_path}`")
    elif my_power < opp_power:
        mitigation = PASSIVE_LOSS_MITIGATION.get(my_rarity)
        mitigated = mitigation is not None and player.get("mitigation_used_date") != today
        if mitigated:
            player["mitigation_used_date"] = today
            if mitigation == "refund":
                # MARK: ViboGram - "Always Charged": the loss doesn't
                # count AND the attempt itself is refunded.
                player["battles_today"] -= 1
                note = f"Your #{my_idx}'s Legendary passive (Always Charged) voided this loss AND refunded the attempt -- battles left today unaffected."
            else:
                # "Second Wind": the loss doesn't count, but the attempt
                # is still spent.
                note = f"Your #{my_idx}'s Epic passive (Second Wind) voided this loss (attempt still spent)."
            save_player(player_path, player)
            commit_and_push(player_path, f"game-sync: {game}/{username} battle loss mitigated ({mitigation})")
            accept(token, repo, issue_number, f"Your #{my_idx} (power {my_power}) lost to #{opp_idx} (power {opp_power}). {note}")
        else:
            player["losses"] = player.get("losses", 0) + 1
            save_player(player_path, player)
            commit_and_push(player_path, f"game-sync: {game}/{username} battle loss")
            accept(token, repo, issue_number, f"Your #{my_idx} (power {my_power}) lost to #{opp_idx} (power {opp_power}). No prize this time.")
    else:
        player["draws"] = player.get("draws", 0) + 1
        save_player(player_path, player)
        commit_and_push(player_path, f"game-sync: {game}/{username} battle draw")
        accept(token, repo, issue_number, f"Your #{my_idx} (power {my_power}) drew with #{opp_idx} (power {opp_power}). No prize this time.")


def main():
    token = os.environ["GH_TOKEN"]
    repo = os.environ["GH_REPO"]
    issue_number = os.environ["ISSUE_NUMBER"]
    title = os.environ.get("ISSUE_TITLE", "")
    body = os.environ.get("ISSUE_BODY", "")

    match = TITLE_RE.match(title.strip())
    if not match:
        print("Title doesn't match a pull/craft request, ignoring.")
        return

    action, game, username = match.group(1), match.group(2), match.group(3)

    if not USERNAME_RE.match(username):
        reject(token, repo, issue_number, "username doesn't look like a real Telegram username.")
        return

    fields = parse_body(body)

    if action == "pull":
        handle_pull(token, repo, issue_number, game, username, fields)
    elif action == "craft":
        handle_craft(token, repo, issue_number, game, username, fields)
    elif action == "battle":
        handle_battle(token, repo, issue_number, game, username, fields)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        # Don't fail the whole Actions run loudly over a malformed issue --
        # this is best-effort processing of arbitrary public input, not a
        # release step that should ever go red.
        sys.exit(0)
