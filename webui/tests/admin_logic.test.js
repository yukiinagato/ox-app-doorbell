"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

// Every literal Admin translation key must come from the generated catalog. This keeps new UI
// paths from silently falling back to a single language when English or Chinese is selected.
const adminSource = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
const literalTranslationKeys = new Set();
for (const match of adminSource.matchAll(/\bt\(\s*["']([^"']+)["']/g)) {
  if (match[1] !== "day.") literalTranslationKeys.add(match[1]);
}
for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  for (const key of literalTranslationKeys)
    assert.ok(Object.prototype.hasOwnProperty.call(catalog, key), language + " missing " + key);
}

for (const role of ["door_station", "indoor_panel"]) {
  const manifest = L.defaultUiManifest(role);
  assert.strictEqual(L.validateUiManifest(manifest).ok, true);
  assert.strictEqual(manifest.elements["call.primary"].defaults.scale, 1);
}

for (const units of ["logical", "dp", "pt", "effective_px"]) {
  const platformManifest = L.defaultUiManifest("door_station");
  platformManifest.units = units;
  assert.strictEqual(L.validateUiManifest(platformManifest).ok, true);
}

const badManifest = L.defaultUiManifest("door_station");
badManifest.elements["call.primary"].properties.push("visible");
assert.strictEqual(L.validateUiManifest(badManifest).ok, false);
const extraManifestField = L.defaultUiManifest("door_station");
extraManifestField.style = { preset: "legacy" };
assert.strictEqual(L.validateUiManifest(extraManifestField).ok, false);
const extraDescriptorField = L.defaultUiManifest("door_station");
extraDescriptorField.elements["call.primary"].visible = true;
assert.strictEqual(L.validateUiManifest(extraDescriptorField).ok, false);
const missingDefaults = L.defaultUiManifest("door_station");
delete missingDefaults.elements["call.primary"].defaults;
assert.strictEqual(L.validateUiManifest(missingDefaults).ok, false);
const incompleteDefaults = L.defaultUiManifest("door_station");
delete incompleteDefaults.elements["call.primary"].defaults.background;
assert.strictEqual(L.validateUiManifest(incompleteDefaults).ok, false);
// Contrast is advisory now: a manifest whose own defaults are hard to read is accepted and
// reported, exactly like an operator's custom colour.
const unsafeDefaults = L.defaultUiManifest("door_station");
unsafeDefaults.elements["call.primary"].defaults.foreground = "#111111";
const unsafeChecked = L.validateUiManifest(unsafeDefaults);
assert.strictEqual(unsafeChecked.ok, true);
assert.ok(unsafeChecked.warnings.length >= 1);
assert.strictEqual(unsafeChecked.warnings[0].message_key, "theme.low_contrast");

const manifest = L.defaultUiManifest("door_station");
assert.strictEqual(L.validateUiElementOverride(manifest, "call.primary", {
  scale: 1.1, font_scale: 1.2, foreground: "#ffffff", background: "#101418",
  accent: "#4da3ff", border: "#4da3ff", radius: 12
}).ok, true);
assert.strictEqual(L.validateUiElementOverride(manifest, "call.primary", { visible: false }).ok, false);
assert.strictEqual(L.validateUiElementOverride(manifest, "call.primary", { scale: "1.1" }).ok, false);
assert.strictEqual(L.validateUiElementOverride(manifest, "call.primary", { radius: Infinity }).ok, false);
assert.strictEqual(L.validateUiElementOverride(manifest, "cancel.call", { scale: 0.9 }).ok, false);
assert.strictEqual(L.validateUiElementOverride(manifest, "cancel.call", { font_scale: 0.9 }).ok,
                   false);
// A low-contrast override saves and reports the measured ratio; only the format is enforced.
const lowContrast = L.validateUiElementOverride(manifest, "call.primary", {
  foreground: "#111111", background: "#101418"
});
assert.strictEqual(lowContrast.ok, true);
assert.strictEqual(lowContrast.errors.length, 0);
assert.strictEqual(lowContrast.warnings.length, 1);
assert.strictEqual(lowContrast.warnings[0].property, "foreground");
assert.strictEqual(lowContrast.warnings[0].message_key, "theme.low_contrast");
assert.ok(lowContrast.warnings[0].contrast < 4.5);
// The check uses the resolved element, so a single-property override is measured against the
// manifest default it will sit on.
const resolvedAgainstDefault = L.validateUiElementOverride(manifest, "call.primary", {
  foreground: "#1a2027"
});
assert.strictEqual(resolvedAgainstDefault.ok, true);
assert.ok(resolvedAgainstDefault.warnings.length >= 1);
// Format is still refused outright.
assert.strictEqual(L.validateUiElementOverride(manifest, "call.primary", {
  foreground: "not-a-colour"
}).ok, false);
assert.deepStrictEqual(L.uiElementValue({ call: { primary: { scale: 1.2 } } }, "call.primary"),
                       { scale: 1.2 });
