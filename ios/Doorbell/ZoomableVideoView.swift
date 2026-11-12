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

    /// The part of the unzoomed picture that fills the viewport at `scale`, centred on `point`
    /// and moved back inside the picture so a zoom near a corner never shows anything beyond its
    /// edges. All values are in the picture's own (1x) coordinates.
    static func visibleRect(scale: CGFloat, around point: CGPoint, in bounds: CGSize) -> CGRect {
        let scale = clampedScale(scale)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let x = min(max(0, point.x - size.width / 2), max(0, bounds.width - size.width))
        let y = min(max(0, point.y - size.height / 2), max(0, bounds.height - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A pan offset limited to the picture: at `scale` the zoomed content is `bounds * scale`,
    /// and the viewport may not leave it.
    static func clampedOffset(_ offset: CGPoint, scale: CGFloat, bounds: CGSize) -> CGPoint {
        let scale = clampedScale(scale)
        let maxX = max(0, bounds.width * (scale - 1))
        let maxY = max(0, bounds.height * (scale - 1))
        return CGPoint(x: min(maxX, max(0, offset.x)), y: min(maxY, max(0, offset.y)))
    }
}

/// Hosts a live picture so it can be pinched from 1x to 4x, dragged while zoomed, and toggled
/// between fit and 2x with a double tap. Both renderers (the MJPEG image view and the H.264
/// sample-buffer layer's host) go into `contentView`. The scroll view owns the pan limits, so the
/// picture can never be dragged past its edges, and its recognizers only claim pinches, drags of
/// a zoomed picture and double taps: single taps and the call controls beside the picture are
/// untouched. tvOS has no touch input and keeps a plain container.
final class ZoomableVideoView: UIView, UIScrollViewDelegate {

    let contentView = UIView()
    #if os(iOS)
    private let scroll = UIScrollView()
    /// Exposed so a screen with its own single-tap recognizer can wait for this one to fail.
    let doubleTap = UITapGestureRecognizer()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        #if os(iOS)
        scroll.translatesAutoresizingMaskIntoConstraints = false
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
        addSubview(scroll)
        scroll.addSubview(contentView)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scroll.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            contentView.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(onDoubleTap(_:)))
        scroll.addGestureRecognizer(doubleTap)
        #else
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Adds one renderer, filling the picture area.
    func host(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
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
        #if os(iOS)
        scroll.setZoomScale(VideoZoom.minimumScale, animated: false)
        scroll.contentOffset = .zero
        #endif
    }

    #if os(iOS)
    /// A rotation or a new video aspect changes the viewport under a zoomed picture; the offset
    /// is brought back inside it.
    override func layoutSubviews() {
        super.layoutSubviews()
        let clamped = VideoZoom.clampedOffset(scroll.contentOffset, scale: scroll.zoomScale,
                                              bounds: scroll.bounds.size)
        if clamped != scroll.contentOffset { scroll.contentOffset = clamped }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return contentView }

    @objc private func onDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let target = VideoZoom.doubleTapTarget(from: scroll.zoomScale)
        let rect = VideoZoom.visibleRect(scale: target,
                                         around: recognizer.location(in: contentView),
                                         in: scroll.bounds.size)
        scroll.zoom(to: rect, animated: !Motion.reduced)
    }

    #if DEBUG
    func setZoomForTesting(_ scale: CGFloat, offset: CGPoint) {
        scroll.setZoomScale(VideoZoom.clampedScale(scale), animated: false)
        scroll.contentOffset = VideoZoom.clampedOffset(offset, scale: scroll.zoomScale,
                                                       bounds: scroll.bounds.size)
    }
    var contentOffsetForTesting: CGPoint { return scroll.contentOffset }
    #endif
    #endif
}
