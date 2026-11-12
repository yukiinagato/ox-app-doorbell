#!/usr/bin/env python3
"""Source contracts for the kiosk's cross-cutting owner decisions: the round-6
and round-7 pairing/password/write rules (spec §5.4, §5.5), the cross-platform
visit-purpose flag, and the readability findings from the device run.

Two rules the UI must not blur:
  1. Minting the Pairing PIN is separate from 「まとめて追加」. The PIN card and
     the founder flow call the dedicated mint export; only the explicit bulk-add
     button, which carries its own warning, opens the pairing window.
  2. Revoke is a factory reset. Both a remote `pairing_revoked` and the local
     「クラスタから外す」 confirmation wipe the secure PSK, the boot.json pairing
     fields, and the name/role/door/setup_complete choice, then return the
     device to first-run setup.

The arithmetic behind rule 2 is covered by the host suite
(ios-compat/tests/native_settings_ux_test.m); this file pins the wiring.
"""

import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(relative_path):
    with open(os.path.join(ROOT, relative_path), encoding="utf-8") as handle:
        return handle.read()


class PairingFlowContracts(unittest.TestCase):
    def test_pin_minting_never_opens_the_bulk_add_window(self):
        add_device = read("ios-kiosk/src/Screens/DBAddDeviceScreen.m")
        pairing = read("ios-kiosk/src/Screens/DBPairingScreen.m")
        bridge_header = read("ios-kiosk/src/Core/DBCoreBridge.h")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")

        # The PIN card mints; it does not open the window.
        start_code = add_device[add_device.index("- (void)onStartCode"):
                                add_device.index("- (void)onAddAll")]
        self.assertIn("mintJoinTokenWithSeconds:600", start_code)
        self.assertNotIn("startPairingWithSeconds", start_code)
        self.assertNotIn("setPairingMode", start_code)

        # Founding a cluster shows the PIN card and this device's own QR only.
        create = pairing[pairing.index("- (void)onCreate"):]
        self.assertIn("mintJoinTokenWithSeconds:600", create)
        self.assertNotIn("startPairingWithSeconds", create)

        # 「まとめて追加」 is the one caller that opens the window.
        add_all = add_device[add_device.index("- (void)onAddAll"):
                             add_device.index("- (void)onStopAddAll")]
        self.assertIn("startPairingWithSeconds:600", add_all)
        self.assertIn("pair.add_all_warning", add_device)

        # An older core has no export: the card stays empty and says why,
        # rather than falling back to the window.
        self.assertIn("supportsJoinTokenMinting", bridge_header)
        self.assertIn("pair.mint_unsupported", add_device)
        self.assertIn('dlsym(RTLD_DEFAULT, "db_core_mint_join_token_json")', bridge)

    def test_revocation_is_a_factory_reset_of_identity_and_setup(self):
        router = read("ios-kiosk/src/Screens/DBRouter.m")
        add_device = read("ios-kiosk/src/Screens/DBAddDeviceScreen.m")
        boot = read("ios-kiosk/src/Core/DBBootConfig.m")
        delegate = read("ios-kiosk/src/Support/DBAppDelegate.m")

        reset_start = router.index("- (void)factoryResetForRevocation:")
        reset = router[reset_start:router.index("\n- (", reset_start + 10)]
        self.assertIn("[_core unpair]", reset)
        self.assertIn('storeSecret:@"mesh.psk" value:@""', reset)
        self.assertIn("clearPairingAndSetup", reset)
        self.assertIn("setupRequired = YES", reset)
        self.assertIn("restartIntoBootstrapSetup", reset)

        # Both entry points reach it: the replicated event and the local confirm.
        revoked = router[router.index('isEqualToString:@"pairing_revoked"'):]
        self.assertIn("factoryResetForRevocation:", revoked[:600])
        unpair = add_device[add_device.index("- (void)onUnpair"):]
        self.assertIn("factoryResetForRevocation:", unpair)

        # The profile transformation drops cluster identity and the setup choice.
        transform = boot[boot.index("+ (NSString *)factoryResetJsonFromJson:"):
                         boot.index("+ (BOOL)persistSetupName:")]
        for key in ("psk_hex", "psk_ref", "seed_peers", "name", "role", "door"):
            self.assertIn('removeObjectForKey:@"%s"' % key, transform)
        self.assertIn('forKey:@"setup_complete"', transform)

        # Returning to first-run setup stops the running node first.
        restart_start = delegate.index("- (void)restartIntoBootstrapSetup {")
        restart = delegate[restart_start:delegate.index("\n- (", restart_start + 10)]
        self.assertIn("[_core stop]", restart)
        self.assertIn("[_recovery stop]", restart)
        self.assertIn("showBootstrapSetup", restart)


