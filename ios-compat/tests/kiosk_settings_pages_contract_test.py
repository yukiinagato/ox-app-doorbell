#!/usr/bin/env python3
"""Source contracts for the kiosk's native settings editor pages
(ios-kiosk/src/Screens/DBSettingsPages.m and DBEditor.m).

The pages reach parity with the web admin, so the rules that keep that safe are
pinned here:
  1. Every page identifier the settings screen opens is handled by pageNamed:.
  2. Another device's role and door are written as one batch, after a
     confirmation that the target restarts; this device's own entry writes
     nothing from the Devices page.
  3. Destructive actions are confirmed and name what is lost.
  4. Secrets go to the secure store; configuration only receives a
     "secret:<name>" reference, including through the raw key writer.
  5. The only HTTP the pages speak is this device's own Core over loopback:
     the administrator session that already existed (DBAdminHttpSession) for the
     routes Core has no C export for, and the public asset route.
  6. The lists the web admin defines (ink regions, UI properties, playback
     strategies, Web Push keys) are read from webui/admin/app.js, so a value
     the admin gains without a native row fails here.

The arithmetic (door filtering, used-by, ranges, flattening) is covered by the
host test ios-compat/tests/kiosk_settings_pages_test.m.
"""

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PAGES = "ios-kiosk/src/Screens/DBSettingsPages.m"
EDITOR = "ios-kiosk/src/Screens/DBEditor.m"
LOGIC = "ios-kiosk/src/Core/DBSettingsLogic.m"
ADMIN = "webui/admin/app.js"

PAGE_IDS = [
    # Present before the parity work.
    "quick_replies", "purposes", "notice_presets", "quiet_hours", "ntp_servers", "rules",
    "telegram", "secrets", "sip", "mqtt", "panels", "media_sources", "places", "devices",
    "wording", "theme", "sounds", "config_transfer", "admin_password",
    # Added for parity with the web admin.
    "web_push", "assets", "speech", "playback_policy", "capabilities", "ui_elements",
    "raw_config", "logs", "other_devices", "cluster_security",
]

# Core routes without a C export. /api/test/telegram predates the parity work.
ALLOWED_ROUTES = {
    "/api/test/telegram", "/api/pairing/rebuild", "/api/panel-token/rotate",
    "/api/panel-token/provision", "/api/tts", "/api/tts/cache", "/api/logs", "/api/events",
}


def read(relative_path):
    with open(os.path.join(ROOT, relative_path), encoding="utf-8") as handle:
        return handle.read()


def method(source, signature):
    """The text of one Objective-C method or C function, up to the next definition."""
    start = source.index(signature)
    following = re.search(r"\n(?:[-+] \(|#pragma mark|static |@end)", source[start + len(signature):])
    end = start + len(signature) + following.start() if following else len(source)
    return source[start:end]


def js_string_array(source, name):
    match = re.search(r"var %s = \[([^\]]*)\]" % re.escape(name), source)
    if match is None:
        raise AssertionError("webui/admin/app.js no longer defines %s" % name)
    return re.findall(r'"([^"]+)"', match.group(1))