const preview = L.uiPreviewModel(manifest, { "call.primary": { scale: 1.2 } });
assert.strictEqual(preview.minimum_touch, 44);
assert.strictEqual(preview.elements.find(e => e.id === "call.primary").style.scale, 1.2);
assert.strictEqual(preview.elements.find(e => e.id === "call.primary").style.foreground,
                   "#e8edf2");

const changes = L.uiElementChanges("dev", manifest, {
  "call.primary": { scale: 1.2 }, "status.offline": {}
});
assert.deepStrictEqual(changes.entries, [{
  key: "devices.dev.local.ui.elements.call.primary", value: { scale: 1.2 }
}]);
assert.deepStrictEqual(changes.dels, ["devices.dev.local.ui.elements.status.offline"]);

const raw = { nested: [1, true, null, { x: "y" }] };
const ops = L.configBatchOps([{ key: "custom.payload", value: raw }], ["custom.old"]);
assert.deepStrictEqual(ops, [
  { op: "set", key: "custom.payload", value: raw },
  { op: "delete", key: "custom.old" }
]);
assert.strictEqual(typeof ops[0].value, "object"); // no double JSON stringification
assert.throws(() => L.configBatchOps([{ key: "same", value: 1 }], ["same"]), /duplicate/);
assert.throws(() => L.configBatchOps([{
  key: "devices.dev.local.ui.style", value: { text_scale: 1 }
}], []), /elements/);
assert.throws(() => L.configBatchOps([{
  key: "devices.dev.local.ui.elements.call.primary", value: { visible: false }
}], []), /unsupported/);
assert.throws(() => L.configBatchOps([{
  key: "devices.dev.local.ui.elements.call.primary.scale", value: 1.2
}], []), /object/);

const imported = L.flattenConfig({ devices: { dev: { local: { ui: { elements: {
  call: { primary: { scale: 1.2 } }, status: { offline: { foreground: "#ffffff" } }
} } } } } });
assert.deepStrictEqual(imported, [
  { key: "devices.dev.local.ui.elements.call.primary", value: { scale: 1.2 } },
  { key: "devices.dev.local.ui.elements.status.offline", value: { foreground: "#ffffff" } }
]);
assert.doesNotThrow(() => L.configBatchOps(imported, []));

const device = L.deviceEntries("dev", {
  name: "Panel", role: "indoor_panel", helper_mode: "on"
});
assert.deepStrictEqual(device.find(e => e.key ===
  "devices.dev.local.recovery.helper_mode"), {
    key: "devices.dev.local.recovery.helper_mode", value: "on"
  });
const normalizedDevice = L.deviceEntries("dev", {
  role: "indoor_panel", helper_mode: "arbitrary"
});
assert.strictEqual(normalizedDevice.find(e => e.key ===
  "devices.dev.local.recovery.helper_mode").value, "auto");
assert.throws(() => L.deviceEntries("dev", {
  name: "Door", role: "door_station", door: ""
}), /door_required/);
assert.throws(() => L.deviceEntries("dev", {
  name: "Door", role: "door_station", door: "bad door"
}), /door_required/);
assert.throws(() => L.deviceEntries("dev", {
  name: "Door", role: "unexpected", door: "front"
}), /role_invalid/);
const trimmedDoor = L.deviceEntries("dev", {
  name: "Door", role: "door_station", door: "  front  "
});
assert.strictEqual(trimmedDoor.find(e => e.key === "devices.dev.door").value, "front");
assert.strictEqual(L.validDoorId("front-door_1"), true);
assert.strictEqual(L.validDoorId("_front"), false);
assert.strictEqual(L.defaultDoorId("75a2822c-ignored"), "door-75a2822c");
assert.strictEqual(L.validDoorId(L.defaultDoorId("")), true);
const indoorWithoutDoor = L.deviceEntries("dev", {
  name: "Panel", role: "indoor_panel", door: "stale-door"
});
assert.strictEqual(indoorWithoutDoor.find(e => e.key === "devices.dev.door").value, "");

const existingBuilding = {
  label: { ja: "Old", en: "Old English", fr: "Maison" },
  future: { access: { zone: 4 } }
};
const editedBuilding = L.buildingEntries("main", {
  ja: "New", en: "", zh: "新館"
}, existingBuilding)[0].value;
assert.deepStrictEqual(editedBuilding, {
  label: { ja: "New", fr: "Maison", zh: "新館" },
  future: { access: { zone: 4 } }
});
assert.strictEqual(existingBuilding.label.ja, "Old");