class AdminPasswordAndWriteContracts(unittest.TestCase):
    """One cluster-wide admin password and native config writes (spec §5.5)."""

    def test_the_admin_gate_is_the_cluster_password_and_the_digest_is_migrated(self):
        overlay = read("ios-kiosk/src/Screens/DBPinOverlay.m")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")

        accept = overlay[overlay.index("- (BOOL)acceptsEnteredPassword:"):
                         overlay.index("- (void)submit {")]
        # Core owns the comparison and the lockout it shares with /api/login.
        self.assertIn("[DBCoreBridge supportsAdminPassword]", accept)
        self.assertIn("[_core verifyAdminPassword:entered]", accept)
        self.assertIn("retireLocalDigest", accept)
        # Core's documented codes drive the decision: accepted, wrong, locked
        # out, or no cluster password yet.
        self.assertIn("if (status > 0)", accept)
        self.assertIn("if (status == 0 || status == -1)", accept)
        self.assertIn("if (status != -2) return NO;", accept)
        # The old per-node digest is consulted only while the cluster has no
        # password (-2) and the first successful entry republishes it.
        self.assertIn('setAdminPasswordFrom:@"" to:entered', accept)
        self.assertIn("if (digest != nil && !localMatches) return NO;", accept)
        # ...and then the file is gone, so it is never a second credential.
        retire = overlay[overlay.index("+ (void)retireLocalDigest"):
                         overlay.index("- (BOOL)acceptsEnteredPassword:")]
        self.assertIn("removeItemAtPath:path", retire)
        self.assertIn('DBCoreSymbol("db_core_admin_password_verify")', bridge)
        self.assertIn("dlsym(RTLD_DEFAULT, name)", bridge)

    def test_native_settings_write_through_the_core_abi(self):
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        bridge = read("ios-kiosk/src/Core/DBCoreBridge.m")
        dialog = read("ios-kiosk/src/Screens/DBNoticeDialog.m")
        history = read("ios-kiosk/src/Screens/DBHistoryScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")

        for symbol in ("db_core_set_config_json", "db_core_config_batch_json",
                       "db_core_delete_config_key", "db_core_last_write_warnings_json",
                       "db_core_call_log_json_v2", "db_core_sip_set_mic_muted"):
            self.assertIn('DBCoreSymbol("%s")' % symbol, bridge)
        # There is no global-notice export: the cluster-wide announcement is
        # door "*", so the shell must not look one up.
        self.assertNotIn("db_core_set_global_notice", bridge)
        self.assertNotIn("db_core_clear_global_notice", bridge)
        self.assertIn("setNotice:text forDoor:DBNoticeTargetGlobal", bridge)
        # The batch form returns a result document, not a status code.
        self.assertIn("typedef char *(*DBConfigBatchFn)", bridge)
        # A readability warning is shown, never treated as a failed write.
        self.assertIn("lastWriteWarnings", settings)
        self.assertIn("theme.low_contrast", settings)

        # No loopback HTTP anywhere in the settings path.
        self.assertNotIn("api/config", settings)
        self.assertNotIn("api/login", settings)
        # Every row writes through one helper that owns the Core call and its retry.
        self.assertIn("[core setConfigKey:", settings)
        self.assertIn("[core deleteConfigKey:", settings)
        # A Core without the export says so instead of claiming a save.
        self.assertIn("status == -100", settings)

        self.assertIn("[_core setGlobalNotice:", dialog)
        self.assertIn("[_core clearGlobalNotice]", dialog)
        self.assertIn("callLogSince:0 beforeMs:beforeMs", history)
        self.assertIn("[DBCoreBridge supportsMicMute]", incoming)
        self.assertIn("[_core setMicMuted:muted]", incoming)


