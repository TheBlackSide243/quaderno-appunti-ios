import UIKit

/// Text boxes and pictures of a page, in page points. Touches on empty space fall through to the
/// canvas below, so the page still scrolls and zooms.
@MainActor
final class ItemsLayer: UIView {
    private(set) var items: [PageItem] = []
    private var views: [UUID: ItemView] = [:]
    private var notebook: Notebook?
    private(set) var selectedID: UUID?

    var onChange: (() -> Void)?
    var onSelection: ((PageItem?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    func load(_ nb: Notebook, _ list: [PageItem]) {
        notebook = nb
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
        items = list
        selectedID = nil
        for item in list { addView(item) }
        onSelection?(nil)
    }

    private func addView(_ item: PageItem) {
        guard let nb = notebook else { return }
        let v = ItemView(item: item, notebook: nb)
        v.onTap = { [weak self] id in self?.tapped(id) }
        v.onChange = { [weak self] item in self?.changed(item) }
        v.onEndEditing = { [weak self] item in
            if item.kind == .text, item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.remove(item.id) }
        }
        addSubview(v)
        views[item.id] = v
    }

    func item(at p: CGPoint) -> PageItem? {
        items.last { $0.frame.contains(p) }
    }

    func add(_ item: PageItem, edit: Bool, select sel: Bool = true) {
        items.append(item)
        addView(item)
        if sel { select(item.id) }
        if edit { views[item.id]?.beginEditing() }
        onChange?()
    }

    // MARK: Tape

    /// The topmost tape under a point.
    func tape(at p: CGPoint) -> PageItem? {
        items.last { $0.kind == .tape && $0.frame.contains(p) }
    }

    func setCovered(_ id: UUID, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].covered = on ? nil : false
        views[id]?.apply(items[i], animated: true)
        if id == selectedID { onSelection?(items[i]) }
        onChange?()
    }

    /// Covers every tape of the page again. False if there was nothing to cover.
    @discardableResult
    func coverAllTapes() -> Bool {
        var any = false
        for i in items.indices where items[i].kind == .tape && !items[i].isCovered {
            items[i].covered = nil
            views[items[i].id]?.apply(items[i], animated: true)
            any = true
        }
        if any { onChange?() }
        return any
    }

    var hasTape: Bool { items.contains { $0.kind == .tape } }

    private func tapped(_ id: UUID) {
        if selectedID == id {
            views[id]?.beginEditing()
        } else {
            endEditing(true)
            select(id)
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
        for (k, v) in views { v.selected = k == id }
        onSelection?(items.first { $0.id == id })
    }

    private func changed(_ item: PageItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        if item.id == selectedID { onSelection?(item) }
        onChange?()
    }

    func updateSelected(_ change: (inout PageItem) -> Void) {
        guard let id = selectedID, let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        views[id]?.apply(items[i])
        onSelection?(items[i])
        onChange?()
    }

    private func remove(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), item.kind == .image, let name = item.image, let nb = notebook {
            try? FileManager.default.removeItem(at: Store.image(nb.id, name))
        }
        items.removeAll { $0.id == id }
        views[id]?.removeFromSuperview()
        views[id] = nil
        if selectedID == id { select(nil) }
        onChange?()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        remove(id)
    }

    func bringSelectedToFront() {
        guard let id = selectedID, let i = items.firstIndex(where: { $0.id == id }), let v = views[id] else { return }
        let item = items.remove(at: i)
        items.append(item)
        bringSubviewToFront(v)
        onChange?()
    }
}