const editedDoor = L.doorEntries("front", {
  ja: "Front", en: "", zh: "", building: ""
}, {
  label: { ja: "Old front", it: "Ingresso" }, building: "old-building",
  future: { lock: { protocol: 3 } }
})[0].value;
assert.deepStrictEqual(editedDoor.label, { ja: "Front", it: "Ingresso" });
assert.strictEqual(Object.prototype.hasOwnProperty.call(editedDoor, "building"), false);
assert.deepStrictEqual(editedDoor.future, { lock: { protocol: 3 } });

const editedReply = L.quickReplyEntries("wait", {
  ja: "Wait", en: "", zh: "", speak: true, order: 8, audio: { ja: "new-audio" }
}, {
  label: { ja: "Old", de: "Bitte warten" }, speak: false, order: 2,
  audio: { ja: "old-audio", de: "future-audio" },
  future_delivery: { retry: { count: 2 } }
})[0].value;
assert.deepStrictEqual(editedReply.label, { ja: "Wait", de: "Bitte warten" });
assert.deepStrictEqual(editedReply.audio, { ja: "new-audio", de: "future-audio" });
assert.deepStrictEqual(editedReply.future_delivery, { retry: { count: 2 } });
assert.strictEqual(editedReply.speak, true);
assert.strictEqual(editedReply.order, 8);

const repliesBeforeReorder = {
  wait: { label: { pt: "Espere" }, speak: false, order: 9,
          future: { routing: ["lobby"] } }
};
const reorderedReply = L.reorderEntries(["wait"], repliesBeforeReorder)[0].value;
assert.deepStrictEqual(reorderedReply, {
  label: { pt: "Espere" }, speak: false, order: 1,
  future: { routing: ["lobby"] }
});
assert.strictEqual(repliesBeforeReorder.wait.order, 9);

const editedHousehold = L.householdEntries("owners", {
  ja: "Owners", en: "", zh: "", chat_ids: "12, -13", sip_ext: "201"
}, {
  label: { ja: "Old owners", es: "Propietarios" },
  telegram_chat_ids: [1], sip_extensions: ["100"],
  future: { escalation: { after_s: 30 } }
})[0].value;
assert.deepStrictEqual(editedHousehold.label, { ja: "Owners", es: "Propietarios" });
assert.deepStrictEqual(editedHousehold.telegram_chat_ids, [12, -13]);
assert.deepStrictEqual(editedHousehold.sip_extensions, ["201"]);
assert.deepStrictEqual(editedHousehold.future, { escalation: { after_s: 30 } });

const existingDevice = { local: {
  camera: { device_hint: "old", future_codec: { profile: "av1" },
            calibration: { matrix: [1, 2, 3] } },
  motion: { enabled: false, zones: [{ id: "porch", threshold: 7 }],
            future_filter: { model: "v2" } }
} };
const editedDeviceEntries = L.deviceEntries("dev", {
  name: "Panel", role: "door_station", door: "front", ui_lang: "en",
  helper_mode: "auto", video_playback: "low_latency", video_rotation: "90",
  cam_hint: "new", cam_fps: 9, cam_quality: 70, cam_resolution: "800x600",
  cam_codec: "h264", cam_h264_resolution: "640x360", cam_h264_fps: 24,
  cam_h264_bitrate: 900, motion_enabled: true, motion_sensitivity: 55,
  motion_interval: 15
}, existingDevice);
const editedCamera = editedDeviceEntries.find(e =>
  e.key === "devices.dev.local.camera").value;
const editedMotion = editedDeviceEntries.find(e =>
  e.key === "devices.dev.local.motion").value;
assert.strictEqual(editedCamera.device_hint, "new");
assert.deepStrictEqual(editedCamera.future_codec, { profile: "av1" });
assert.deepStrictEqual(editedCamera.calibration, { matrix: [1, 2, 3] });
assert.strictEqual(editedMotion.sensitivity, 55);
assert.deepStrictEqual(editedMotion.zones, [{ id: "porch", threshold: 7 }]);
assert.deepStrictEqual(editedMotion.future_filter, { model: "v2" });
assert.strictEqual(existingDevice.local.camera.device_hint, "old");