class NativeSettingsRoleAndParityContracts(unittest.TestCase):
    """The kiosk's own settings: the role form, the admin-password retry, and the
    keys it shares with the web admin."""

    def test_role_change_persists_boot_then_takes_the_identity_restart(self):
        form = read("ios-kiosk/src/Screens/DBRoleChange.m")
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        app = read("ios-kiosk/src/Support/DBAppDelegate.m")

        # The Device category opens the form for both the role and the door row.
        self.assertIn('[_texts ts:@"settings.change_role"], [self roleLabel], @"role"',
                      settings)
        self.assertIn("[[DBRoleChange alloc] initWithRouter:_router editor:_editor]", settings)
        # Nothing is written before the confirmation, and a busy device refuses.
        self.assertIn("applyLocalIdentityName:_boot.name role:role door:door", form)
        self.assertNotIn("setConfigKey", form)
        self.assertIn("settings.role_busy", form)
        for state in ('@"active_calls"', '@"emergency.active"', '@"joining"'):
            self.assertIn(state, form)
        self.assertIn("[DBBootConfig isValidDoor:door]", form)
        self.assertIn("settings.role_door_in_use", form)
        # Local and replicated edits share one commit: boot.json first, then the
        # maintenance restart.
        commit = app[app.rindex("- (DBIdentityCommit)commitIdentityName:"):
                     app.index("- (void)restartForIdentityChange {")]
        self.assertLess(commit.index("persistSetupName:name role:role door:door"),
                        commit.index("_identityRestartPending = YES"))
        local = app[app.index("- (BOOL)applyLocalIdentityName:"):
                    app.rindex("- (DBIdentityCommit)commitIdentityName:")]
        self.assertIn("[DBBootConfig isValidRole:role]", local)
        self.assertIn("[DBBootConfig isValidDoor:door]", local)
        replicated = app[app.index("- (BOOL)applyReplicatedIdentity {"):
                         app.index("- (BOOL)applyLocalIdentityName:")]
        self.assertIn("commitIdentityName:name role:role door:door", replicated)

    def test_top_level_writes_retry_after_the_admin_password(self):
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        write = settings[settings.index("- (BOOL)write:(int (^)(void))write {"):
                         settings.index("- (BOOL)writeKey:(NSString *)key string:")]
        self.assertIn("status != DBAdminRequiredResult", write)
        self.assertIn("[_router requestPinThen:^{", write)
        self.assertIn("[screen reportWriteStatus:write()]", write)
        # No row bypasses the retrying writer.
        self.assertNotIn("reportWriteStatus:[_core", settings)
        self.assertNotIn("reportWriteStatus:[screen->_core", settings)

    def test_settings_rows_use_the_keys_the_web_admin_edits(self):
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        admin = read("webui/admin/app.js")
        # Each key must be one the Admin itself names, so a renamed key fails here
        # rather than silently writing something Core ignores.
        for leaf in ("ui_lang", "helper_mode", "visitor_layout", "mjpeg_fps",
                     "mjpeg_quality", "h264_resolution", "h264_fps", "h264_bitrate_kbps",
                     "device_hint", "wake_screen", "min_interval_s", "show_button",
                     "launch_sound", "call_sound", "update_sound", "button_sound",
                     "return_s", "alarm_volume", "appearance_schedule", "dark_from",
                     "light_from", "auto_system"):
            self.assertIn(leaf, admin)
            self.assertIn(leaf, settings)
        for key in ('@"devices.%@.local.ui_lang"', '@"devices.%@.local.recovery.helper_mode"',
                    '@"ui.languages"', '@"call.indoor.return_s"',
                    '@"devices.%@.local.call.return_s"', '@"emergency.trigger.mode"',
                    '@"emergency.alarm_volume|0|100"', '@"audio.volume."',
                    '@"display.appearance_schedule"', '@"display.screensaver.schedule"',
                    '@"ui.launch_sound"', '@"ui.call_sound"', '@"ui.update_sound"'):
            self.assertIn(key, settings)
        # The visitor language list can never be written empty.
        self.assertIn("settings.languages_required", settings)


