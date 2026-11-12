import UIKit

/// The geometry of live-picture zoom, kept apart from the view so it can be tested on its own.
enum VideoZoom {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4
    /// What a double tap zooms to from the fitted picture.
    static let doubleTapScale: CGFloat = 2

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return minimumScale }
        return min(maximumScale, max(minimumScale, scale))
    }

    /// The scale a double tap moves to: 2x from the fitted picture, back to fit from anything
    /// that is already zoomed.
    static func doubleTapTarget(from current: CGFloat) -> CGFloat {
        return current > minimumScale + 0.01 ? minimumScale : doubleTapScale
    }

    /// The picture aspect-fitted in the stage: it fills the width or the height, whichever is
    /// reached first, and is never stretched or cropped. An unknown picture size fills the stage.
    static func fittedSize(picture: CGSize, stage: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0, stage.width > 0, stage.height > 0 else {
            return stage
        }
        let scale = min(stage.width / picture.width, stage.height / picture.height)
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }

    /// Where the zoomed picture may sit in the stage, per axis. The clip rectangle is the whole
    /// stage: a picture larger than the stage on an axis may not show empty space there, so its
    /// edges stay at or beyond the stage edges; a picture that is not larger stays centred.
    /// `origin` is the picture's top-left corner in stage coordinates.
    static func clampedOrigin(_ origin: CGPoint, zoomed: CGSize, stage: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, _ size: CGFloat, _ limit: CGFloat) -> CGFloat {
            guard size > limit else { return (limit - size) / 2 }
            return min(0, max(limit - size, value))
        }
        return CGPoint(x: axis(origin.x, zoomed.width, stage.width),
                       y: axis(origin.y, zoomed.height, stage.height))
    }

    /// How much of the stage the zoomed picture covers: it grows into the letterbox bars until
    /// it covers the stage, so this can exceed the fitted 1x rectangle.
    static func visibleSize(zoomed: CGSize, stage: CGSize) -> CGSize {
        return CGSize(width: min(zoomed.width, stage.width),
                      height: min(zoomed.height, stage.height))
    }

    /// The part of the fitted picture a double tap brings into the stage at `scale`, centred on
    /// `point` and kept inside the picture. All values are in the fitted picture's own (1x)
    /// coordinates.
    static func visibleRect(scale: CGFloat, around point: CGPoint, picture: CGSize,
                            stage: CGSize) -> CGRect {
        let scale = clampedScale(scale)
        let size = CGSize(width: min(picture.width, stage.width / scale),
                          height: min(picture.height, stage.height / scale))
        let x = min(max(0, point.x - size.width / 2), max(0, picture.width - size.width))
        let y = min(max(0, point.y - size.height / 2), max(0, picture.height - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// The stage of a live picture. The stage takes whatever space its screen gives it; the picture
/// is aspect-fitted and centred in it at 1x, can be pinched up to 4x, dragged while zoomed, and
/// toggled between fit and 2x with a double tap. The clip rectangle is the whole stage, so a
/// zoomed picture grows into the letterbox bars until it covers the stage. Both renderers (the
/// MJPEG image view and the H.264 sample-buffer layer's host) go into `contentView`, which is
/// the fitted picture. The scroll view owns the pan limits, and its recognizers only claim
/// pinches, drags of a zoomed picture and double taps: single taps and the call controls beside
/// the picture are untouched. tvOS has no touch input and keeps the fitted picture alone.
final class ZoomableVideoView: UIView, UIScrollViewDelegate {

    let contentView = UIView()
    /// The picture's own size after rotation, in any unit; only its aspect matters. Zero until
    /// the first frame says, and the picture then fills the stage.
    var pictureSize: CGSize = .zero {
        didSet { if pictureSize != oldValue { fitPicture(keepingZoom: true) } }
    }
    private var fittedStage: CGSize = .zero
    #if os(iOS)
    private let scroll = UIScrollView()
    /// Exposed so a screen with its own single-tap recognizer can wait for this one to fail.
    let doubleTap = UITapGestureRecognizer()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        #if os(iOS)
        scroll.delegate = self
        scroll.minimumZoomScale = VideoZoom.minimumScale
        scroll.maximumZoomScale = VideoZoom.maximumScale
        scroll.bounces = false
        scroll.bouncesZoom = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.scrollsToTop = false
        scroll.delaysContentTouches = false
        if #available(iOS 11.0, *) { scroll.contentInsetAdjustmentBehavior = .never }
        scroll.frame = bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scroll)
        scroll.addSubview(contentView)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(onDoubleTap(_:)))
        scroll.addGestureRecognizer(doubleTap)
        // The zoom level is the picture's accessibility value, so assistive technology and UI
        // tests can read what a pinch or a double tap did.
        isAccessibilityElement = true
        accessibilityIdentifier = "live_picture"
        accessibilityTraits = .image
        publishZoom()
        #else
        addSubview(contentView)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Adds one renderer, filling the fitted picture.
    func host(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(view)
    }

    var zoomScale: CGFloat {
        #if os(iOS)
        return scroll.zoomScale
        #else
        return 1
        #endif
    }

    /// Back to the fitted picture. Called whenever the door or the call on screen changes.
    func resetZoom() {
        fitPicture(keepingZoom: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedStage { fitPicture(keepingZoom: true) }
    }

    /// Sizes the picture to the stage at 1x and puts the zoom back on top of it. A rotation, a
    /// resized stage or a new picture aspect all come through here.
    private func fitPicture(keepingZoom: Bool) {
        fittedStage = bounds.size
        let fitted = VideoZoom.fittedSize(picture: pictureSize, stage: bounds.size)
        #if os(iOS)
        let zoom = keepingZoom ? scroll.zoomScale : VideoZoom.minimumScale
        scroll.zoomScale = VideoZoom.minimumScale
        contentView.frame = CGRect(origin: .zero, size: fitted)
        scroll.contentSize = fitted
        if zoom != VideoZoom.minimumScale { scroll.zoomScale = VideoZoom.clampedScale(zoom) }
        centrePicture()
        if !keepingZoom { scroll.contentOffset = restingOffset() }
        publishZoom()
        #else
        contentView.frame = CGRect(x: (bounds.width - fitted.width) / 2,
                                   y: (bounds.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height)
        #endif
    }

    #if os(iOS)
    /// An axis on which the zoomed picture is smaller than the stage is centred with an inset;
    /// an axis on which it is larger has none, so the scroll view stops the pan at its edges.
    private func centrePicture() {
        let zoomed = scroll.contentSize
        let inset = UIEdgeInsets(top: max(0, (bounds.height - zoomed.height) / 2),
                                 left: max(0, (bounds.width - zoomed.width) / 2),
                                 bottom: max(0, (bounds.height - zoomed.height) / 2),
                                 right: max(0, (bounds.width - zoomed.width) / 2))
        if scroll.contentInset != inset { scroll.contentInset = inset }
        let origin = VideoZoom.clampedOrigin(
            CGPoint(x: -scroll.contentOffset.x, y: -scroll.contentOffset.y),
            zoomed: zoomed, stage: bounds.size)
        let offset = CGPoint(x: -origin.x, y: -origin.y)
        if offset != scroll.contentOffset { scroll.contentOffset = offset }
    }

    private func restingOffset() -> CGPoint {
        let origin = VideoZoom.clampedOrigin(.zero, zoomed: scroll.contentSize, stage: bounds.size)
        return CGPoint(x: -origin.x, y: -origin.y)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centrePicture()
        publishZoom()
    }

    private func publishZoom() {
        accessibilityValue = String(format: "%.1fx", Double(scroll.zoomScale))
    }

    @objc private func onDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let target = VideoZoom.doubleTapTarget(from: scroll.zoomScale)
        let rect = VideoZoom.visibleRect(scale: target,
                                         around: recognizer.location(in: contentView),
                                         picture: contentView.bounds.size, stage: bounds.size)
        scroll.zoom(to: rect, animated: !Motion.reduced)
    }

    #if DEBUG
    func setZoomForTesting(_ scale: CGFloat, origin: CGPoint) {
        scroll.setZoomScale(VideoZoom.clampedScale(scale), animated: false)
        scroll.contentOffset = CGPoint(x: -origin.x, y: -origin.y)
        centrePicture()
    }
    /// The zoomed picture's frame in stage coordinates.
    var pictureFrameForTesting: CGRect {
        return CGRect(origin: CGPoint(x: -scroll.contentOffset.x, y: -scroll.contentOffset.y),
                      size: scroll.contentSize)
    }
    #endif
    #endif
}