const existingQuiet = {
  windows: [
    { from: "20:00", to: "21:00", future: { calendar: "weekday" } },
    { from: "22:00", to: "06:00", days: ["mon", "tue"], future: { zone: "home" } }
  ],
  suppress: ["chime"], never_suppress: [], future_policy: { revision: 4 }
};
const editedQuiet = L.quietEntries({
  windows: [{ from: "23:00", to: "07:00", _existing_index: 1 }],
  suppress: ["sip_call"], never_suppress: ["device_alert"]
}, existingQuiet)[0].value;
assert.deepStrictEqual(editedQuiet.windows, [{
  from: "23:00", to: "07:00", days: ["mon", "tue"], future: { zone: "home" }
}]);
assert.deepStrictEqual(editedQuiet.future_policy, { revision: 4 });
assert.strictEqual(Object.prototype.hasOwnProperty.call(editedQuiet.windows[0],
  "_existing_index"), false);

const globalTheme = L.themeEntries("", {
  bg_color: "#010203", bg_image: "asset:new", color_on: true, image_on: true
}, {
  bg_color: "#ffffff", bg_image: "asset:old", future: { contrast_mode: "adaptive" }
});
assert.deepStrictEqual(globalTheme.entries[0].value.future,
  { contrast_mode: "adaptive" });
assert.deepStrictEqual(globalTheme.entries[1], {
  key: "display.theme.bg_image", value: "asset:new"
});
const globalThemeCleared = L.themeEntries("", {
  bg_color: "#010203", bg_image: "", color_on: true, image_on: true
}, { bg_color: "#ffffff", bg_image: "asset:old" });
assert.deepStrictEqual(globalThemeCleared.dels, ["display.theme.bg_image"]);
assert.strictEqual(Object.prototype.hasOwnProperty.call(
  globalThemeCleared.entries[0].value, "bg_image"), false);
const deviceTheme = L.themeEntries("dev", {
  bg_color: "#010203", bg_image: "", color_on: false, image_on: false
}, { bg_color: "#ffffff", bg_image: "asset:old", future: { palette: ["blue"] } });
assert.deepStrictEqual(deviceTheme.dels, ["devices.dev.local.theme.bg_image"]);
assert.deepStrictEqual(deviceTheme.entries[0].value, { future: { palette: ["blue"] } });
assert.deepStrictEqual(L.themeEntries("dev", {
  color_on: false, image_on: false
}, {}).dels, ["devices.dev.local.theme", "devices.dev.local.theme.bg_image"]);
assert.deepStrictEqual(L.themeEntries("dev", {
  bg_image: "", color_on: false, image_on: true
}, {}).entries, [{ key: "devices.dev.local.theme.bg_image", value: null }]);

const editedPurpose = L.purposeEntries("delivery", {
  ja: "Delivery", en: "", zh: "", icon: "📦", order: 3
}, {
  label: { ja: "Old", ko: "배송" }, icon: "old", order: 1,
  future: { routing: { queue: "packages" } }
})[0].value;
assert.deepStrictEqual(editedPurpose.label, { ja: "Delivery", ko: "배송" });
assert.deepStrictEqual(editedPurpose.future, { routing: { queue: "packages" } });
const reorderedPurpose = L.purposeReorderEntries(["delivery"], {
  delivery: { label: { ko: "배송" }, icon: "📦", order: 9,
              future: { routing: { queue: "packages" } } }
})[0].value;
assert.deepStrictEqual(reorderedPurpose.future, { routing: { queue: "packages" } });
assert.strictEqual(reorderedPurpose.order, 1);

const existingPlayback = {
  future_profile: { decoder_budget: 2 },
  strategies: [
    { id: "future_av1", enabled: true, future: { hardware_only: true } },
    { id: "h264_low_latency", enabled: true, startup_timeout_ms: 300,
      stall_timeout_ms: 3000, future: { jitter_ms: 15 } },
    { id: "mjpeg", enabled: true, startup_timeout_ms: 5000,
      stall_timeout_ms: 3000, future: { prewarm: true } }
  ]
};
const playbackEdit = { strategies: [
  { id: "mjpeg", enabled: true, startup_timeout_ms: 4100, stall_timeout_ms: 3200 },
  { id: "h264_low_latency", enabled: false, startup_timeout_ms: 450, stall_timeout_ms: 3500 },
  { id: "h264_hls", enabled: true, startup_timeout_ms: 700, stall_timeout_ms: 6000 }
] };
const editedGlobalPlayback = L.playbackProfileEntries("", "", playbackEdit,
  existingPlayback)[0];
assert.strictEqual(editedGlobalPlayback.key, "video_playback.global");
assert.deepStrictEqual(editedGlobalPlayback.value.future_profile, { decoder_budget: 2 });
assert.deepStrictEqual(editedGlobalPlayback.value.strategies.map(s => s.id),
  ["future_av1", "mjpeg", "h264_low_latency", "h264_hls"]);