/// One box. Drag to move, pinch or use the corner handle to resize, tap again to type.
@MainActor
final class ItemView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    private(set) var item: PageItem
    private let notebook: Notebook
    private var textView: UITextView?
    private var imageView: UIImageView?
    private var tapeView: UIView?
    private let tapeEdge = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handle = UIView()
    private var startFrame = CGRect.zero
    private var startFont: Double = 18

    var onTap: ((UUID) -> Void)?
    var onChange: ((PageItem) -> Void)?
    var onEndEditing: ((PageItem) -> Void)?

    var selected = false {
        didSet {
            border.isHidden = !selected
            handle.isHidden = !selected
        }
    }

    init(item: PageItem, notebook: Notebook) {
        self.item = item
        self.notebook = notebook
        super.init(frame: item.frame)
        backgroundColor = .clear

        switch item.kind {
        case .text:
            let tv = UITextView()
            tv.backgroundColor = .clear
            tv.isScrollEnabled = false
            tv.isEditable = false
            tv.isSelectable = false
            tv.textContainerInset = PageRenderer.textInset
            tv.textContainer.lineFragmentPadding = 0
            tv.delegate = self
            tv.overrideUserInterfaceStyle = .light
            tv.isUserInteractionEnabled = false
            addSubview(tv)
            textView = tv
        case .image:
            let iv = UIImageView()
            iv.contentMode = .scaleToFill
            iv.clipsToBounds = true
            if let name = item.image { iv.image = UIImage(contentsOfFile: Store.image(notebook.id, name).path) }
            addSubview(iv)
            imageView = iv
        case .tape:
            let tv = UIView()
            tv.isUserInteractionEnabled = false
            tv.layer.cornerRadius = 2
            tv.layer.shadowColor = UIColor.black.cgColor
            tv.layer.shadowOpacity = 0.18
            tv.layer.shadowRadius = 1.5
            tv.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(tv)
            tapeView = tv
            tapeEdge.fillColor = nil
            tapeEdge.lineWidth = 1
            tapeEdge.lineDashPattern = [4, 3]
            layer.addSublayer(tapeEdge)
        }

        border.fillColor = nil
        border.strokeColor = UIColor(Theme.accent).cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        border.isHidden = true
        layer.addSublayer(border)

        handle.backgroundColor = UIColor(Theme.accent)
        handle.layer.cornerRadius = 10
        handle.layer.borderColor = UIColor.white.cgColor
        handle.layer.borderWidth = 2
        handle.isHidden = true
        addSubview(handle)
        let handlePan = UIPanGestureRecognizer(target: self, action: #selector(resize))
        handlePan.delegate = self
        handle.addGestureRecognizer(handlePan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moved))
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        apply(item)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ item: PageItem, animated: Bool = false) {
        self.item = item
        if let tv = tapeView {
            let color = UIColor(hex: item.color)
            tv.backgroundColor = UIColor(patternImage: Self.tapePattern(color))
            tapeEdge.strokeColor = color.withAlphaComponent(0.9).cgColor
            let covered = item.isCovered
            let change = {
                tv.alpha = covered ? 1 : 0.16
                tv.layer.shadowOpacity = covered ? 0.18 : 0
            }
            if animated { UIView.animate(withDuration: 0.22, animations: change) } else { change() }
            tapeEdge.isHidden = covered
        }
        if let tv = textView {
            tv.font = UIFont.systemFont(ofSize: item.fontSize, weight: item.bold ? .bold : .regular)
            tv.textColor = UIColor(hex: item.color)
            if tv.text != item.text { tv.text = item.text }
            fitText()
        }
        frame = self.item.frame
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView?.frame = bounds
        imageView?.frame = bounds
        tapeView?.frame = bounds
        tapeEdge.frame = bounds
        tapeEdge.path = UIBezierPath(roundedRect: bounds, cornerRadius: 2).cgPath
        border.frame = bounds
        border.path = UIBezierPath(rect: bounds.insetBy(dx: -2, dy: -2)).cgPath
        handle.frame = CGRect(x: bounds.maxX - 20, y: bounds.maxY - 20, width: 20, height: 20)
    }

    /// Grows the box to fit its text.
    private func fitText() {
        guard let tv = textView else { return }
        let h = max(item.fontSize + 16, tv.sizeThatFits(CGSize(width: item.w, height: .greatestFiniteMagnitude)).height)
        if abs(h - item.h) > 0.5 { item.h = h }
    }

    func beginEditing() {
        guard let tv = textView else { return }
        tv.isUserInteractionEnabled = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        item.text = textView.text
        fitText()
        frame = item.frame
        onChange?(item)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        onEndEditing?(item)
    }

    @objc private func tapped() { onTap?(item.id) }

    /// Paper tape: the colour with light diagonal stripes, like washi tape.
    private static var patterns: [String: UIImage] = [:]

    static func tapePattern(_ color: UIColor) -> UIImage {
        let key = color.hexString
        if let p = patterns[key] { return p }
        let side: CGFloat = 12
        let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { r in
            color.setFill()
            r.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let c = r.cgContext
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            c.setLineWidth(3)
            for k in [-side, 0, side] {
                c.move(to: CGPoint(x: k, y: side))
                c.addLine(to: CGPoint(x: k + side, y: 0))
            }
            c.strokePath()
        }
        patterns[key] = img
        return img
    }

    /// The box's own drag must not start on the resize handle.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g.view === self, g is UIPanGestureRecognizer, !handle.isHidden,
           handle.frame.insetBy(dx: -8, dy: -8).contains(g.location(in: self)) {
            return false
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// Moving and resizing a box can happen together, but only with this box's own gestures.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    /// The page must not scroll or zoom while a box is being dragged or pinched.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    @objc private func moved(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            startFrame = item.frame
            if !selected { onTap?(item.id) }
        case .changed:
            let t = g.translation(in: sv)
            var f = startFrame.offsetBy(dx: t.x, dy: t.y)
            f.origin.x = min(max(f.origin.x, -f.width + 30), sv.bounds.width - 30)
            f.origin.y = min(max(f.origin.y, -f.height + 30), sv.bounds.height - 30)
            item.frame = f
            frame = f
        case .ended, .cancelled:
            onChange?(item)
        default: break
        }
    }

    @objc private func resize(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            startFrame = item.frame
        case .changed:
            let t = g.translation(in: sv)
            var f = startFrame
            f.size.width = max(item.kind == .tape ? 16 : 40, startFrame.width + t.x)
            if item.kind == .image {
                f.size.height = f.width * startFrame.height / max(1, startFrame.width)
            } else if item.kind == .tape {
                f.size.height = max(12, startFrame.height + t.y)
            }
            item.frame = f
            fitText()
            frame = item.frame
            setNeedsLayout()
        case .ended, .cancelled:
            onChange?(item)
        default: break
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            startFrame = item.frame
            startFont = item.fontSize
        case .changed:
            let s = max(0.2, min(6, g.scale))
            let c = CGPoint(x: startFrame.midX, y: startFrame.midY)
            let w = max(40, startFrame.width * s), h = max(20, startFrame.height * s)
            item.frame = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            if item.kind == .text {
                item.fontSize = max(8, min(120, (startFont * s).rounded()))
                textView?.font = UIFont.systemFont(ofSize: item.fontSize, weight: item.bold ? .bold : .regular)
                fitText()
            }
            frame = item.frame
            setNeedsLayout()
        case .ended, .cancelled:
            onChange?(item)
        default: break
        }
    }
}
