import UIKit
import ARKit
import RealityKit
import Combine

/// AR Desk Mode. Everything on the desk lives in "desk space": a single ARAnchor placed on the table,
/// +Y = up, Y = 0 is the table top, -Z points away from you (card "tops" point that way).
/// Built for Swift 5 language mode (ARSessionDelegate / scene-event closures are not actor-annotated).
final class ARDeskViewController: UIViewController, ARSessionDelegate, UIGestureRecognizerDelegate {

    // MARK: Configuration

    var brandHeader = true                       // false = exact web-card header (name in blue, company · title below)
    var defaultCC = ""                           // RoloPro's "Default country code" so QR phone numbers get a +prefix
    var onLaterChanged: (([String]) -> Void)?    // contact ids currently in the Later pile

    // MARK: State

    private let contacts: [RoloContact]
    private let arView = ARView(frame: .zero)
    private let reticleAnchor = AnchorEntity(world: .zero)
    private var deskAnchor: ARAnchor?
    private var deskEntity: AnchorEntity?
    private var deskPlaneID: UUID?
    private var cards: [CardEntity] = []
    private var selected: CardEntity?
    private var held: CardEntity?
    private var grabOffset = SIMD2<Float>.zero
    private var updateSub: Cancellable?

    private let friction: Float = 5.5            // exponential slide-out: travel distance = v0 / friction
    private let matThickness: Float = 0.0006
    private var laterCenter = SIMD2<Float>(0.22, 0)
    private let laterSize = SIMD2<Float>(0.17, 0.105)
    private var tableRect = (min: SIMD2<Float>(-0.2, -0.15), max: SIMD2<Float>(0.31, 0.15))
    private var laterIDs = Set(UserDefaults.standard.stringArray(forKey: "rolopro.ar.later") ?? [])

    // HUD
    private let hint = UILabel()
    private let selectionBar = UIStackView()
    private let addButton = UIButton(type: .system)

    // MARK: Init