assert.deepStrictEqual(editedGlobalPlayback.value.strategies[0].future,
  { hardware_only: true });
assert.deepStrictEqual(editedGlobalPlayback.value.strategies[1].future, { prewarm: true });
assert.deepStrictEqual(editedGlobalPlayback.value.strategies[2].future, { jitter_ms: 15 });
assert.strictEqual(editedGlobalPlayback.value.strategies[1].startup_timeout_ms, 4100);
const editedPairPlayback = L.playbackProfileEntries("viewer", "source", playbackEdit,
  existingPlayback)[0];
assert.strictEqual(editedPairPlayback.key, "video_playback.pairs.viewer.source");
assert.deepStrictEqual(editedPairPlayback.value.future_profile, { decoder_budget: 2 });
assert.strictEqual(existingPlayback.strategies[1].startup_timeout_ms, 300);

const mqttPlan = L.mqttPlan({ host: "broker", port: 1883, user: "door", pass: "plain" }, {});
assert.strictEqual(/^secret:mqtt\.[0-9a-f]+$/.test(mqttPlan.secrets[0].secret_ref), true);
assert.strictEqual(mqttPlan.secrets[0].value, "plain");
assert.strictEqual(mqttPlan.entries.some(e => e.key === "integrations.mqtt.pass"), false);
assert.strictEqual(mqttPlan.entries.find(e => e.key === "integrations.mqtt.pass_ref").value,
                   mqttPlan.secrets[0].secret_ref);
assert.deepStrictEqual(mqttPlan.retire_secret_refs, []);
const rotatedMqtt = L.mqttPlan({ host: "broker", pass: "replacement" },
                               { pass_ref: "secret:mqtt.old" });
assert.notStrictEqual(rotatedMqtt.secrets[0].secret_ref, "secret:mqtt.old");
assert.deepStrictEqual(rotatedMqtt.retire_secret_refs, ["secret:mqtt.old"]);
const unchangedMqtt = L.mqttPlan({ host: "broker", pass: "" },
                                 { pass_ref: "secret:mqtt.old" });
assert.deepStrictEqual(unchangedMqtt.secrets, []);
assert.strictEqual(unchangedMqtt.entries.find(e => e.key ===
  "integrations.mqtt.pass_ref").value, "secret:mqtt.old");
const localMqttProvision = L.localSecretProvisionPlan("secret:mqtt.old", "same-fleet-secret");
assert.deepStrictEqual(localMqttProvision, {
  entries: [],
  secrets: [{ secret_ref: "secret:mqtt.old", value: "same-fleet-secret" }],
  retire_secret_refs: []
});
assert.deepStrictEqual(
  L.panelProvisionPayload("secret:panel.access.fleet", "one-time-panel-token"),
  { secret_ref: "secret:panel.access.fleet", token: "one-time-panel-token" }
);
assert.strictEqual(L.canEditSipSecret("node-a", "node-a"), true);
assert.strictEqual(L.canEditSipSecret("node-b", "node-a"), false);
assert.strictEqual(L.canEditSipSecret("node-b", ""), false);

const telegramPlan = L.telegramPlan({ bot_token: "123:secret", poll_updates: true },
                                     { unknown: "preserved" });
assert.strictEqual(/^secret:telegram_bot\.[0-9a-f]+$/.test(
  telegramPlan.secrets[0].secret_ref), true);
assert.strictEqual(telegramPlan.secrets[0].value, "123:secret");
assert.strictEqual(telegramPlan.entries.some(e => e.key === "integrations.telegram.bot_token"),
                   false);

const sipPlan = L.sipAccountPlan("node-1", "201", "new-secret", {
  user: "old", pass_ref: "secret:sip.existing", answer_mode: "manual",
  vendor_extension: { enabled: true }
});

const mergedSipPlans = L.mergeSecretPlans([{ key: "sip.server", value: "pbx" }], [
  { entries: [{ key: "sip.accounts.a", value: { pass_ref: "secret:sip.a.new" } }],
    secrets: [{ secret_ref: "secret:sip.a.new", value: "a" }],
    retire_secret_refs: ["secret:sip.a.old"] },
  { entries: [{ key: "sip.accounts.b", value: { pass_ref: "secret:sip.b.new" } }],
    secrets: [{ secret_ref: "secret:sip.b.new", value: "b" }],
    retire_secret_refs: ["secret:sip.b.old"] }
]);
assert.deepStrictEqual(mergedSipPlans.retire_secret_refs,
  ["secret:sip.a.old", "secret:sip.b.old"]);