class VisitPurposeContracts(unittest.TestCase):
    """`visit_purposes.<id>.enabled` (bool, default true), introduced by the iOS
    package and honoured here. The arithmetic is covered by the host suite; this
    pins which screens filter on it and which deliberately do not."""

    def test_choosers_hide_disabled_purposes_but_records_keep_them(self):
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        settings = read("ios-kiosk/src/Screens/DBSettingsScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")

        # The visitor's grid, and the follow-up chooser that reads the same
        # list, offer only enabled purposes.
        rebuild = door[door.index("- (void)rebuildPurposes"):
                       door.index("- (void)rebuildLanguages")]
        self.assertIn("enabledPurposeIdsInConfig", rebuild)
        self.assertNotIn("sortedByOrder", rebuild)
        self.assertIn("_purposeAlertIDs = [_purposeIds copy]", door)

        # The editor lists every purpose, or a disabled one could never be
        # switched back on from the device, and its toggle writes the key.
        purpose_rows = settings[settings.index("- (NSArray *)purposeRows"):
                                settings.index("- (NSArray *)ruleRows")]
        self.assertIn("allPurposeIdsInConfig", purpose_rows)
        self.assertIn("enabledKeyForPurpose:purpose", purpose_rows)
        self.assertIn('@"toggle"', purpose_rows)

        # A purpose the visitor already pressed is still reported back.
        self.assertIn("Deliberately not filtered by visit_purposes", incoming)
        self.assertNotIn("enabledPurposeIdsInConfig", incoming)