class KioskSettingsPagesContracts(unittest.TestCase):
    def test_every_page_identifier_is_routed(self):
        router = method(read(PAGES), "- (DBEditPage *)pageNamed:(NSString *)name {")
        for identifier in PAGE_IDS:
            self.assertIn('[name isEqualToString:@"%s"]' % identifier, router, identifier)
        # An unknown name opens nothing.
        self.assertTrue(router.rstrip().endswith("return nil;\n}"), router[-80:])
        header = read("ios-kiosk/src/Screens/DBSettingsPages.h")
        for identifier in PAGE_IDS:
            self.assertIn(identifier, header, identifier)

    def test_other_device_role_edits_are_one_confirmed_batch(self):
        pages = read(PAGES)
        apply_identity = method(pages, "- (void)applyIdentity:(NSString *)device")
        # The batch comes from the validated builder, is confirmed with the restart notice,
        # and is committed as one write.
        self.assertIn("[DBSettingsLogic roleChangeOpsForDevice:device role:role door:door]",
                      apply_identity)
        self.assertIn('"editor.role_restart_confirm"', apply_identity)
        self.assertIn("[_editor confirmTitle:title message:message then:^{", apply_identity)
        confirm = apply_identity[apply_identity.index("[_editor confirmTitle:"):]
        self.assertIn("[pages commit:ops]", confirm)
        self.assertNotIn("commit:", apply_identity[:apply_identity.index("[_editor confirmTitle:")])
        # An invalid door never reaches the confirmation.
        self.assertLess(apply_identity.index("if (ops == nil)"),
                        apply_identity.index("[_editor confirmTitle:"))
        # This device's own identity is never written from here.
        self.assertIn("if ([device isEqualToString:_nodeId]) return;", apply_identity)
        self.assertLess(apply_identity.index("if ([device isEqualToString:_nodeId]) return;"),
                        apply_identity.index("roleChangeOpsForDevice"))

        # Nothing else writes a role or a door key.
        self.assertNotIn('setKey:[base stringByAppendingString:@".role"]', pages)
        self.assertNotIn('setKey:[base stringByAppendingString:@".door"]', pages)
        self.assertNotIn('key:[base stringByAppendingString:@".door"]', pages)
        identity = method(pages, "- (DBEditPage *)identityPage:(NSString *)device {")
        self.assertNotIn("setKey:", identity)
        self.assertNotIn("commit:", identity)
        self.assertEqual(identity.count("[weakSelf applyIdentity:device role:"), 2)
        self.assertIn("[deep applyIdentity:device role:@\"door_station\" door:entered]", identity)
        self.assertIn("[DBSettingsLogic unservedDoorsInConfig:cfg", identity)
        self.assertIn("[DBSettingsLogic validDoorId:entered]", identity)

        # The builder writes role and door together, role first.
        logic = read(LOGIC)
        builder = method(logic, "+ (NSArray *)roleChangeOpsForDevice:")
        self.assertLess(builder.index('@".role"'), builder.index('@".door"'))
        self.assertEqual(builder.count('@"op" : @"set"'), 2)
        self.assertIn('doorStation ? door : @""', builder)

        # The misleading "changed on that device" footer is gone.
        self.assertNotIn("editor.role_on_device", pages)

    def test_this_device_entry_is_read_only_in_the_devices_page(self):
        device_page = method(read(PAGES), "- (DBEditPage *)devicePage:(NSString *)device {")
        own = device_page[device_page.index("if (me) {"):device_page.index("} else {")]
        for forbidden in ("setKey:", "commit:", "onChange", "DBEditKindText", "identityPage"):
            self.assertNotIn(forbidden, own, forbidden)
        self.assertIn('"settings.device_self_hint"', own)
        # Another device's name is length-checked before it is written.
        other = device_page[device_page.index("} else {"):]
        self.assertLess(other.index("[DBSettingsLogic validDeviceName:text]"),
                        other.index('setKey:[base stringByAppendingString:@".name"]'))
        # A device whose role is fixed gets no role editor.
        self.assertIn("[DBSettingsLogic roleEditableForDevice:entry peer:peer]", other)
        # Removing a device names the device and the consequence.
        self.assertIn('"admin.remove_device_confirm"', device_page)

    def test_destructive_actions_confirm_and_name_the_consequence(self):
        pages = read(PAGES)
        editor = read(EDITOR)
        # The editor confirms every destructive or confirm-flagged action with its message,
        # and every list delete with the section's message.
        self.assertIn("if (field.confirm || field.destructive) {", editor)
        self.assertIn("[self confirmTitle:field.title message:field.confirmMessage then:action];",
                      editor)
        commit = method(editor, "- (void)tableView:(UITableView *)tableView commitEditingStyle:")
        self.assertIn("section.deleteMessage ? section.deleteMessage(index) : nil", commit)
        self.assertLess(commit.index("[self confirmTitle:field.title message:message then:^{"),
                        commit.index("section.onDelete(index)"))

        # The shared helper marks the action destructive and carries the consequence.
        danger = method(pages, "- (DBEditField *)danger:(NSString *)title")
        self.assertIn("field.destructive = YES;", danger)
        self.assertIn("field.confirmMessage = message;", danger)
        # No destructive row is left without a consequence.
        for match in re.finditer(r"(\w+)\.destructive = YES;\n\s*(.*)\n", pages):
            self.assertIn("%s.confirmMessage = " % match.group(1), match.group(2),
                          pages[match.start():match.end()])

        # The specific actions whose loss is largest.
        security = method(pages, "- (DBEditPage *)clusterSecurityPage {")
        rebuild = security[security.index('"security.rebuild"'):security.index("dangerZone")]
        self.assertIn('message:[pages t:@"security.rebuild_confirm"]', rebuild)
        # Rebuilding always asks for the administrator password again.
        self.assertLess(rebuild.index("inner->_http = nil;"),
                        rebuild.index('path:@"/api/pairing/rebuild"'))
        self.assertIn('message:[pages t:@"admin.rotate_confirm"]', security)

        asset_page = method(pages, "- (DBEditPage *)assetPage:(NSString *)hash {")
        self.assertIn("message:[pages assetDeleteMessage:hash]", asset_page)
        assets = method(pages, "- (DBEditPage *)assetsPage:(NSString *)typePrefix {")
        self.assertIn("section.deleteMessage = ", assets)
        message = method(pages, "- (NSString *)assetDeleteMessage:(NSString *)hash {")
        self.assertIn("assetReferencesInConfig:", message)
        self.assertIn('"settings.asset_delete_in_use"', message)

        raw = method(pages, "- (void)writeRawKey:(NSString *)key json:(NSString *)json")
        self.assertLess(raw.index("[_editor confirmTitle:key"), raw.index("setKey:key value:value"))
        raw_page = method(pages, "- (DBEditPage *)rawConfigPage {")
        self.assertIn("section.deleteMessage = ", raw_page)
        self.assertNotIn("setKey:", raw_page)

        for signature, key in (
                ("- (DBEditPage *)playbackProfilePage:", "editor.pair_delete_confirm"),
                ("- (DBEditPage *)capabilityPage:", "editor.caps_clear_confirm"),
                ("- (DBEditPage *)uiElementPage:", "editor.ui_element_reset_confirm"),
                ("- (DBEditPage *)themeScopePage:", "editor.theme_reset_confirm"),
                ("- (DBEditPage *)telegramPage {", "editor.telegram_disable_confirm")):
            self.assertIn('"%s"' % key, method(pages, signature), key)

    def test_secrets_reach_configuration_only_as_references(self):
        pages = read(PAGES)
        # Single-key writes all pass through commit:, whose only direct Core write is the
        # fallback for a Core without the batch export.
        self.assertEqual(pages.count("setConfigKey:"), 1)
        self.assertIn("[_core setConfigKey:key valueJson:DBJsonFragment(",
                      method(pages, "- (BOOL)commit:(NSArray *)ops {"))

        store = method(pages, "- (BOOL)storeSecret:(NSString *)value base:(NSString *)base")
        self.assertLess(store.index("[_core storeSecret:name value:secret]"),
                        store.index('setKey:key value:[@"secret:" stringByAppendingString:name]'))
        self.assertNotIn("value:secret]", store.replace("[_core storeSecret:name value:secret]", ""))
        helper = method(pages, "- (DBEditField *)secret:(NSString *)title key:(NSString *)key")
        self.assertIn("storeSecret:[value description] base:base key:key", helper)

        # Every secret field stores before it writes, and writes a reference.
        blocks = re.findall(
            r"kind:DBEditKindSecret[^;]*;(?:(?!DBEditKind)(?:.|\n)){0,300}?"
            r"\.onChange = \^BOOL\(id value\) \{(?:.|\n)*?\n\s*\};", pages)
        self.assertGreaterEqual(len(blocks), 4)
        for block in blocks:
            self.assertNotRegex(block, r"setKey:[^\n]*value:(secret|token|\[value description\])\]")
            if "/api/panel-token/provision" in block:
                # The legacy token goes to Core's secure store over loopback, never to config.
                self.assertNotIn("setKey:", block)
                self.assertNotIn("commit:", block)
                continue
            self.assertIn("storeSecret:", block)
            if "_core storeSecret:" in block:
                self.assertIn('@"secret:" stringByAppendingString:name', block)

        web_push = method(pages, "- (DBEditPage *)webPushPage {")
        self.assertIn('key:[w stringByAppendingString:@"vapid_private_key_ref"]', web_push)
        self.assertIn('storeSecret:text base:@"webpush.sender" key:bearerKey', web_push)
        self.assertIn("secure:YES", web_push)

        speech = method(pages, "- (DBEditPage *)speechPage {")
        self.assertLess(speech.index("[inner->_core storeSecret:name value:secret]"),
                        speech.index('[inner set:keyRef value:[@"secret:" stringByAppendingString:name]]'))
        self.assertIn('[inner set:@"speech.generator_node" value:inner.nodeId]', speech)

        # The raw key writer refuses a plain value under a reference key before it confirms.
        self.assertIn('if (![key hasSuffix:@"_ref"] || ![value isKindOfClass:[NSString class]]) '
                      'return YES;', pages)
        self.assertIn('[(NSString *)value hasPrefix:@"secret:"]', pages)
        raw = method(pages, "- (void)writeRawKey:(NSString *)key json:(NSString *)json")
        self.assertLess(raw.index("if (!DBRawValueAllowed(key, value)) {"),
                        raw.index("[_editor confirmTitle:key"))

    def test_http_is_loopback_only_and_limited_to_known_routes(self):
        pages = read(PAGES)
        editor = read(EDITOR)
        # The login itself lives in DBAdminHttpSession, opened by withSession: with a password
        # typed for that operation; the pages never build it.
        self.assertNotIn("api/login", pages)
        self.assertNotIn("api/config", pages)
        self.assertNotIn("http", editor.lower().replace("https://", ""))
        self.assertEqual(pages.count("[DBAdminHttpSession openWithPassword:"), 1)
        self.assertIn("[DBAdminHttpSession openWithPassword:",
                      method(pages, "- (void)withSession:"))
        routes = set(re.findall(r'@"(/api/[A-Za-z0-9/_-]+)', pages))
        self.assertEqual(routes - ALLOWED_ROUTES, set())
        # Every new route rides the same session helper.
        admin_request = method(pages, "- (void)adminRequest:(NSString *)method")
        self.assertIn("[self withSession:^(DBAdminHttpSession *session) {", admin_request)
        self.assertEqual(pages.count("[session request:"), 2)

        # The one direct request is the public asset route on this device, off the main thread.
        self.assertEqual(pages.count("NSURLConnection"), 1)
        fetch = method(pages, "- (void)fetchAsset:(NSString *)hash")
        self.assertIn('@"http://127.0.0.1:%ld/asset/%@"', fetch)
        self.assertLess(fetch.index("if (!DBSafeId(hash))"), fetch.index("URLWithString"))
        self.assertLess(fetch.index("dispatch_get_global_queue"), fetch.index("NSURLConnection"))
        urls = set(re.findall(r'@"(https?://[^"]*)"', pages))
        self.assertEqual({url for url in urls if not url.startswith("http://127.0.0.1:")
                          and url not in ("http://", "https://")
                          and not url.startswith("https://%@:47443/panel/")
                          and not url.startswith("http://192.0.2.")}, set())

        # Thumbnails are decoded away from the main thread.
        thumbnail = method(pages, "- (void)loadThumbnail:(NSString *)hash {")
        self.assertLess(thumbnail.index("dispatch_get_global_queue"),
                        thumbnail.index("[UIImage imageWithData:data]"))

    def test_no_modal_presentation_and_foundation_only_logic(self):
        for path in (PAGES, EDITOR):
            source = read(path)
            self.assertNotIn("presentViewController", source, path)
            self.assertNotIn("presentModalViewController", source, path)
        logic = read(LOGIC) + read("ios-kiosk/src/Core/DBSettingsLogic.h")
        self.assertNotIn("UIKit", logic)
        self.assertIn("#import <Foundation/Foundation.h>", logic)

    def test_admin_defined_lists_have_native_rows(self):
        admin = read(ADMIN)
        pages = read(PAGES)
        logic = read(LOGIC)
        strings = read("i18n/strings.yaml")

        # Text ink: one row per region the admin offers.
        theme = method(pages, "- (DBEditPage *)themeScopePage:(NSString *)device {")
        regions = js_string_array(admin, "INK_REGIONS")
        self.assertGreaterEqual(len(regions), 7)
        for region in regions:
            self.assertIn('@"%s"' % region, theme, region)
            self.assertRegex(strings, r"(?m)^theme\.region_%s: " % re.escape(region))
        for leaf in (".backdrop.", '@"enabled"', '@"color"', '@"opacity"', ".glass.blur_radius",
                     ".call_button_bg", ".bg_image", ".bg_color", ".ink_override."):
            self.assertIn(leaf, theme, leaf)

        # Per-element overrides: every property, with a label.
        properties = js_string_array(admin, "UI_PROPERTIES")
        for name in properties:
            self.assertIn('@"%s"' % name, logic, name)
            self.assertRegex(strings, r"(?m)^editor\.ui_prop_%s: " % re.escape(name))

        # Playback strategies and their default timeouts.
        defaults = admin[admin.index("function defaultPlaybackProfile()"):
                         admin.index("function normalizePlaybackProfile(")]
        strategies = re.findall(
            r'id: "([a-z0-9_]+)", enabled: (true|false), startup_timeout_ms: (\d+), '
            r"stall_timeout_ms: (\d+)", defaults)
        self.assertEqual(len(strategies), 3)
        native = method(logic, "static NSArray *DBLDefaultStrategies(void) {") \
            if "static NSArray *DBLDefaultStrategies(void) {" in logic else logic
        compact = re.sub(r"\s+", " ", native)
        for identifier, enabled, startup, stall in strategies:
            self.assertIn(
                '@"id" : @"%s", @"enabled" : @%s, @"startup_timeout_ms" : @%s, '
                '@"stall_timeout_ms" : @%s' % (identifier, "YES" if enabled == "true" else "NO",
                                              startup, stall), compact, identifier)
            self.assertIn('isEqualToString:@"%s"]' % identifier,
                          method(pages, "- (NSString *)strategyLabel:(NSString *)identifier {"))

        # Web Push: every key the admin writes.
        entries = admin[admin.index("function webPushEntries(f)"):admin.index("function sipEntries(f)")]
        keys = re.findall(r'key: "integrations\.web_push\.([a-z_]+)"', entries)
        self.assertGreaterEqual(len(keys), 5)
        web_push = method(pages, "- (DBEditPage *)webPushPage {")
        for key in keys:
            self.assertIn('@"%s"' % key, web_push, key)

        # Per-device keys the admin's device editor writes under devices.<id>.local.
        device_entries = admin[admin.index("if (isObj(f.caps_override))") - 4000:
                               admin.index("if (isObj(f.caps_override))")]
        local = method(pages, "- (NSArray *)deviceLocalSections:(NSString *)device {")
        leaves = set(re.findall(r'base \+ "\.local\.([a-z_.]+)"', device_entries))
        self.assertTrue({"ui_lang", "video.playback", "video.rotation"} <= leaves, leaves)
        for leaf in leaves:
            if leaf in ("camera", "motion"):
                continue  # written leaf by leaf below, like the other native shells
            self.assertIn('key(@"%s")' % leaf, local, leaf)
        for member in re.findall(r"(?:camera|motion)\.([a-z0-9_]+) = ", device_entries):
            self.assertRegex(local, r'@"(camera|motion)\.%s"' % member)

    def test_every_string_key_the_pages_use_exists(self):
        strings = set(re.findall(r"(?m)^([A-Za-z0-9_.]+): \{", read("i18n/strings.yaml")))
        pages = read(PAGES)
        used = set(re.findall(r'\bts?:\(?@"([a-z0-9_.]+)"', pages))
        used |= set(re.findall(r'toast:@"([a-z0-9_.]+)"', pages))
        used |= set(re.findall(r'[?:] @"((?:editor|admin|settings|security|theme|speech|power'
                               r'|panels|purpose|prefs)\.[a-z0-9_]+)"', pages))
        missing = sorted(key for key in used
                         if key not in strings and not key.endswith(("_", ".")))
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