assert.strictEqual(mergedSipPlans.entries.length, 3);
assert.strictEqual(mergedSipPlans.secrets.length, 2);
assert.strictEqual(/^secret:sip_node_1\.[0-9a-f]+$/.test(sipPlan.secrets[0].secret_ref), true);
assert.strictEqual(sipPlan.secrets[0].value, "new-secret");
assert.deepStrictEqual(sipPlan.entries, [{ key: "sip.accounts.node-1", value: {
  user: "201", pass_ref: sipPlan.secrets[0].secret_ref, answer_mode: "manual",
  vendor_extension: { enabled: true }
} }]);
assert.deepStrictEqual(sipPlan.retire_secret_refs, ["secret:sip.existing"]);
assert.strictEqual(Object.prototype.hasOwnProperty.call(sipPlan.entries[0].value, "pass"), false);

const webPushPlan = L.webPushPlan({
  sender_url: "https://push.example/send",
  vapid_public_key: "public-key",
  vapid_subject: "mailto:doorbell@example.com",
  vapid_private_key: "new-private",
  sender_bearer_enabled: true,
  sender_secret: "new-bearer"
}, {
  vapid_private_key_ref: "secret:webpush.vapid.old",
  sender_secret_ref: "secret:webpush.sender.old"
});
assert.strictEqual(webPushPlan.entries.length, 5);
assert.strictEqual(webPushPlan.secrets.length, 2);
assert.strictEqual(/^secret:webpush_vapid_private\.[0-9a-f]+$/.test(
  webPushPlan.secrets[0].secret_ref), true);
assert.strictEqual(/^secret:webpush_sender\.[0-9a-f]+$/.test(
  webPushPlan.secrets[1].secret_ref), true);
assert.deepStrictEqual(webPushPlan.retire_secret_refs,
  ["secret:webpush.vapid.old", "secret:webpush.sender.old"]);
assert.strictEqual(webPushPlan.entries[3].value, webPushPlan.secrets[0].secret_ref);
assert.strictEqual(webPushPlan.entries[4].value, webPushPlan.secrets[1].secret_ref);

const webPushProvisionOnly = L.webPushPlan({
  sender_url: "https://push.example/send",
  vapid_public_key: "public-key",
  vapid_subject: "mailto:doorbell@example.com",
  vapid_private_key: "",
  sender_bearer_enabled: false,
  sender_secret: ""
}, {
  vapid_private_key_ref: "secret:webpush.vapid.current",
  sender_secret_ref: "secret:webpush.sender.current"
});
assert.strictEqual(webPushProvisionOnly.secrets.length, 0);
assert.strictEqual(webPushProvisionOnly.entries[3].value,
  "secret:webpush.vapid.current");
assert.strictEqual(webPushProvisionOnly.entries[4].value, "");
assert.deepStrictEqual(webPushProvisionOnly.retire_secret_refs,
  ["secret:webpush.sender.current"]);

const seededSosOn = {
  enabled: true,
  when: { type: "emergency_on" },
  actions: [
    {
      type: "device_alert",
      targets: { roles: "all", web_profiles: "all" },
      channels: ["in_app", "system_notification", "web_push"],
      never_suppress: true,
      presentation: { visual: true, sticky: true, ttl_s: 0 }
    },
    { type: "telegram", never_suppress: true, households: "all" }
  ]
};
const seededSosOff = {
  enabled: true,
  when: { type: "emergency_off" },
  actions: [
    {
      type: "device_alert",
      targets: { roles: "all", web_profiles: "all" },
      channels: ["in_app", "system_notification", "web_push"],
      never_suppress: true,
      presentation: { visual: true, sticky: false, ttl_s: 10 }
    },
    { type: "telegram", never_suppress: true, households: "all" }
  ]
};
for (const [id, seeded] of [["r_sos_default_on", seededSosOn],
                            ["r_sos_default_off", seededSosOff]]) {
  const editor = L.normalizeRuleEditor(seeded);
  assert.deepStrictEqual(L.ruleEntries(id, editor, seeded), [
    { key: "trigger_rules." + id, value: seeded }
  ]);
}