    init(contacts: [RoloContact]) {
        self.contacts = contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        arView.frame = view.bounds
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self

        let coaching = ARCoachingOverlayView(frame: view.bounds)
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        setupReticle()
        setupGestures()
        setupHUD()
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.tick(Float(e.deltaTime))
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.environmentTexturing = .automatic                      // real reflections + lighting on the paper
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            cfg.sceneReconstruction = .mesh                        // LiDAR devices: hands and objects can occlude cards
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        arView.session.run(cfg)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: Table detection + desk anchor

    /// Prefers planes ARKit classifies as .table, then any non-floor horizontal plane, then whatever is there.
    private func tableHit(at p: CGPoint) -> ARRaycastResult? {
        let hits = arView.raycast(from: p, allowing: .existingPlaneGeometry, alignment: .horizontal)
        func kind(_ r: ARRaycastResult) -> ARPlaneAnchor.Classification? { (r.anchor as? ARPlaneAnchor)?.classification }
        return hits.first(where: { kind($0) == .table })
            ?? hits.first(where: { kind($0) != .floor })
            ?? hits.first
    }

    private func setupReticle() {
        let m = ModelEntity(mesh: .generatePlane(width: 0.12, depth: 0.12), materials: [CardMaterials.overlay(CardRenderer.reticle())])
        m.position.y = 0.001
        reticleAnchor.addChild(m)
        reticleAnchor.isEnabled = false
        arView.scene.addAnchor(reticleAnchor)
    }

    private func updateReticle() {
        guard let hit = tableHit(at: arView.center) else {
            reticleAnchor.isEnabled = false
            hint.text = "Point at a table and move slowly"
            return
        }
        reticleAnchor.isEnabled = true
        reticleAnchor.setTransformMatrix(hit.worldTransform, relativeTo: nil)
        let isTable = (hit.anchor as? ARPlaneAnchor)?.classification == .table
        hint.text = isTable ? "Table found. Tap to place your desk" : "Surface found. Tap to place your desk"
    }

    private func placeDesk(at hit: ARRaycastResult) {
        let t = hit.worldTransform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let cam = arView.cameraTransform.translation
        let yaw = atan2(cam.x - pos.x, cam.z - pos.z)               // desk +Z faces you, so card text reads upright
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(pos, 1)

        // A world ARAnchor (not the plane anchor): it never "slides" when ARKit merges / refines planes.
        let anchor = ARAnchor(name: "rolopro.desk", transform: m)
        arView.session.add(anchor: anchor)
        let desk = AnchorEntity(anchor: anchor)
        arView.scene.addAnchor(desk)
        deskAnchor = anchor
        deskEntity = desk
        deskPlaneID = (hit.anchor as? ARPlaneAnchor)?.identifier
        reticleAnchor.isEnabled = false

        let mat = ModelEntity(mesh: .generatePlane(width: laterSize.x, depth: laterSize.y),
                              materials: [CardMaterials.overlay(CardRenderer.tray())])
        mat.position = [laterCenter.x, 0.0004, laterCenter.y]
        desk.addChild(mat)

        hint.text = "Drag to move · double-tap to flip · flick toward Later"
        deal(Array(contacts.prefix(3)))
        if contacts.isEmpty { hint.text = "No contacts yet. Import a RoloPro backup first" }
    }

    private func resetDesk() {
        if let a = deskAnchor { arView.session.remove(anchor: a) }
        deskEntity?.removeFromParent()
        deskEntity = nil; deskAnchor = nil; deskPlaneID = nil
        cards.removeAll(); select(nil)
    }

    /// Fit the playable area to the real table as ARKit refines the plane.
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let id = deskPlaneID, let desk = deskEntity,
              let plane = anchors.compactMap({ $0 as? ARPlaneAnchor }).first(where: { $0.identifier == id }) else { return }
        let toDesk = desk.transformMatrix(relativeTo: nil).inverse * plane.transform
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for v in plane.geometry.boundaryVertices {
            let p = toDesk * SIMD4<Float>(v, 1)
            lo = simd_min(lo, [p.x, p.z]); hi = simd_max(hi, [p.x, p.z])
        }
        // Never smaller than the starting area, so a half-scanned table doesn't trap the cards.
        tableRect = (min: simd_min(lo + [0.03, 0.03], [-0.2, -0.15]), max: simd_max(hi - [0.03, 0.03], [0.31, 0.15]))
    }

    // MARK: Cards