class ReadabilityContracts(unittest.TestCase):
    """Findings from the real-device run: text over a light part of a theme
    image came out white, and the footer collided with the SOS slider in
    portrait. The maths for both lives in DBUiTheme and is host-tested; this
    pins that every screen actually goes through it."""

    def test_every_screen_inks_text_per_region(self):
        widgets = read("ios-kiosk/src/Screens/DBWidgets.m")
        home = read("ios-kiosk/src/Screens/DBHomeScreen.m")
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")

        # An administrator's colour outranks everything; over an image the
        # shell refines locally, because core averaged the whole picture.
        refine = widgets[widgets.index("- (NSString *)inkHexForRegion:(NSString *)region frame:"):
                         widgets.index("- (UIColor *)inkForRegion:(NSString *)region frame:")]
        self.assertIn("adminInkOverrideHexForRegion", refine)
        self.assertIn("averageHexInViewRect:frame", refine)
        self.assertIn("inkHexForSampledLuminance", refine)

        # The sample carries its extremes, tracked in the pass that already
        # reads every patch, and the shadow is gated on them: a line crossing a
        # pale wall and a dark jacket averages fine and vanishes over the
        # jacket. The ink itself still follows the average.
        sample = widgets[widgets.index("- (NSDictionary *)sampleInViewRect:"):
                         widgets.index("- (NSString *)averageHexInViewRect:")]
        for key in ('@"average"', '@"darkest"', '@"lightest"'):
            self.assertIn(key, sample)
        self.assertIn("darkestLuminance", sample)
        self.assertIn("lightestLuminance", sample)
        apply_ink = widgets[widgets.index("- (void)applyInkToLabel:"):]
        self.assertIn("backgroundSampleForRegion:region frame:frame viewSize:viewSize",
                      apply_ink)
        self.assertIn('darkest:[sample objectForKey:@"darkest"]', apply_ink)
        self.assertIn('lightest:[sample objectForKey:@"lightest"]', apply_ink)

        # The ink is whichever of the two reads better, not a lightness
        # threshold: a midtone wallpaper took white ink under the old rule.
        theme = read("ios-kiosk/src/Core/DBUiTheme.m")
        rule = theme[theme.index("+ (NSString *)inkModeForLuminance:"):
                     theme.index("+ (double)inkCrossoverLuminance")]
        self.assertIn("withDarkInk >= withLightInk", rule)
        self.assertNotIn("luminance >= 0.5", rule)

        # The sampler is built off the main thread and only when it must be...
        self.assertIn("DBBackgroundSampler samplerWithImage:image viewSize:size", home)
        self.assertIn("dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW", home)
        self.assertIn("CGSizeEqualToSize(_samplerSize, size)", home)
        # ...the decision re-runs once the image has finished loading...
        load = home[home.index("- (void)loadThemeImage:"):
                    home.index("- (void)refreshBackgroundSampler")]
        self.assertIn("screen->_themeImage = backdrop", load)
        self.assertIn("[screen refreshBackgroundSampler]", load)
        # One prepared, darkened copy per picture and panel size, decoded off
        # the main thread; the sampler then measures what is actually drawn.
        self.assertIn("DBThemeBackdrop cachedBackdropForKey:want size:size", load)
        self.assertIn("DBThemeBackdrop backdropForData:data key:want size:size", load)
        # The administrator's overlay is part of the picture's identity, so a
        # change of colour or opacity rebuilds rather than reusing the cache.
        self.assertIn("backdropOverlayForConfig:", load)
        self.assertIn("overlay:overlay", load)
        # The prepared bitmap is bounded and the darkening is deep enough to
        # read text over a bright wallpaper. Spec 5.1 wants the picture, so a
        # flat ground has to say which fault put it there.
        # The pixel work lives in a CoreGraphics-only unit so the darkening is
        # measured by a host test rather than judged from a device photograph.
        compositor = read("ios-kiosk/src/Core/DBBackdropCompositor.m")
        self.assertIn("+ (CGFloat)maximumLongSide { return 1024; }", compositor)
        self.assertIn("+ (CGFloat)darkeningAlpha { return 0.62; }", compositor)
        self.assertIn("kCGBlendModeNormal", compositor)
        self.assertIn("aspectFillDrawRectForImageWidth", compositor)
        self.assertIn("DBBackdropCompositor newBackdropFromImage:upright", widgets)
        # Icons are assets, never paths or emoji.
        self.assertNotIn("UIBezierPath", widgets)
        self.assertIn("DBIconAsset tintedImageNamed:", widgets)
        self.assertIn("CGContextClipToMask", read("ios-kiosk/src/Core/DBIconAsset.m"))
        # Cards, chips and scrims follow the appearance, not the wallpaper.
        self.assertIn("if (_usesThemeBackground) return [_mode isEqualToString:@\"light\"];",
                      widgets)
        self.assertIn("+ (NSString *)plateHexForMode:", theme)
        # The counters are a status line: ink and halo, no plate.
        self.assertIn("counter.ink = [_palette inkForRegion:DBUiRegionStatusLine", home)
        self.assertIn("counter.halo = [_palette needsShadowForRegion:", home)
        # The SOS bar is the fleet red with a real knob, not a tinted plate.
        self.assertIn("static UIColor *DBSosTrackColor(void)", widgets)
        self.assertIn("_thumb = [[UIView alloc] init];", widgets)
        self.assertIn("_thumbChevron = [[UIImageView alloc] init];", widgets)
        # Small text over a busy picture gets a plate; headings keep region ink.
        # The footer keeps its frosted plate. The dashboard lists no calls: the
        # History tab does, and unread missed calls show as one notice that
        # switches to it.
        self.assertIn("- (void)applyScrimTone", home)
        self.assertIn("_footerScrim.frame", home)
        self.assertIn("colorWithAlphaComponent:kFooterGlassAlpha", home)
        self.assertNotIn("UITableView", home)
        self.assertIn("_missedNotice.hidden = _unreadMissed <= 0;", home)
        self.assertIn("action:@selector(onHistory)", home)
        self.assertIn("[_router selectHomeTab:DBHomeTabHistory];", home)
        self.assertIn("[_tabs setMissedCount:_unreadMissed];", home)
        self.assertNotIn("DBNoticeChip", widgets)
        self.assertNotIn("DBTwoPartButton", widgets)
        for reason in ('@"safe_mode"', '@"no_theme_image_configured"',
                       '@"theme_asset_fetch_failed"', '@"theme_asset_decode_failed"'):
            self.assertIn(reason, home)
        # The admin address is one line that shrinks before it truncates, and
        # the host is the last thing to go.
        self.assertIn("_urlLabel.numberOfLines = 1;", widgets)
        self.assertIn("_urlLabel.adjustsFontSizeToFitWidth = YES;", widgets)
        self.assertIn("_urlLabel.minimumFontSize = kQrUrlMinPt;", widgets)
        self.assertIn("static const CGFloat kQrUrlMinPt = 9;", widgets)
        self.assertIn("- (NSString *)addressForWidth:", widgets)
        # ...and a sampler built for another view size is ignored, so a
        # rotation falls back rather than reading the wrong pixels.
        self.assertIn("- (DBBackgroundSampler *)samplerForViewSize:", widgets)
        self.assertIn("CGSizeEqualToSize(_sampler.viewSize, viewSize)", widgets)

        # Each screen inks its regions after layout, when the frames are final.
        for source, name in ((home, "dashboard"), (door, "door screen"),
                             (incoming, "incoming screen")):
            self.assertIn("- (void)applyRegionInk", source, name)
            self.assertIn("applyInkToLabel:", source, name)
            layout = source[source.rindex("- (void)layoutSubviews"):]
            self.assertIn("[self applyRegionInk]", layout, name)

        for region in ("DBUiRegionClock", "DBUiRegionDate", "DBUiRegionStatusLine"):
            self.assertIn(region, home)
            self.assertIn(region, door)
        self.assertIn("DBUiRegionHint", door)
        self.assertIn("DBUiRegionTileLabel", home)

    def test_the_live_picture_is_fitted_in_a_stage_that_is_also_the_zoom_clip(self):
        incoming = read("ios-kiosk/src/Screens/DBIncomingScreen.m")
        # Rotation before fitting, per-axis inset and clamp from the host-tested
        # geometry, and no aspect-locked stage or scaled-down quarter turn.
        self.assertIn("DBVideoStageFitSize(slot.size, [self videoSourceSize], _videoRotation)",
                      incoming)
        self.assertIn("DBVideoStageAxisMake(stage.width, zoomed.width)", incoming)
        self.assertIn("DBVideoStageClampOffset(x, offset.x)", incoming)
        self.assertIn("_videoScroll.contentInset = inset;", incoming)
        self.assertIn("s->_liveView.transform = CGAffineTransformMakeRotation(angle);", incoming)
        self.assertNotIn("* 9 / 16", incoming)
        self.assertNotIn("CGAffineTransformScale", incoming)
        self.assertIn("_videoScroll.maximumZoomScale = 4;", incoming)

    def test_the_footer_and_the_sos_slider_share_one_computed_band(self):
        theme = read("ios-kiosk/src/Core/DBUiTheme.m")
        home = read("ios-kiosk/src/Screens/DBHomeScreen.m")
        door = read("ios-kiosk/src/Screens/DBDoorScreen.m")

        self.assertIn("+ (NSDictionary *)footerLayoutForViewWidth:", theme)
        # The dashboard takes all three frames from that one split, so nothing
        # can drift back into an overlap.
        self.assertIn("footerLayoutForViewWidth:size.width", home)
        # ...measured above the tab bar, and every other dashboard frame comes
        # from the host-tested layout function.
        self.assertIn("viewHeight:footerViewHeight", home)
        self.assertIn("CGFloat footerViewHeight = size.height - tabHeight;", home)
        self.assertIn("DBHomeLayoutMake(size, navHeight, tabHeight, footerHeight,", home)
        self.assertIn("tile.frame = DBHomeLayoutTileFrame(layout, i, count);", home)
        # SOS is no longer a footer bar: the footer is laid out without it and
        # the compact trigger gets its frame from the dashboard layout.
        self.assertIn("sosVisible:NO];", home)
        self.assertIn("_sosButton.frame = layout.sos;", home)
        for element in ("qr", "version"):
            self.assertIn('DBRectFromArray([footer objectForKey:@"%s"])' % element, home)
        # The band reserves its own height instead of a hardcoded constant.
        self.assertIn('[[footer objectForKey:@"height"] doubleValue]', home)

        # The door station stacks them with an explicit gap.
        # The host layout test measures separation at every supported size;
        # this check retains the UIKit-to-production-layout wiring contract.
        self.assertIn("DBDoorVisitorLayoutMake(size, !_sosButton.hidden, actionScale)", door)
        self.assertIn("_versionLabel.frame = layout.version", door)
        self.assertIn("_sosButton.frame = layout.sos", door)
        # Two deliberate gestures in two places: the button only opens the
        # in-container panel, the slide lives in the panel, and neither screen
        # ever puts the slide on its own surface or uses a long press.
        panel = read("ios-kiosk/src/Screens/DBSosPanel.m")
        for source in (home, door):
            self.assertIn("[_sosPanel presentInView:self below:", source)
            self.assertIn("[[DBSosPanel alloc] initWithSlider:_sos delegate:self]", source)
            self.assertNotIn("addSubview:_sos]", source)
            self.assertNotIn("UILongPressGestureRecognizer", source)
        emergency = door[door.index("- (void)handleEmergencyEvent:"):]
        self.assertIn("if (active) [_sosPanel dismiss];", emergency[:1400])
        self.assertIn("[_sosPanel dismiss];\n  [_sos reset];", home)
        self.assertIn('tintedImageNamed:@"alert-triangle"', panel)
        self.assertIn("kSosPanelIdleCloseS = 10.0", panel)
        self.assertIn("[_panel addSubview:_slider];", panel)
        self.assertIn("[_forward sosSliderDidFire:slider];", panel)
        self.assertNotIn("emergency:", panel)
        self.assertNotIn("UILongPressGestureRecognizer", panel)


if __name__ == "__main__":
    unittest.main(verbosity=2)