const extendedRule = {
  enabled: true,
  vendor_rule: { revision: 7 },
  when: { type: "emergency_on", vendor_match: ["x"] },
  schedule: { always: true, timezone_ref: "building" },
  actions: [
    {
      type: "device_alert",
      targets: {
        devices: ["panel-a"], roles: ["indoor_panel"],
        web_subscription_groups: ["guards"], vendor_selector: true
      },
      channels: ["in_app", "web_push"], never_suppress: true,
      presentation: { visual: true, sound: "siren1", volume: 90, sticky: true, ttl_s: 0,
                      vendor_color: "red" },
      vendor_delivery: { retries: 2 }
    },
    { type: "future_satellite_alert", opaque: { protocol: 3 } }
  ]
};
const editedExtended = L.normalizeRuleEditor(extendedRule);
editedExtended.actions[0].presentation.volume = 70;
const mergedExtended = L.mergeRuleEditor(extendedRule, editedExtended);
assert.strictEqual(mergedExtended.actions[0].presentation.volume, 70);
assert.deepStrictEqual(mergedExtended.vendor_rule, extendedRule.vendor_rule);
assert.deepStrictEqual(mergedExtended.when.vendor_match, ["x"]);
assert.strictEqual(mergedExtended.schedule.timezone_ref, "building");
assert.strictEqual(mergedExtended.actions[0].targets.vendor_selector, true);
assert.strictEqual(mergedExtended.actions[0].presentation.vendor_color, "red");
assert.deepStrictEqual(mergedExtended.actions[0].vendor_delivery, { retries: 2 });
assert.deepStrictEqual(mergedExtended.actions[1], extendedRule.actions[1]);
const partialMerge = L.mergeRuleEditor(extendedRule, { enabled: false });
assert.strictEqual(partialMerge.enabled, false);
assert.deepStrictEqual(Object.assign({}, partialMerge, { enabled: true }), extendedRule);

const oldRule = {
  when: { type: "button", doors: ["legacy-door"], purposes: ["delivery"] },
  actions: [{ type: "chime", sound: "legacy-tone", vendor_gain: 4 }],
  old_extension: true
};
assert.deepStrictEqual(L.mergeRuleEditor(oldRule, L.normalizeRuleEditor(oldRule)), oldRule);

const unavailableStatus = {
  peers: [
    { id: "panel-a", role: "indoor_panel", status: "alive",
      caps: { device_alert_channels: ["in_app", "system_notification"] } },
    { id: "panel-b", role: "indoor_panel", status: "dead",
      caps: { device_alert_channels: ["in_app"], device_alert_channel_support: {
        channels: { in_app: { supported: true, available: false, permission: "denied" } }
      } } }
  ],
  web_push: { subscriptions: 0, delivery_backend: false }
};
const targetedRule = {
  enabled: true,
  when: { type: "emergency_on" },
  actions: [{
    type: "device_alert",
    targets: { devices: ["panel-b", "missing"], roles: ["indoor_panel"],
               web_subscription_groups: ["guards"] },
    channels: ["in_app", "web_push"],
    presentation: { visual: true, sound: "siren1", volume: 100, sticky: true, ttl_s: 0 }
  }]
};
const targetedPreview = L.sosDryRunPreview(targetedRule, unavailableStatus, {});
assert.deepStrictEqual(targetedPreview.target_devices, ["panel-b", "missing"]);
assert.deepStrictEqual(targetedPreview.target_roles, ["indoor_panel"]);
assert.deepStrictEqual(targetedPreview.target_web_subscription_groups, ["guards"]);
assert.deepStrictEqual(targetedPreview.offline_devices, ["panel-b", "missing"]);
assert.strictEqual(targetedPreview.local_recipients, 2);
assert.strictEqual(targetedPreview.capable_local_recipients, 1);
assert.deepStrictEqual(targetedPreview.unavailable_device_channels, ["panel-b:in_app"]);
assert.strictEqual(targetedPreview.web_push_recipients, 0);
assert.deepStrictEqual(L.sosRuleWarnings(targetedRule, unavailableStatus, {}).map(w => w.code),
  ["no_web_push_subscriptions", "web_push_backend_unavailable", "offline_devices",
   "unavailable_device_channels"]);

const unsupportedChannelRule = {
  when: { type: "emergency_on" },
  actions: [{ type: "device_alert", targets: { devices: ["panel-b"] },
              channels: ["system_notification"] }]
};
const unsupportedPreview = L.sosDryRunPreview(unsupportedChannelRule, unavailableStatus, {});
assert.strictEqual(unsupportedPreview.local_recipients, 1);
assert.strictEqual(unsupportedPreview.capable_local_recipients, 0);
assert.deepStrictEqual(unsupportedPreview.unsupported_device_channels,
  ["panel-b:system_notification"]);
assert.deepStrictEqual(L.sosRuleWarnings(unsupportedChannelRule, unavailableStatus, {}).map(w => w.code),
  ["offline_devices", "unsupported_device_channels"]);

const webOnlyPreview = L.sosDryRunPreview({
  when: { type: "emergency_on" },
  actions: [{ type: "device_alert", targets: { web_subscription_groups: ["guards"] },
              channels: ["web_push"] }]
}, unavailableStatus, {});
assert.strictEqual(webOnlyPreview.local_recipients, 0);
assert.deepStrictEqual(webOnlyPreview.actions[0].matched_devices, []);