    private func deal(_ list: [RoloContact]) {
        guard let desk = deskEntity else { return }
        for (i, c) in list.enumerated() {
            if let existing = cards.first(where: { $0.contact.id == c.id }) { select(existing); continue }
            let card = CardEntity(contact: c, brandHeader: brandHeader, defaultCC: defaultCC)
            let inLater = laterIDs.contains(c.id)
            let xz: SIMD2<Float> = inLater ? laterCenter
                : [Float.random(in: -0.12...0.02), Float.random(in: -0.02...0.07)]
            card.yaw = Float.random(in: -0.18...0.18)
            card.zone = inLater ? .later : .table
            let rest = supportHeight(at: xz, excluding: card) + CardSpec.thickness / 2
            card.setPose(xz: xz, restY: rest, lift: 0.18)           // dealt from above
            desk.addChild(card)
            cards.append(card)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 * Double(i)) {
                card.animate(lift: 0, duration: 0.28)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func select(_ c: CardEntity?) {
        selected?.setSelected(false)
        selected = c
        c?.setSelected(true)
        selectionBar.isHidden = (c == nil)
        if c != nil { UISelectionFeedbackGenerator().selectionChanged() }
    }

    // MARK: Desk-space maths

    /// Ray through a screen point, intersected with the table plane (desk Y = 0), as desk-space (x, z).
    private func planePoint(_ p: CGPoint) -> SIMD2<Float>? {
        guard let desk = deskEntity, let ray = arView.ray(through: p) else { return nil }
        let inv = desk.transformMatrix(relativeTo: nil).inverse
        let o = inv * SIMD4<Float>(ray.origin, 1)
        let d = inv * SIMD4<Float>(ray.direction, 0)
        guard abs(d.y) > 1e-5 else { return nil }
        let s = -o.y / d.y
        guard s > 0 else { return nil }
        return [o.x + s * d.x, o.z + s * d.z]
    }

    private func worldVelocity(at p: CGPoint, screen v: CGPoint) -> SIMD2<Float> {
        let dt: CGFloat = 0.05
        guard let a = planePoint(p), let b = planePoint(CGPoint(x: p.x + v.x * dt, y: p.y + v.y * dt)) else { return .zero }
        var w = (b - a) / Float(dt)
        let speed = simd_length(w)
        if speed > 2.5 { w *= 2.5 / speed }
        return w
    }

    private func clamp(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let mx = CardSpec.width * 0.3, mz = CardSpec.height * 0.3
        return [min(max(p.x, tableRect.min.x + mx), tableRect.max.x - mx),
                min(max(p.y, tableRect.min.y + mz), tableRect.max.y - mz)]
    }

    private func isInLater(_ p: SIMD2<Float>) -> Bool {
        abs(p.x - laterCenter.x) < laterSize.x / 2 && abs(p.y - laterCenter.y) < laterSize.y / 2
    }

    /// Height of the surface under a card at p: the table, the Later tray, or the top of any card it overlaps.
    /// (Axis-aligned overlap test: close enough for stacking, and cheap.)
    private func supportHeight(at p: SIMD2<Float>, excluding me: CardEntity) -> Float {
        var top: Float = isInLater(p) ? matThickness : 0
        for c in cards where c !== me && c.parent != nil {
            if abs(c.position.x - p.x) < CardSpec.width * 0.6 && abs(c.position.z - p.y) < CardSpec.height * 0.6 {
                top = max(top, c.restY + CardSpec.thickness / 2)
            }
        }
        return top
    }

    private func card(at p: CGPoint) -> CardEntity? {
        var e: Entity? = arView.entity(at: p)
        while let cur = e {
            if let c = cur as? CardEntity { return c }
            e = cur.parent
        }
        return nil
    }

    // MARK: Gestures

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        tap.require(toFail: dbl)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        let rot = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        [tap, dbl, pan, rot].forEach { $0.delegate = self; arView.addGestureRecognizer($0) }
    }

    /// Tap: place desk (first time) / select a card / deselect.
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: arView)
        guard deskEntity != nil else {
            if let hit = tableHit(at: arView.center) ?? tableHit(at: p) { placeDesk(at: hit) }
            return
        }
        select(card(at: p))
    }

    /// Double-tap: flip.
    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        guard let c = card(at: g.location(in: arView)) else { return }
        select(c)
        c.flip()
    }

    /// Two-finger twist: rotate the held / selected card on the table.
    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        guard g.state == .changed, let c = held ?? selected else { return }
        c.yaw -= Float(g.rotation)                                   // screen clockwise = negative yaw about +Y
        g.rotation = 0
    }

    /// Pan: pick up (lift) -> drag across the table -> drop / stack, or flick to throw.
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: arView)
        switch g.state {
        case .began:
            guard deskEntity != nil, let c = card(at: p), let w = planePoint(p) else { return }
            c.stopAllAnimations(recursive: true)
            c.velocity = .zero
            held = c
            select(c)
            grabOffset = c.xz - w                                    // keep the card under the same spot of your finger
            if c.zone == .later { c.zone = .table; persistLater() }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        case .changed:
            guard let c = held, let w = planePoint(p) else { return }
            let target = clamp(w + grabOffset)
            let next = c.xz + (target - c.xz) * 0.6                  // light smoothing
            let rest = supportHeight(at: next, excluding: c) + CardSpec.thickness / 2
            let lift = c.lift + (0.03 - c.lift) * 0.35               // ease up to a 3 cm pick-up
            c.setPose(xz: next, restY: rest, lift: lift)

        case .ended, .cancelled:
            guard let c = held else { return }
            held = nil
            let v = worldVelocity(at: p, screen: g.velocity(in: arView))
            if g.state == .ended, simd_length(v) > 0.45 { throwCard(c, v) } else { settle(c) }

        default: break
        }
    }

    // MARK: Throw / settle / stack

    private func throwCard(_ c: CardEntity, _ v0: SIMD2<Float>) {
        var v = v0
        // Aim assist: a flick roughly toward the Later tray lands in the tray.
        let toMat = laterCenter - c.xz
        let d = simd_length(toMat)
        if d > 0.05, simd_dot(simd_normalize(v), simd_normalize(toMat)) > 0.85 {
            v = simd_normalize(toMat) * d * friction                 // v0 / friction = distance travelled
        }
        c.velocity = v
        c.zone = .table
    }

    /// Per-frame: slide thrown cards, bounce softly off the table edge, ride up onto cards they hit.
    private func tick(_ dt: Float) {
        guard deskEntity != nil else { updateReticle(); return }
        for c in cards where c.velocity != .zero {
            c.velocity *= exp(-friction * dt)
            var p = c.xz + c.velocity * dt
            let lo = tableRect.min + [CardSpec.width * 0.3, CardSpec.height * 0.3]
            let hi = tableRect.max - [CardSpec.width * 0.3, CardSpec.height * 0.3]
            if p.x < lo.x { p.x = lo.x; c.velocity.x = abs(c.velocity.x) * 0.4 }
            if p.x > hi.x { p.x = hi.x; c.velocity.x = -abs(c.velocity.x) * 0.4 }
            if p.y < lo.y { p.y = lo.y; c.velocity.y = abs(c.velocity.y) * 0.4 }
            if p.y > hi.y { p.y = hi.y; c.velocity.y = -abs(c.velocity.y) * 0.4 }
            let rest = c.restY + (supportHeight(at: p, excluding: c) + CardSpec.thickness / 2 - c.restY) * min(1, dt * 20)
            c.setPose(xz: p, restY: rest, lift: c.lift * 0.85)
            if simd_length(c.velocity) < 0.03 { c.velocity = .zero; settle(c) }
        }
    }

    /// Put a card down: find what is under it, rest on top, add a little real-world mess if it landed on a stack.
    private func settle(_ c: CardEntity) {
        var p = c.xz
        let base: Float = isInLater(p) ? matThickness : 0
        let support = supportHeight(at: p, excluding: c)
        var yaw = c.yaw
        if support > base + 0.0001 {                                 // landed on other cards => stacked
            p += [Float.random(in: -0.002...0.002), Float.random(in: -0.002...0.002)]
            yaw += Float.random(in: -0.05...0.05)
        }
        let wasLater = c.zone == .later
        c.zone = isInLater(p) ? .later : .table
        c.animate(xz: p, restY: support + CardSpec.thickness / 2, lift: 0, yaw: yaw, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        if (c.zone == .later) != wasLater { persistLater() }
    }

    private func persistLater() {
        let ids = cards.filter { $0.zone == .later }.map { $0.contact.id }
        laterIDs = Set(ids)
        UserDefaults.standard.set(ids, forKey: "rolopro.ar.later")
        onLaterChanged?(ids)
    }

    // MARK: Selection bar actions

    @objc private func flipSelected() { selected?.flip() }
    @objc private func straightenSelected() { selected?.animate(yaw: 0, duration: 0.2) }
    @objc private func removeSelected() {
        guard let c = selected else { return }
        c.removeFromParent()
        cards.removeAll { $0 === c }
        select(nil)
        persistLater()
    }

    // MARK: HUD

    private func hudButton(_ symbol: String, _ title: String? = nil, _ action: Selector?) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = CardSpec.buttonFill
        cfg.baseForegroundColor = CardSpec.ink
        cfg.cornerStyle = .capsule
        cfg.image = UIImage(systemName: symbol)
        cfg.title = title
        cfg.imagePadding = 6
        cfg.background.strokeColor = CardSpec.goldEdge
        cfg.background.strokeWidth = 2
        let b = UIButton(configuration: cfg)
        if let a = action { b.addTarget(self, action: a, for: .touchUpInside) }
        return b
    }

    private func setupHUD() {
        let close = hudButton("xmark", nil, #selector(closeTapped))
        let reset = hudButton("arrow.counterclockwise", nil, #selector(resetTapped))

        hint.font = UIFont(name: "CourierPrime", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
        hint.textColor = CardSpec.ink
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.backgroundColor = CardSpec.buttonFill.withAlphaComponent(0.92)
        hint.layer.cornerRadius = 12
        hint.layer.masksToBounds = true

        addButton.setImage(UIImage(systemName: "plus.rectangle.on.rectangle"), for: .normal)
        var addCfg = UIButton.Configuration.filled()
        addCfg.baseBackgroundColor = CardSpec.buttonFill; addCfg.baseForegroundColor = CardSpec.ink
        addCfg.cornerStyle = .capsule; addCfg.image = UIImage(systemName: "plus.rectangle.on.rectangle"); addCfg.title = "Card"
        addCfg.imagePadding = 6; addCfg.background.strokeColor = CardSpec.goldEdge; addCfg.background.strokeWidth = 2
        addButton.configuration = addCfg
        addButton.showsMenuAsPrimaryAction = true
        addButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.addMenuItems() ?? []) }])

        let shutter = UIButton(type: .custom)
        shutter.backgroundColor = CardSpec.buttonFill
        shutter.layer.cornerRadius = 36
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = CardSpec.gold.cgColor
        shutter.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        shutter.accessibilityLabel = "Take photo"

        let flip = hudButton("arrow.left.arrow.right", "Flip", #selector(flipSelected))
        let straight = hudButton("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", "Straighten", #selector(straightenSelected))
        let remove = hudButton("trash", nil, #selector(removeSelected))
        [flip, straight, remove].forEach { selectionBar.addArrangedSubview($0) }
        selectionBar.axis = .horizontal; selectionBar.spacing = 8; selectionBar.isHidden = true

        for v in [close, reset, hint, addButton, shutter, selectionBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            close.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            reset.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            reset.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            hint.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 10),
            hint.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -32),   // side margins: text never touches the screen edge
            shutter.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            shutter.widthAnchor.constraint(equalToConstant: 72), shutter.heightAnchor.constraint(equalToConstant: 72),
            addButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            addButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            selectionBar.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: -14),
        ])
    }

    private func addMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "Deal 3 random", image: UIImage(systemName: "shuffle")) { [weak self] _ in
                guard let self = self else { return }
                self.deal(Array(self.contacts.shuffled().prefix(3)))
            }
        ]
        // The full list belongs in a searchable sheet; a menu is enough for a first pass.
        items += contacts.prefix(40).map { c in
            UIAction(title: c.name.isEmpty ? "(no name)" : c.name) { [weak self] _ in self?.deal([c]) }
        }
        return items
    }

    @objc private func closeTapped() { dismiss(animated: true) }
    @objc private func resetTapped() { resetDesk() }

    // MARK: Capture

    @objc private func captureTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        arView.snapshot(saveToHDR: false) { [weak self] image in       // camera feed + virtual cards, no HUD
            guard let self = self, let image = image else { return }
            let flash = UIView(frame: self.view.bounds)
            flash.backgroundColor = .white
            self.view.addSubview(flash)
            UIView.animate(withDuration: 0.25, animations: { flash.alpha = 0 }) { _ in flash.removeFromSuperview() }
            self.present(PhotoPreviewViewController(image: image), animated: true)
        }
    }
}
