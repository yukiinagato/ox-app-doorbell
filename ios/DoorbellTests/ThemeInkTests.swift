import UIKit
import XCTest

@testable import Doorbell

/// The automatic text-ink precedence of §5, which a real panel got wrong: Core reported a flat
/// `color` background for a 5.7 MP picture it had refused to sample, and the shell painted the
/// published light ink over the light half of that picture.
final class ThemeInkTests: XCTestCase {

    private let lightGround = UIColor(white: 0.93, alpha: 1)
    private let darkGround = UIColor(white: 0.07, alpha: 1)

    private func display(_ theme: [String: Any]) -> [String: Any] {
        return ["theme": theme]
    }

    private func decide(_ display: [String: Any]?, region: String = "footer",
                        ground: InkGround, config: [String: Any]? = nil,
                        nodeId: String = "") -> InkDecision {
        return DoorbellTheme.decideInk(display: display, config: config, nodeId: nodeId,
                                       region: region, ground: ground, palette: .dark)
    }

    private func assertColor(_ actual: UIColor, _ expected: UIColor,
                             _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(DoorbellTheme.hex(actual), DoorbellTheme.hex(expected), message,
                       file: file, line: line)
    }

    // MARK: - The decision table

    /// An administrator's choice is deliberate and beats every automatic answer, on every ground.
    func testOverrideWinsOverCoreInkAndOverALocalSample() {
        let contract = display(["ink_override": ["footer": "#ff0000"],
                                "auto_ink": ["footer": "light"],
                                "auto_background": ["source": "color", "color": "#101010"]])
        for ground in [InkGround.palette(darkGround), .themeColor(darkGround),
                       .sampled(.uniform(lightGround))] {
            let decision = decide(contract, ground: ground)
            XCTAssertEqual(decision.source, .admin)
            assertColor(decision.ink, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        }
    }

    /// Core republishes the overrides it validated, but a Core that predates the display contract
    /// publishes none, so configuration is still read — this device's value before the cluster's.
    func testOverrideIsAlsoReadFromConfiguration() {
        let cluster: [String: Any] = ["display": ["theme": ["ink_override": ["footer": "#00ff00"]]]]
        let clusterDecision = decide(nil, ground: .themeColor(darkGround), config: cluster)
        XCTAssertEqual(clusterDecision.source, .admin)
        assertColor(clusterDecision.ink, UIColor(red: 0, green: 1, blue: 0, alpha: 1))

        var perDevice = cluster
        perDevice["devices"] = ["pad-1": ["local": ["theme": ["ink_override":
                                                                ["footer": "#0000ff"]]]]]
        let deviceDecision = decide(nil, ground: .themeColor(darkGround), config: perDevice,
                                    nodeId: "pad-1")
        XCTAssertEqual(deviceDecision.source, .admin)
        assertColor(deviceDecision.ink, UIColor(red: 0, green: 0, blue: 1, alpha: 1))

        // The display contract still outranks both.
        let published = display(["ink_override": ["footer": "#ff00ff"]])
        XCTAssertEqual(DoorbellTheme.hex(decide(published, ground: .themeColor(darkGround),
                                                config: perDevice, nodeId: "pad-1").ink),
                       "#ff00ff")
    }

    /// Over a flat theme colour Core measured exactly what is on screen, so its per-region value
    /// stands and every shell in the cluster agrees on one answer.
    func testCoreInkDecidesOverAFlatThemeColour() {
        let dark = decide(display(["auto_ink": ["footer": "light"],
                                   "auto_background": ["source": "color", "color": "#121212"]]),
                          ground: .themeColor(darkGround))
        XCTAssertEqual(dark.source, .core)
        assertColor(dark.ink, DoorbellPalette.dark.ink, "a light token asks for the light ink")

        let light = decide(display(["auto_ink": ["footer": "dark"],
                                    "auto_background": ["source": "color", "color": "#eeeeee"]]),
                           ground: .themeColor(lightGround))
        XCTAssertEqual(light.source, .core)
        assertColor(light.ink, DoorbellPalette.light.ink, "a dark token asks for the dark ink")
    }

    /// A region of a picture this shell drew is measured here. Core computes one ink for the whole
    /// picture because it has no layout geometry, so over a light corner it is simply wrong.
    func testLocalRegionSampleBeatsCoreInkOverAPicture() {
        let contract = display(["bg_image": "sha256:abc",
                                "auto_ink": ["footer": "light"],
                                "auto_background": ["source": "image", "color": "#101010"]])
        let decision = decide(contract, ground: .sampled(.uniform(lightGround)))
        XCTAssertEqual(decision.source, .localRegion)
        assertColor(decision.ink, DoorbellPalette.light.ink,
                    "a light region takes the dark ink whatever Core published")

        let onDark = decide(contract, ground: .sampled(.uniform(darkGround)))
        XCTAssertEqual(onDark.source, .localRegion)
        assertColor(onDark.ink, DoorbellPalette.dark.ink)
    }

    /// With no theme decoration at all there is nothing for Core's ink to describe.
    func testPaletteGroundKeepsThePaletteInk() {
        let decision = decide(display(["auto_ink": ["footer": "dark"]]),
                              ground: .palette(DoorbellPalette.dark.background))
        XCTAssertEqual(decision.source, .local)
        assertColor(decision.ink, DoorbellPalette.dark.ink)
    }

    /// An older Core publishes no per-region ink; the same contrast rule runs locally instead.
    func testMissingCoreInkFallsBackToTheLocalRule() {
        let decision = decide(display(["auto_background": ["color": "#eeeeee"]]),
                              ground: .themeColor(lightGround))
        XCTAssertEqual(decision.source, .local)
        assertColor(decision.ink, DoorbellPalette.light.ink)
    }

    /// The automatic ink is the one that reads better, not the one a luminance threshold picks.
    /// A wallpaper averaging #BBBBB4 lands at Y = 0.494 — just under a 0.5 threshold, which would
    /// hand it the light ink at under 2:1 where the dark ink reads at over 9:1. The two rules
    /// differ only around the middle of the range, and cross over near Y = 0.179.
    func testAutomaticInkTakesTheBetterContrastNotTheLuminanceHalf() {
        let wallpaper = UIColor(red: 0xBB / 255, green: 0xBB / 255, blue: 0xB4 / 255, alpha: 1)
        XCTAssertLessThan(Double(DoorbellTheme.luminance(wallpaper)), 0.5,
                          "#BBBBB4 is the case a 0.5 threshold gets wrong")
        assertColor(DoorbellTheme.automaticInk(on: wallpaper), DoorbellPalette.light.ink,
                    "#BBBBB4 takes the dark ink")
        XCTAssertGreaterThan(
            DoorbellTheme.contrast(DoorbellTheme.automaticInk(on: wallpaper), wallpaper),
            DoorbellTheme.contrast(DoorbellPalette.dark.ink, wallpaper))

        let midGrey = UIColor(white: 0x40 / 255, alpha: 1)
        assertColor(DoorbellTheme.automaticInk(on: midGrey), DoorbellPalette.dark.ink,
                    "#404040 takes the light ink")

        assertColor(DoorbellTheme.automaticInk(on: .white), DoorbellPalette.light.ink)
        assertColor(DoorbellTheme.automaticInk(on: .black), DoorbellPalette.dark.ink)
    }

    /// The rule reaches the regions too, not only the arithmetic helper.
    func testASampledWallpaperTakesTheDarkInkOverCoresLightOne() {
        let contract = display(["bg_image": "sha256:abc",
                                "auto_ink": ["footer": "light"],
                                "auto_background": ["source": "image_unsampled",
                                                    "reason": "pixels_above_cap"]])
        let wallpaper = UIColor(red: 0xBB / 255, green: 0xBB / 255, blue: 0xB4 / 255, alpha: 1)
        let decision = decide(contract, ground: .sampled(.uniform(wallpaper)))
        XCTAssertEqual(decision.source, .localRegion)
        assertColor(decision.ink, DoorbellPalette.light.ink)
        XCTAssertGreaterThan(Double(DoorbellTheme.contrast(decision.ink, wallpaper)), 4.5)
        XCTAssertNil(decision.shadow, "an ink that already passes AA needs no outline")
    }

    // MARK: - What Core says about its own measurement

    /// Core will report `image_unsampled` with a reason for a picture it refuses to decode. That
    /// colour describes nothing on screen, and an unknown value from a newer Core is read the same
    /// cautious way — neither is an error, and neither may crash the shell.
    func testBackgroundSourceValuesAreAllAccepted() {
        XCTAssertEqual(DoorbellTheme.backgroundSource(
            display: display(["auto_background": ["source": "image"]])), .image)
        XCTAssertEqual(DoorbellTheme.backgroundSource(
            display: display(["auto_background": ["source": "color"]])), .color)
        XCTAssertEqual(DoorbellTheme.backgroundSource(
            display: display(["auto_background": ["source": "image_unsampled",
                                                  "reason": "pixels_above_cap"]])),
                       .imageUnsampled)
        XCTAssertNil(DoorbellTheme.backgroundSource(
            display: display(["auto_background": ["source": "hologram"]])))
        XCTAssertNil(DoorbellTheme.backgroundSource(display: display([:])))
        XCTAssertNil(DoorbellTheme.backgroundSource(display: nil))
    }

    func testOnlyAMeasuredColourIsTreatedAsTheGround() {
        XCTAssertTrue(DoorbellTheme.publishedBackgroundIsGround(
            display: display(["auto_background": ["source": "color", "color": "#123456"]])))
        XCTAssertTrue(DoorbellTheme.publishedBackgroundIsGround(
            display: display(["auto_background": ["source": "image", "color": "#123456"]])))
        XCTAssertFalse(DoorbellTheme.publishedBackgroundIsGround(
            display: display(["auto_background": ["source": "image_unsampled",
                                                  "reason": "pixels_above_cap",
                                                  "color": "#123456"]])))
        XCTAssertFalse(DoorbellTheme.publishedBackgroundIsGround(
            display: display(["auto_background": ["source": "hologram", "color": "#123456"]])),
                       "an unknown source may not be mistaken for a measurement")
        XCTAssertTrue(DoorbellTheme.publishedBackgroundIsGround(
            display: display(["auto_background": ["color": "#123456"]])),
                      "a Core with no source field always measured")
    }

    // MARK: - Colour arithmetic

    func testRelativeLuminanceAndContrast() {
        XCTAssertEqual(Double(DoorbellTheme.luminance(.white)), 1, accuracy: 0.0001)
        XCTAssertEqual(Double(DoorbellTheme.luminance(.black)), 0, accuracy: 0.0001)
        XCTAssertEqual(Double(DoorbellTheme.luminance(.green)), 0.7152, accuracy: 0.0001)
        XCTAssertEqual(Double(DoorbellTheme.contrast(.white, .black)), 21, accuracy: 0.0001)
    }

    /// The outline is a fallback, not decoration: it appears only below the 4.5:1 body-text
    /// target, and it is the opposite ink at 40 %.
    func testShadowAppearsOnlyBelowTheBodyTextTarget() {
        let readable = decide(nil, ground: .sampled(.uniform(darkGround)))
        XCTAssertNil(readable.shadow)

        // Around the crossover neither ink reaches 4.5:1, which is precisely when the outline is
        // the only thing keeping the text readable.
        let midGround = UIColor(white: 0.5, alpha: 1)
        let marginal = decide(nil, ground: .sampled(.uniform(midGround)))
        assertColor(marginal.ink, DoorbellPalette.light.ink)
        XCTAssertLessThan(DoorbellTheme.contrast(marginal.ink, midGround), 4.5)
        guard let shadow = marginal.shadow else {
            return XCTFail("an ink that misses 4.5:1 has to carry the opposite-ink outline")
        }
        var white: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(shadow.getWhite(&white, alpha: &alpha))
        XCTAssertEqual(Double(alpha), 1, accuracy: 0.001,
                       "the halo colour is opaque; its strength is the layer's opacity")
        XCTAssertEqual(Double(white), 1, accuracy: 0.001, "a dark ink is outlined in white")
    }

    /// The halo has to be a halo: a flat one-point label shadow is two device pixels on a 2x
    /// panel and vanished into a photograph on the device.
    func testTheHaloIsBlurredAndNearlyOpaque() {
        XCTAssertGreaterThanOrEqual(Double(DoorbellTheme.outlineBlurRadius), 2)
        XCTAssertGreaterThanOrEqual(Double(DoorbellTheme.outlineOpacity), 0.8)

        let label = UILabel()
        let midGround = UIColor(white: 0.5, alpha: 1)
        DoorbellTheme.applyInk(DoorbellPalette.light.ink,
                               over: .sampled(.uniform(midGround)), to: label)
        XCTAssertEqual(label.layer.shadowOpacity, DoorbellTheme.outlineOpacity)
        XCTAssertEqual(label.layer.shadowRadius, DoorbellTheme.outlineBlurRadius)
        XCTAssertEqual(label.layer.shadowOffset, .zero)
        XCTAssertNil(label.shadowColor, "the flat label shadow is not used any more")

        // An ink that reads on its own carries no halo at all.
        DoorbellTheme.applyInk(DoorbellPalette.dark.ink,
                               over: .sampled(.uniform(UIColor(white: 0.02, alpha: 1))),
                               to: label)
        XCTAssertEqual(label.layer.shadowOpacity, 0)
    }

    // MARK: - Sampling the picture the shell actually draws

    /// The picture is scaled to cover the viewport and centred, so a region on screen maps onto
    /// the part of the picture the viewer is looking at rather than the whole file.
    func testAspectFillRectCoversAndCentres() {
        let wide = DoorbellTheme.aspectFillRect(imageSize: CGSize(width: 200, height: 100),
                                                viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(wide.height, 100, accuracy: 0.001)
        XCTAssertEqual(wide.width, 200, accuracy: 0.001)
        XCTAssertEqual(wide.minX, -50, accuracy: 0.001, "the overflow is cropped on both sides")
        XCTAssertEqual(wide.minY, 0, accuracy: 0.001)

        let tall = DoorbellTheme.aspectFillRect(imageSize: CGSize(width: 100, height: 400),
                                                viewport: CGSize(width: 200, height: 200))
        XCTAssertEqual(tall.width, 200, accuracy: 0.001)
        XCTAssertEqual(tall.height, 800, accuracy: 0.001)
        XCTAssertEqual(tall.minY, -300, accuracy: 0.001)
    }

    /// The whole path, on the shape of the real finding: a picture whose top half is bright and
    /// bottom half is dark, with Core insisting on one light ink for all of it.
    func testAPictureIsInkedPerRegionWhateverCorePublished() {
        let background = ThemeBackgroundView()
        background.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        background.setBackgroundImage(twoToneImage(size: CGSize(width: 64, height: 96)))
        XCTAssertTrue(background.drawsImage)

        let contract = display(["bg_image": "sha256:abc",
                                "auto_ink": ["clock": "light", "footer": "light"],
                                "auto_background": ["source": "image_unsampled",
                                                    "reason": "pixels_above_cap",
                                                    "color": "#101010"]])
        let skin = DoorbellSkin(palette: .dark, display: contract,
                                background: DoorbellPalette.dark.background, decorated: true,
                                config: nil, nodeId: "", sampler: background)

        let top = skin.decision("clock", in: CGRect(x: 20, y: 20, width: 280, height: 60))
        XCTAssertEqual(top.source, .localRegion)
        assertColor(top.ink, DoorbellPalette.light.ink,
                    "the bright half must take the dark ink, not Core's light one")

        let bottom = skin.decision("footer", in: CGRect(x: 20, y: 400, width: 280, height: 40))
        XCTAssertEqual(bottom.source, .localRegion)
        assertColor(bottom.ink, DoorbellPalette.dark.ink)

        XCTAssertGreaterThan(DoorbellTheme.luminance(top.background), 0.5)
        XCTAssertLessThan(DoorbellTheme.luminance(bottom.background), 0.5)
    }

    /// Without a picture on screen the sampler stays out of the way and Core's ink is used.
    func testAnUndrawnPictureLeavesCoreInkInCharge() {
        let background = ThemeBackgroundView()
        background.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        XCTAssertFalse(background.drawsImage)

        let contract = display(["auto_ink": ["footer": "light"],
                                "auto_background": ["source": "color", "color": "#101010"]])
        let skin = DoorbellSkin(palette: .dark, display: contract, background: darkGround,
                                decorated: true, config: nil, nodeId: "", sampler: background)
        let decision = skin.decision("footer", in: CGRect(x: 0, y: 0, width: 100, height: 20))
        XCTAssertEqual(decision.source, .core)
        assertColor(decision.ink, DoorbellPalette.dark.ink)
    }

    // MARK: - The outline answers the whole region, not its average

    /// A region that is one colour throughout needs no outline once its ink clears 4.5:1.
    func testAUniformRegionThatClearsAAKeepsNoOutline() {
        let wallpaper = UIColor(red: 0xBB / 255, green: 0xBB / 255, blue: 0xB4 / 255, alpha: 1)
        let decision = decide(nil, ground: .sampled(.uniform(wallpaper)))
        assertColor(decision.ink, DoorbellPalette.light.ink, "#BBBBB4 takes the dark ink")
        XCTAssertGreaterThan(Double(DoorbellTheme.contrast(decision.ink, wallpaper)), 4.5)
        XCTAssertNil(decision.shadow)
    }

    /// The device finding: a hint line crossing a pale wall and a dark jacket. The average is the
    /// same #BBBBB4 wall that needs no outline on its own, and the ink chosen from that average is
    /// still right — but it disappears over the jacket, so the outline has to come from the
    /// darkest and lightest patch rather than the average.
    func testARegionSpanningLightAndDarkTakesTheOutline() {
        let wall = UIColor(red: 0xBB / 255, green: 0xBB / 255, blue: 0xB4 / 255, alpha: 1)
        let jacket = UIColor(white: 0.08, alpha: 1)
        let sample = BackgroundSample(average: wall,
                                      minLuminance: DoorbellTheme.luminance(jacket),
                                      maxLuminance: DoorbellTheme.luminance(wall))
        let decision = decide(nil, ground: .sampled(sample))

        assertColor(decision.ink, DoorbellPalette.light.ink,
                    "the average still chooses the ink")
        XCTAssertGreaterThan(Double(DoorbellTheme.contrast(decision.ink, wall)), 4.5,
                             "against the average alone this pair would have looked settled")
        XCTAssertLessThan(Double(sample.worstContrast(decision.ink)), 4.5,
                          "over the jacket it is not")

        guard let shadow = decision.shadow else {
            return XCTFail("an ink that fails over part of its own region needs the outline")
        }
        var white: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(shadow.getWhite(&white, alpha: &alpha))
        XCTAssertEqual(Double(alpha), 1, accuracy: 0.001,
                       "the halo colour is opaque; its strength is the layer's opacity")
        XCTAssertEqual(Double(white), 1, accuracy: 0.001, "a dark ink is outlined in white")
    }

    /// The same rule off a real picture: a band straddling the light and dark halves is outlined,
    /// and a band wholly inside the light half is not.
    func testTheOutlineFollowsTheRegionOnADrawnPicture() {
        let background = ThemeBackgroundView()
        background.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        background.setBackgroundImage(twoToneImage(size: CGSize(width: 64, height: 96)))
        let skin = DoorbellSkin(palette: .dark, display: display(["bg_image": "sha256:abc"]),
                                background: darkGround, decorated: true, config: nil, nodeId: "",
                                sampler: background)

        let straddling = skin.decision("hint", in: CGRect(x: 20, y: 200, width: 280, height: 80))
        XCTAssertEqual(straddling.source, .localRegion)
        XCTAssertNotNil(straddling.shadow,
                        "a band across both halves fails over one of them")

        let inTheLight = skin.decision("clock", in: CGRect(x: 20, y: 20, width: 280, height: 60))
        assertColor(inTheLight.ink, DoorbellPalette.light.ink)
        XCTAssertNil(inTheLight.shadow, "a band wholly on the bright half reads on its own")
    }

    /// A sample answers for both extremes, whichever side the ink sits on.
    func testWorstContrastTakesTheNearerExtreme() {
        let sample = BackgroundSample(average: UIColor(white: 0.5, alpha: 1),
                                      minLuminance: DoorbellTheme.luminance(.black),
                                      maxLuminance: DoorbellTheme.luminance(.white))
        XCTAssertEqual(Double(sample.worstContrast(.white)), 1, accuracy: 0.0001)
        XCTAssertEqual(Double(sample.worstContrast(.black)), 1, accuracy: 0.0001)

        let flat = BackgroundSample.uniform(.black)
        XCTAssertEqual(Double(flat.worstContrast(.white)), 21, accuracy: 0.0001)
    }

    // MARK: - Re-deciding when the picture or the layout moves

    /// The picture arrives long after the screen was laid out. Deciding once at bind time is what
    /// leaves Core's light ink standing over a light photograph, so the arrival re-inks every
    /// region that was handed over.
    func testInkIsDecidedAgainWhenThePictureArrives() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let background = ThemeBackgroundView()
        background.frame = host.bounds
        host.addSubview(background)
        let clock = UILabel(frame: CGRect(x: 20, y: 20, width: 280, height: 60))
        host.addSubview(clock)

        let contract = display(["bg_image": "sha256:abc",
                                "auto_ink": ["clock": "light"],
                                "auto_background": ["source": "image_unsampled",
                                                    "reason": "pixels_above_cap"]])
        let skin = DoorbellSkin(palette: .dark, display: contract, background: darkGround,
                                decorated: true, config: nil, nodeId: "", sampler: background)
        skin.apply("clock", to: clock)
        assertColor(clock.textColor, DoorbellPalette.dark.ink,
                    "before the picture there is only Core's answer")

        background.setBackgroundImage(twoToneImage(size: CGSize(width: 64, height: 96)))
        drainMainQueue()
        assertColor(clock.textColor, DoorbellPalette.light.ink,
                    "the bright half of the arrived picture takes the dark ink")
    }

    /// A rotation moves every region to a different part of the picture.
    func testInkIsDecidedAgainWhenTheLayoutChanges() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let background = ThemeBackgroundView()
        background.frame = host.bounds
        host.addSubview(background)
        let footer = UILabel(frame: CGRect(x: 20, y: 400, width: 280, height: 40))
        host.addSubview(footer)

        background.setBackgroundImage(twoToneImage(size: CGSize(width: 64, height: 96)))
        let skin = DoorbellSkin(palette: .dark, display: display(["bg_image": "sha256:abc"]),
                                background: darkGround, decorated: true, config: nil, nodeId: "",
                                sampler: background)
        skin.apply("footer", to: footer)
        drainMainQueue()
        assertColor(footer.textColor, DoorbellPalette.dark.ink, "the dark half takes light ink")

        // The footer ends up over the bright half after the layout moves.
        footer.frame = CGRect(x: 20, y: 40, width: 280, height: 40)
        background.frame = CGRect(x: 0, y: 0, width: 320, height: 481)
        background.layoutIfNeeded()
        drainMainQueue()
        assertColor(footer.textColor, DoorbellPalette.light.ink)
    }

    /// Runs the re-ink the background view scheduled on the main queue, then returns.
    private func drainMainQueue() {
        let settled = expectation(description: "the scheduled ink pass has run")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// A bright top half and a dark bottom half, which is the shape of a sky over a doorway.
    private func twoToneImage(size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        UIColor(white: 0.95, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        UIColor(white: 0.05, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}