const nativeOnlyPushPreview = L.sosDryRunPreview({
  when: { type: "emergency_on" },
  actions: [{ type: "device_alert", targets: { roles: ["indoor_panel"] },
              channels: ["web_push"] }]
}, { peers: [], web_push: { subscriptions: 3, delivery_backend: true } }, {
  web_push: { subscriptions: { one: { group: "all" }, two: { group: "guards" } } }
});
assert.strictEqual(nativeOnlyPushPreview.web_push_recipients, 0);
assert.deepStrictEqual(nativeOnlyPushPreview.target_web_subscription_groups, []);

const zeroSilentRule = {
  when: { type: "emergency_on" },
  actions: [{
    type: "device_alert",
    targets: { devices: [], roles: [], web_subscription_groups: [] },
    channels: [],
    presentation: { visual: false, sound: "", volume: 0, sticky: false, ttl_s: 1 }
  }]
};
assert.deepStrictEqual(L.sosRuleWarnings(zeroSilentRule, unavailableStatus, {}).map(w => w.code),
  ["zero_recipients", "all_channels_silent"]);

const noAlertWarnings = L.sosRuleWarnings(
  { when: { type: "emergency_off" }, actions: [{ type: "future_action" }] },
  unavailableStatus, {});
assert.deepStrictEqual(noAlertWarnings.map(w => w.code),
  ["no_device_alert", "zero_recipients", "all_channels_silent"]);
const legacyAlertRule = {
  when: { type: "emergency_on" },
  actions: [{ type: "device_alert", targets: { roles: "all" } }]
};
assert.deepStrictEqual(L.effectiveAlertChannels(legacyAlertRule.actions[0]), ["in_app"]);
assert.deepStrictEqual(L.sosRuleWarnings(legacyAlertRule, {
  peers: [{ id: "panel-a", role: "indoor_panel", status: "alive",
            caps: { device_alert_channels: ["in_app"] } }]
}, {}), []);

assert.strictEqual(L.callFlowMode({ mode: "ring_then_purpose" }), "ring_then_purpose");
assert.strictEqual(L.callFlowMode("unsupported"), "purpose_first");
const mixedFlow = L.callFlowCompatibility("ring_then_purpose", {
  features: { call_flow_v2: true },
  peers: [
    { id: "self", self: true },
    { id: "new", features: { call_flow_v2: true } },
    { id: "old", features: {} }
  ]
});
assert.deepStrictEqual(mixedFlow.supported, ["self", "new"]);
assert.deepStrictEqual(mixedFlow.unsupported, ["old"]);
assert.strictEqual(mixedFlow.warning, true);
assert.strictEqual(L.callFlowCompatibility("purpose_first", {}).warning, false);
assert.deepStrictEqual(L.webSosEntries(true), [
  { key: "emergency.web_active_page_alerts", value: true }
]);
assert.deepStrictEqual(L.webSosEntries(false), [
  { key: "emergency.web_active_page_alerts", value: false }
]);
assert.strictEqual(L.validateAlertPresentation({
  background: "#101418", foreground: "#FFFFFF", accent: "#4DA3FF"
}).ok, true);
assert.strictEqual(L.validateAlertPresentation({
  background: "#101418", foreground: "#111111", accent: "#4DA3FF"
}).ok, false);

assert.deepStrictEqual(L.runtimeHealthRows({
  generation: 3, heartbeat_ms: 1700000000000, safe_mode: false,
  process_recovery: { last_exit_reason: "native_crash" },
  recovery_helper: { effective: "helper_degraded" },
  components: { media: "low_resolution_mjpeg" },
  device_alert: { result: "permission_denied" }
}), [
  { key: "safe_mode", value: "off", severity: "ok" },
  { key: "helper", value: "helper_degraded", severity: "err" },
  { key: "codec", value: "low_resolution_mjpeg", severity: "ok" },
  { key: "last_exit", value: "native_crash", severity: "" },
  { key: "alert", value: "permission_denied", severity: "warn" },
  { key: "heartbeat", value: "g3 @1700000000000", severity: "" }
]);

assert.deepStrictEqual(L.runtimeHealthRows({
  media_playback: {
    state: "playing", transport: "fmp4_direct", compositor: "uikit_bgra_sibling",
    decoded_frames: 326, displayed_frames: 325, dropped_frames: 1
  }
}), [
  { key: "codec",
    value: "playing / fmp4_direct / uikit_bgra_sibling / frames=325/326 / drop=1",
    severity: "ok" }
]);

console.log("admin logic tests: ok");
