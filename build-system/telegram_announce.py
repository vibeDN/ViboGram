"""Posts a release announcement to the ViboGram Telegram channel.

Shared by trial-build.yml (CI-published releases) and announce-release.yml
(any release published on GitHub, including manual ones). Reads everything
from environment variables so both workflows can call it the same way.
"""
import html
import json
import os
import re
import urllib.request

CLIENT_FEATURES = [
    "Ghost mode — без чеков прочтения и статуса «в сети»",
    "Streamer mode — прячет номер телефона в интерфейсе",
    "ID пользователя виден в профиле",
    "Никакой спонсорской/рекламной мишуры",
    "Обход клиентских iOS-ограничений на контент",
    "Растягиваемое поле ввода + свой размер шрифта",
    "Текстовые эффекты: размер, затемнение, радуга",
    "Скриншоты и сохранение медиа разрешены в секретных чатах",
    "Мгновенное удаление самоуничтожающихся медиа",
]


def gh_changelog_to_bullets(md: str) -> str:
    # generate-notes (and GitHub's own "Generate release notes") produce a
    # "## What's Changed" heading, "* message in url" bullets, and a trailing
    # "**Full Changelog**: url" line -- drop the heading/full-changelog line
    # (redundant with the GitHub button) and keep just the bullet list.
    lines = []
    for line in md.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if re.match(r'^#{1,6}\s*', stripped):
            continue
        if stripped.startswith('**Full Changelog**'):
            continue
        stripped = re.sub(r'^[\*\-]\s+', '', stripped)
        lines.append(f"• {stripped}")
    return "\n".join(lines) if lines else "• (пусто)"


def main():
    token = os.environ["TELEGRAM_BOT_TOKEN"]
    chat_id = os.environ["TELEGRAM_CHAT_ID"]
    version = os.environ["VERSION"]
    tg_base_version = os.environ.get("TG_BASE_VERSION", "").strip()
    raw_notes = os.environ.get("NOTES", "")
    ipa_url = os.environ.get("IPA_URL", "").strip()
    repo = os.environ["GITHUB_REPOSITORY"]

    version_line = f"Vibogram <b>{html.escape(version)}</b>"
    if tg_base_version:
        version_line += f" (Telegram {html.escape(tg_base_version)})"

    features_block = "\n".join(f"• {html.escape(f)}" for f in CLIENT_FEATURES)
    changelog_block = gh_changelog_to_bullets(html.escape(raw_notes))

    # sendPhoto captions cap at 1024 chars (vs 4096 for plain messages) --
    # trim the changelog block specifically to fit, since the header +
    # feature list is fixed overhead.
    header = (
        f"{version_line}\n\n"
        f"<b>Что умеет клиент:</b>\n<blockquote>{features_block}</blockquote>\n\n"
        f"<b>Что нового в {html.escape(version)}:</b>\n"
    )
    wrapper_overhead = len("<blockquote></blockquote>")
    budget = 1024 - len(header) - wrapper_overhead - 1
    if len(changelog_block) > budget:
        changelog_block = changelog_block[:budget - 1] + "…"
    caption = f"{header}<blockquote>{changelog_block}</blockquote>"

    top_row = [{"text": "🐙 GitHub", "url": f"https://github.com/{repo}"}]
    top_row.append({"text": "✨ Все фишки форка", "url": f"https://github.com/{repo}/blob/main/README.md"})
    buttons = [top_row]
    if ipa_url:
        buttons.append([{"text": "⬇️ Актуальный установочный файл", "url": ipa_url}])

    payload = json.dumps({
        "chat_id": chat_id,
        "photo": "https://raw.githubusercontent.com/{}/main/.github/assets/telegram-banner.jpg".format(repo),
        "caption": caption,
        "parse_mode": "HTML",
        "reply_markup": {"inline_keyboard": buttons},
    }).encode()

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendPhoto",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        print(resp.read().decode())


if __name__ == "__main__":
    main()
