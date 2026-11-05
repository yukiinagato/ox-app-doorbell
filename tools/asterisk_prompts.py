#!/usr/bin/env python3
"""Builds the voice-menu prompt texts for tools/gen_asterisk_prompts.sh.

Writes a tab-separated manifest (lang, file, text) plus '#' comment lines with the matching
REPLY_COUNT and sip.dtmf_actions mapping. Reads the restricted single-line YAML format of
i18n/strings.yaml.
"""
import argparse
import json
import re
import sys

LINE = re.compile(r'^([A-Za-z0-9_.]+):\s*\{(.*)\}\s*$')
FIELD = re.compile(r'(\w+):\s*"((?:[^"\\]|\\.)*)"')
DEFAULT_REPLIES = ["qr_away", "qr_no", "qr_wrong", "qr_wait"]
REPLY_PREFIX = "#2"
DECLINE_CODE = "#90"
MAX_REPLIES = 9


def load_strings(path):
    strings = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            match = LINE.match(raw.strip())
            if not match:
                continue
            strings[match.group(1)] = {k: v.replace('\\"', '"') for k, v in FIELD.findall(match.group(2))}
    return strings


def text(strings, key, lang, **values):
    entry = strings.get(key)
    if not entry:
        raise SystemExit(f"missing i18n key {key}")
    value = entry.get(lang) or entry.get("en") or next(iter(entry.values()))
    for name, replacement in values.items():
        value = value.replace("{" + name + "}", replacement)
    return value


def configured_replies(config_path, strings):
    if not config_path:
        return [(rid, strings.get("core.seed.quick_reply." + rid, {})) for rid in DEFAULT_REPLIES]
    with open(config_path, encoding="utf-8") as handle:
        doc = json.load(handle)
    for key in ("config", "configuration"):
        if isinstance(doc.get(key), dict):
            doc = doc[key]
            break
    replies = doc.get("quick_replies")
    if not isinstance(replies, dict) or not replies:
        raise SystemExit("the configuration has no quick_replies")
    ordered = sorted(
        ((rid, body) for rid, body in replies.items() if isinstance(body, dict)),
        key=lambda item: (item[1].get("order", 1 << 30), item[0]))
    return [(rid, body.get("label") or {}) for rid, body in ordered]


def label_in(label, lang):
    if isinstance(label, str):
        return label
    return label.get(lang) or label.get("ja") or label.get("en") or next(iter(label.values()), "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strings", required=True)
    parser.add_argument("--langs", default="ja,en,zh")
    parser.add_argument("--config")
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()

    strings = load_strings(args.strings)
    replies = configured_replies(args.config, strings)[:MAX_REPLIES]
    rows = []
    for lang in [item for item in args.langs.split(",") if item]:
        rows.append((lang, "menu", text(strings, "core.ivr.menu", lang)))
        parts = [text(strings, "core.ivr.reply_menu", lang)]
        for index, (_, label) in enumerate(replies, start=1):
            parts.append(text(strings, "core.ivr.reply_option", lang,
                              label=label_in(label, lang), digit=str(index)))
        parts.append(text(strings, "core.ivr.reply_back", lang))
        rows.append((lang, "reply-menu", " ".join(parts)))
        rows.append((lang, "invalid", text(strings, "core.ivr.invalid", lang)))
        rows.append((lang, "reply-sent", text(strings, "core.ivr.reply_sent", lang)))
        rows.append((lang, "declined", text(strings, "core.ivr.declined", lang)))

    mapping = {f"{REPLY_PREFIX}{index}": {"type": "quick_reply", "reply_id": rid}
               for index, (rid, _) in enumerate(replies, start=1)}
    mapping[DECLINE_CODE] = {"type": "decline"}
    with open(args.manifest, "w", encoding="utf-8") as out:
        for lang, name, body in rows:
            if "\t" in body or "\n" in body:
                raise SystemExit(f"prompt text for {lang}/{name} contains a tab or newline")
            out.write(f"{lang}\t{name}\t{body}\n")
        out.write(f"# Asterisk [globals]: REPLY_COUNT={len(replies)}\n")
        out.write("# Door station sip.dtmf_actions (merge in Admin): "
                  + json.dumps(mapping, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
