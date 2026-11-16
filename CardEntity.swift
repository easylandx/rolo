import RealityKit
import UIKit
import simd

/// One contact card.
///
///  CardEntity (root)  position = card centre in desk space, orientation = yaw only, collision box for hit-testing
///   ├─ body          flips about the card's long axis (X)
///   │   ├─ edge      slim box = paper thickness
///   │   ├─ front     quad just above the box (texture: front)
///   │   └─ back      quad just below the box (texture: back with QR)
///   ├─ shadow        stays on the surface under the card, grows/fades as the card is lifted
///   └─ ring          gold outline on the surface, visible when selected
@MainActor
final class CardEntity: Entity, HasCollision {
    enum Zone { case table, later }

    let contact: RoloContact
    private let body = Entity()
    private let shadow: ModelEntity
    private let ring: ModelEntity

    private(set) var isFaceDown = false
    var zone: Zone = .table
    var velocity = SIMD2<Float>.zero                 // m/s in desk space (xz), non-zero while sliding
    var restY: Float = CardSpec.thickness / 2        // centre height when resting on whatever is below
    private(set) var lift: Float = 0                 // extra height above restY

    var yaw: Float = 0 {
        didSet { orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) }
    }
    var xz: SIMD2<Float> { [position.x, position.z] }

    required init() { fatalError("use init(contact:)") }

    init(contact: RoloContact, brandHeader: Bool = true, defaultCC: String = "") {
        self.contact = contact
        let w = CardSpec.width, h = CardSpec.height, t = CardSpec.thickness

        let edge = ModelEntity(mesh: .generateBox(size: [w - 0.0004, t, h - 0.0004]),
                               materials: [CardMaterials.paperEdge()])
        let front = ModelEntity(mesh: Self.quad(w: w, h: h, y: t / 2 + 0.00002, facingUp: true),
                                materials: [CardMaterials.paperFace(CardRenderer.front(contact, brandHeader: brandHeader))])
        let back = ModelEntity(mesh: Self.quad(w: w, h: h, y: -(t / 2 + 0.00002), facingUp: false),
                               materials: [CardMaterials.paperFace(CardRenderer.back(contact, defaultCC: defaultCC))])

        let s = CardRenderer.shadowScale
        shadow = ModelEntity(mesh: .generatePlane(width: w * s.x, depth: h * s.y),
                             materials: [CardMaterials.overlay(CardRenderer.shadow())])
        ring = ModelEntity(mesh: .generatePlane(width: w * s.x, depth: h * s.y),
                           materials: [CardMaterials.overlay(CardRenderer.ring())])
        super.init()

        body.addChild(edge); body.addChild(front); body.addChild(back)
        addChild(body); addChild(shadow); addChild(ring)
        ring.isEnabled = false
        name = contact.id

        collision = CollisionComponent(shapes: [.generateBox(size: [w, t + 0.012, h])])
        layoutShadow(duration: 0)
    }

    // MARK: Geometry

    /// Flat quad with explicit normals + UVs.
    ///
    /// Vertex order A(-x,-z) B(+x,-z) C(+x,+z) D(-x,+z), viewed from +Y with the card "top" toward -Z.
    /// RealityKit's V axis points up the image (V = 1 is the image's top row).
    /// Front: image top sits at -Z.  Back: image top sits at +Z, so it reads upright after the card is
    /// flipped about its long (X) axis.  If your textures ever look upside-down, swap the two V rows below.
    private static func quad(w: Float, h: Float, y: Float, facingUp: Bool) -> MeshResource {
        let hw = w / 2, hh = h / 2
        var d = MeshDescriptor(name: facingUp ? "front" : "back")
        d.positions = MeshBuffers.Positions([[-hw, y, -hh], [hw, y, -hh], [hw, y, hh], [-hw, y, hh]])
        d.normals = MeshBuffers.Normals(Array(repeating: [0, facingUp ? 1 : -1, 0], count: 4))
        d.textureCoordinates = MeshBuffers.TextureCoordinates(
            facingUp ? [[0, 1], [1, 1], [1, 0], [0, 0]]
                     : [[0, 0], [1, 0], [1, 1], [0, 1]])
        d.primitives = .triangles(facingUp ? [0, 3, 2, 0, 2, 1] : [0, 2, 3, 0, 1, 2])   // counter-clockwise seen from outside
        return try! MeshResource.generate(from: [d])
    }

    // MARK: Pose

    /// Immediate pose (used while dragging / sliding, no animation).
    func setPose(xz p: SIMD2<Float>, restY newRest: Float? = nil, lift newLift: Float? = nil) {
        if let r = newRest { restY = r }
        if let l = newLift { lift = l }
        position = [p.x, restY + lift, p.y]
        layoutShadow(duration: 0)
    }

    /// Animated settle / lift.
    func animate(xz p: SIMD2<Float>? = nil, restY newRest: Float? = nil, lift newLift: Float? = nil,
                 yaw newYaw: Float? = nil, duration: TimeInterval = 0.12) {
        if let r = newRest { restY = r }
        if let l = newLift { lift = l }
        if let y = newYaw { yaw = y }
        let target = p ?? xz
        var tr = Transform(scale: .one, rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]),
                           translation: [target.x, restY + lift, target.y])
        tr.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        move(to: tr, relativeTo: parent, duration: duration, timingFunction: .easeInOut)
        layoutShadow(duration: duration)
    }

    func setSelected(_ on: Bool) { ring.isEnabled = on }

    /// Shadow + ring live on the surface under the card, whatever the card's own height is.
    private func layoutShadow(duration: TimeInterval) {
        let y = -(lift + CardSpec.thickness / 2) + 0.0003
        let k = 1 + lift * 9                                  // higher => larger, softer footprint
        let s = Transform(scale: [k, 1, k], rotation: .init(), translation: [0, y, 0])
        let r = Transform(scale: [1, 1, 1], rotation: .init(), translation: [0, y + 0.0002, 0])
        if duration > 0 {
            shadow.move(to: s, relativeTo: self, duration: duration)
            ring.move(to: r, relativeTo: self, duration: duration)
        } else {
            shadow.transform = s
            ring.transform = r
        }
    }

    // MARK: Flip

    /// Lifts the card, turns it 180° about its long axis, sets it down again.
    func flip() {
        isFaceDown.toggle()
        let mid = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let end = simd_quatf(angle: isFaceDown ? .pi : 0, axis: [1, 0, 0])
        let before = lift
        Task { @MainActor in
            animate(lift: 0.07, duration: 0.14)                 // must clear half the card height while it stands on edge
            body.move(to: Transform(scale: .one, rotation: mid, translation: .zero),
                      relativeTo: self, duration: 0.14, timingFunction: .easeIn)
            try? await Task.sleep(nanoseconds: 150_000_000)
            body.move(to: Transform(scale: .one, rotation: end, translation: .zero),
                      relativeTo: self, duration: 0.16, timingFunction: .easeOut)
            animate(lift: before, duration: 0.16)
            try? await Task.sleep(nanoseconds: 170_000_000)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
