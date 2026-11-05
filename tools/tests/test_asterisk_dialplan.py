"""Static checks for the Asterisk voice menu and its prompt generator.

Asterisk is not available in CI, so these tests parse the reference dialplans: every label a
Goto/GotoIf names exists in its context, every menu prompt is one the generator renders, every
door entry opens early media before dialing with the menu, and the DTMF codes the dialplan
sends match the sip.dtmf_actions mapping the generator prints.
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MENU = ROOT / "deploy/asterisk/doorbell-menu.conf"
PROD = ROOT / "deploy/asterisk/extensions.conf"
DEV = ROOT / "deploy/dev/asterisk/conf/extensions.conf"
PROMPTS = ROOT / "tools/asterisk_prompts.py"
MENU_GLOBALS = ["DOORBELL_LANG", "MENU_TIMEOUT", "MENU_TRIES", "MENU_TIMEOUT_ACTION",
                "REPLY_COUNT", "REPLY_PREFIX", "DECLINE_CODE"]
RENDERED = {"menu", "reply-menu", "invalid", "reply-sent", "declined"}


def contexts(path):
    result, current = {}, None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split(";", 1)[0].rstrip() if not raw.lstrip().startswith("exten") else raw
        stripped = line.strip()
        header = re.match(r"^\[([^\]]+)\]", stripped)
        if header:
            current = header.group(1)
            result.setdefault(current, [])
        elif current and (stripped.startswith("exten") or stripped.startswith("same")):
            result[current].append(stripped)
    return result


def globals_of(path):
    values = {}
    in_globals = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.split(";", 1)[0].strip()
        if stripped.startswith("["):
            in_globals = stripped == "[globals]"
            continue
        if in_globals and "=" in stripped:
            key, value = stripped.split("=", 1)
            values[key.strip()] = value.strip()
    return values


class DialplanTest(unittest.TestCase):
    def test_menu_labels_resolve(self):
        for name, lines in contexts(MENU).items():
            labels = set()
            for line in lines:
                match = re.match(r"(?:same\s*=>\s*n|exten\s*=>\s*[^,]+,\s*\d+)\(([^)]+)\)", line)
                if match:
                    labels.add(match.group(1))
            for line in lines:
                for target in re.findall(r"GotoIf\(\$\[.*\]\?([^)]*)\)", line):
                    for label in [t for t in target.split(":") if t]:
                        self.assertIn(label, labels, f"{name}: {line}")

    def test_menu_prompts_are_rendered(self):
        text = MENU.read_text(encoding="utf-8")
        used = set(re.findall(r"(?:Read\(\w+,|Playback\()doorbell/([\w-]+)", text))
        self.assertTrue(used)
        self.assertLessEqual(used, RENDERED)

    def test_menu_contract(self):
        menu = "\n".join(contexts(MENU)["doorbell-menu"])
        self.assertIn("GOSUB_RESULT=CONTINUE", menu)
        self.assertIn("SHARED(DOORBELL_DTMF,${ARG1})=${REPLY_PREFIX}${REPLY}", menu)
        self.assertIn("SHARED(DOORBELL_DTMF,${ARG1})=${DECLINE_CODE}", menu)
        result = "\n".join(contexts(MENU)["doorbell-result"])
        self.assertIn("SendDTMF(${ACTION},250)", result)
        self.assertNotIn("Answer(", result)

    def test_door_entries_use_early_media_and_the_menu(self):
        for path, extensions in ((PROD, ["600", "601"]), (DEV, ["620", "_62[1-4]"])):
            lines = contexts(path)["from-door"]
            for exten in extensions:
                block, inside = [], False
                for line in lines:
                    if line.startswith("exten"):
                        inside = line.startswith(f"exten => {exten},")
                    if inside:
                        block.append(line)
                joined = "\n".join(block)
                self.assertIn("U(doorbell-menu^${CHANNEL})", joined, f"{path.name} {exten}")
                self.assertNotIn("Answer()", joined, f"{path.name} {exten}")
                self.assertLess(joined.index("Progress()"), joined.index("Dial("),
                                f"{path.name} {exten}")
                self.assertIn("Goto(doorbell-result,s,1)", joined, f"{path.name} {exten}")

    def test_globals_and_include(self):
        for path in (PROD, DEV):
            text = path.read_text(encoding="utf-8")
            self.assertIn('#include "doorbell-menu.conf"', text)
            values = globals_of(path)
            for key in MENU_GLOBALS:
                self.assertIn(key, values, f"{path.name} lacks {key}")
            self.assertIn(values["MENU_TIMEOUT_ACTION"], ("decline", "talk"))
            self.assertEqual(values["REPLY_PREFIX"], "#2")
            self.assertEqual(values["DECLINE_CODE"], "#90")


class PromptGeneratorTest(unittest.TestCase):
    def run_generator(self, config=None):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = pathlib.Path(tmp) / "manifest.tsv"
            args = [sys.executable, str(PROMPTS), "--strings", str(ROOT / "i18n/strings.yaml"),
                    "--langs", "ja,en,zh", "--manifest", str(manifest)]
            if config is not None:
                path = pathlib.Path(tmp) / "config.json"
                path.write_text(json.dumps(config), encoding="utf-8")
                args += ["--config", str(path)]
            subprocess.run(args, check=True)
            return manifest.read_text(encoding="utf-8").splitlines()

    def mapping(self, lines):
        line = next(item for item in lines if item.startswith("# Door station"))
        return json.loads(line.split(": ", 1)[1])

    def test_defaults_cover_every_prompt_and_language(self):
        lines = self.run_generator()
        rows = [line.split("\t") for line in lines if not line.startswith("#")]
        self.assertEqual({(lang, name) for lang, name, _ in rows},
                         {(lang, name) for lang in ("ja", "en", "zh") for name in RENDERED})
        self.assertTrue(all(text and "{" not in text for _, _, text in rows))
        self.assertIn("# Asterisk [globals]: REPLY_COUNT=4", lines)
        self.assertEqual(self.mapping(lines)["#21"], {"type": "quick_reply", "reply_id": "qr_away"})
        self.assertEqual(self.mapping(lines)["#90"], {"type": "decline"})

    def test_cluster_replies_follow_display_order(self):
        config = {"config": {"quick_replies": {
            "b": {"label": {"ja": "二", "en": "two", "zh": "二"}, "order": 2},
            "a": {"label": {"ja": "一", "en": "one", "zh": "一"}, "order": 1},
        }}}
        lines = self.run_generator(config)
        mapping = self.mapping(lines)
        self.assertEqual(mapping["#21"]["reply_id"], "a")
        self.assertEqual(mapping["#22"]["reply_id"], "b")
        self.assertIn("# Asterisk [globals]: REPLY_COUNT=2", lines)
        menu = next(line for line in lines if line.startswith("en\treply-menu\t"))
        self.assertLess(menu.index("one"), menu.index("two"))


if __name__ == "__main__":
    unittest.main()
