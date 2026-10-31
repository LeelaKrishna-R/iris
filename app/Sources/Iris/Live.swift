import AppKit
import SpriteKit

/// Iris rigged from her own master picture, the way Live2D rigs one
/// illustration: the picture itself bends on a fine mesh (head tilt, turn
/// and nod at the neck, eyes that look, breathing, hair that swings on
/// springs), and only what must change is drawn over it — eyelids, happy
/// closed eyes, mouth shapes, a deeper blush (Resources/live, made by
/// iris/art/live.py from the master; her skin under them is her own). Every
/// layer is a full canvas bent by the same mesh, so they never drift apart
/// and her face stays exactly as painted: round, chubby, hers.
final class Live: SKNode {
    struct Params {
        var tilt: CGFloat = 0          // radians, + leans her head to her left (screen right)
        var turn: CGFloat = 0          // -1 … 1: face turns toward screen left/right
        var nod: CGFloat = 0           // + chin down
        var gaze = CGPoint.zero        // -1 … 1
        var lid: CGFloat = 0           // 0 open … 1 shut
        var happy = false              // ^ ^
        var mouth = ""                 // "" her own smile, else a/o/e/i/laugh/smile_open/pout/frown/flat/cat/wobble/grin
        var blush: CGFloat = 0         // the extra blush, 0…1
        var breath: CGFloat = 0        // -1 … 1
        var stride: CGFloat = 0        // 0 standing … 1 walking (legs step)
        var step: CGFloat = 0          // walk cycle phase, radians (one step per π)
        var dir: CGFloat = 0           // -1 heading left, 1 right
        var wave: CGFloat = 0          // waving pose: the hand's swing, -1 … 1
        var tap: CGFloat = 0           // laptop pose: the typing hand's dip, 0 … 1
    }

    static let mouths = ["a", "o", "e", "i", "laugh", "smile_open", "pout", "frown", "flat", "cat", "wobble", "grin"]

    private(set) var ok = false
    let pose: String
    private let size: CGSize
    private var elbow: CGPoint?, hand: CGPoint?, blanket: CGPoint?
    private var base: SKSpriteNode!
    private var layers: [String: SKSpriteNode] = [:]
    private var neck = CGPoint(x: 0.5, y: 0.5), face = CGPoint(x: 0.5, y: 0.6)
    private var eyes: [CGPoint] = []
    private var shoulders: CGFloat = 0.45
    private var hem: CGFloat = 0.22, feet: CGFloat = 0.01, legGap: CGFloat = 0.49
    private let cols = 30, rows = 44
    private var src: [SIMD2<Float>] = []
    // hair springs (side strands): offset and velocity, in canvas widths
    private var hair: [CGFloat] = [0, 0], hairV: [CGFloat] = [0, 0]
    private var lastTilt: CGFloat = 0, lastTurn: CGFloat = 0
    private var clock: CGFloat = 0

    /// `size`: her standing picture's size on screen; a wider pose (lying down) is drawn wider at the same scale.
    init(size standing: CGSize, pose: String) {
        self.pose = pose
        var sz = standing
        let dir = "live/" + pose
        if let url = SpriteView.art.url(forResource: "live", withExtension: "json", subdirectory: dir),
           let data = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["size"] as? [Double] {
            sz.width = standing.width * CGFloat(c[0]) / 434
        }
        self.size = sz
        self.dir = dir
        super.init()
        guard let url = SpriteView.art.url(forResource: "live", withExtension: "json", subdirectory: dir),
              let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func pt(_ k: String) -> CGPoint? { (j[k] as? [Double]).map { CGPoint(x: $0[0], y: $0[1]) } }
        elbow = pt("elbow"); hand = pt("hand"); blanket = pt("body")
        neck = pt("neck") ?? neck
        face = pt("face") ?? face
        if let e = j["eyes"] as? [String: [Double]] { eyes = e.values.map { CGPoint(x: $0[0], y: $0[1]) } }
        shoulders = CGFloat(j["shoulders"] as? Double ?? 0.45)
        hem = CGFloat(j["hem"] as? Double ?? 0.22)
        feet = CGFloat(j["feet"] as? Double ?? 0.01)
        legGap = CGFloat(j["leg_gap"] as? Double ?? 0.49)
        guard let b = sprite("base") else { return }
        base = b
        base.zPosition = 0
        var z: CGFloat = 1
        for n in ["blush", "lid3", "happy"] + Live.mouths.map({ "m_" + $0 }) {
            guard let s = sprite(n) else { continue }
            s.zPosition = z; z += 0.1
            s.isHidden = true
            layers[n] = s
        }
        for r in 0...rows { for c in 0...cols { src.append(SIMD2(Float(c) / Float(cols), Float(r) / Float(rows))) } }
        ok = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private let dir: String

    private func sprite(_ name: String) -> SKSpriteNode? {
        guard let u = SpriteView.art.url(forResource: name, withExtension: "png", subdirectory: dir),
              let t = Textures.load(u, drawnAt: size) else { return nil }
        let s = SKSpriteNode(texture: t, size: size)
        s.anchorPoint = CGPoint(x: 0.5, y: 0)
        addChild(s)
        return s
    }

    func apply(_ p: Params, dt: CGFloat, vx: CGFloat) {
        guard ok else { return }
        clock += dt
        // what shows over her picture
        // her eyes are open or shut, both her own drawings
        // (iris/art/live.py); the half-shut lids were skin patches over her eyes and are gone
        layers["lid3"]?.isHidden = p.happy || p.lid <= 0.85
        layers["happy"]?.isHidden = !p.happy
        for m in Live.mouths { layers["m_" + m]?.isHidden = p.mouth != m }
        if let b = layers["blush"] {
            b.isHidden = p.blush < 0.03
            b.alpha = min(1, p.blush)
        }

        // hair on springs: pushed when her head moves and when she travels
        let headV = (p.tilt - lastTilt) / max(dt, 0.001) + (p.turn - lastTurn) / max(dt, 0.001) * 0.3
        lastTilt = p.tilt; lastTurn = p.turn
        for i in 0..<2 {
            let push = -headV * 0.010 - vx * 0.00006 * (i == 0 ? 1 : 1.25)
            let acc = -30 * hair[i] - 3.6 * hairV[i] + push * 30
            hairV[i] += acc * dt
            hair[i] = max(-0.05, min(0.05, hair[i] + hairV[i] * dt))
        }

        let grid = warp(p)
        base.warpGeometry = grid
        for s in layers.values where !s.isHidden { s.warpGeometry = grid }
    }

    /// Where each mesh point of her picture goes this frame (0…1 canvas, y up).
    private func warp(_ p: Params) -> SKWarpGeometryGrid {
        let aspect = Float(size.height / size.width)
        let a = Float(-p.tilt), ca = cos(a), sa = sin(a)
        let nx = Float(neck.x), ny = Float(neck.y), fx = Float(face.x), fy = Float(face.y)
        let turn = Float(p.turn), nod = Float(p.nod), breath = Float(p.breath)
        let gx = Float(p.gaze.x), gy = Float(p.gaze.y)
        let sh = Float(shoulders)
        let hemY = Float(hem), feetY = Float(feet), gap = Float(legGap)
        let stride = Float(p.stride), sStep = Float(sin(p.step)), cStep = Float(cos(p.step)), dir = Float(p.dir)
        let waveA = Float(p.wave) * 0.32, cw = cos(waveA), sw = sin(waveA)
        let el = elbow.map { SIMD2(Float($0.x), Float($0.y)) }, hd = hand.map { SIMD2(Float($0.x), Float($0.y)) }
        let tap = Float(p.tap), bl = blanket.map { SIMD2(Float($0.x), Float($0.y)) }
        let c = Float(clock)
        let idleSway = sin(c * 1.1) * 0.004 + sin(c * 0.43 + 2) * 0.003
        let hairL = Float(hair[0]) + idleSway, hairR = Float(hair[1]) + idleSway * 0.8
        var dst = [SIMD2<Float>]()
        dst.reserveCapacity(src.count)
        for q in src {
            var x = q.x, y = q.y
            // how much of the head this point is: all of it above the chin, none below the collar
            let wh = smooth(ny - 0.035, ny + 0.06, y)
            // distance from the middle of her face (in canvas widths)
            let dfx = x - fx, dfy = (y - fy) * aspect
            let wf = exp(-(dfx * dfx + dfy * dfy) / (2 * 0.15 * 0.15))
            if wh > 0 {
                // turning: the face moves further than the outline of her head (depth)
                x += turn * (0.020 * wf + 0.008) * wh
                // the hair behind moves the other way a little
                let outer = smooth(0.20, 0.36, abs(dfx))
                x -= turn * 0.006 * outer * wh
                // nodding: features slide down, the top of the head comes forward
                y -= nod * 0.010 * wf * wh
                // breathing lifts her head a touch
                y += 0.0025 * breath * wh
                // tilting: everything above the neck turns about it
                let dx = x - nx, dy = (y - ny) * aspect
                let rx = dx * ca - dy * sa, ry = dx * sa + dy * ca
                x += (rx - dx) * wh
                y += ((ry - dy) / aspect) * wh
            }
            // eyes look: the middle of each eye shifts, the lashes hardly at all
            for e in eyes {
                let ex = q.x - Float(e.x), ey = (q.y - Float(e.y)) * aspect
                let we = exp(-(ex * ex + ey * ey) / (2 * 0.032 * 0.032))
                if we > 0.01 { x += gx * 0.010 * we * wh; y += gy * 0.007 * we * wh }
            }
            // breathing: chest and shoulders rise and widen
            let chest = bell(sh - 0.04, 0.09, q.y)
            x = 0.5 + (x - 0.5) * (1 + 0.012 * breath * chest)
            y += 0.004 * breath * chest
            // long hair: the strands beside her body swing, most at the tips
            let side = smooth(0.17, 0.32, abs(q.x - 0.5))
            let below = smooth(sh + 0.12, sh - 0.25, q.y)
            if pose != "sleep" { x += (q.x < 0.5 ? hairL : hairR) * side * below }
            // waving: the forearm and hand swing about the elbow
            if let el, let hd, p.wave != 0 {
                let reach = simd_length((hd - el) * SIMD2(1, aspect))
                let d = simd_length((SIMD2(q.x, q.y) - el) * SIMD2(1, aspect))
                let along = simd_dot((SIMD2(q.x, q.y) - el) * SIMD2(1, aspect), (hd - el) * SIMD2(1, aspect)) / (reach * reach)
                let w = smooth(0.15, 0.6, along) * smooth(reach * 1.6, reach * 1.1, d)
                if w > 0 {
                    let dx = (x - el.x), dy = (y - el.y) * aspect
                    x += (dx * cw - dy * sw - dx) * w
                    y += ((dx * sw + dy * cw - dy) / aspect) * w
                }
            }
            // typing: the hand on the keys dips with each keystroke
            if let hd, tap > 0, p.wave == 0 {
                let ex = q.x - hd.x, ey = (q.y - hd.y) * aspect
                y -= tap * 0.008 * exp(-(ex * ex + ey * ey) / (2 * 0.05 * 0.05))
            }
            // asleep: the blanket rises and falls with her breath
            if let bl {
                let ex = q.x - bl.x, ey = (q.y - bl.y) * aspect
                let w = exp(-(ex * ex + ey * ey) / (2 * 0.16 * 0.16))
                y += 0.006 * breath * w * smooth(bl.y - 0.25, bl.y + 0.05, q.y)
                x = x + (x - bl.x) * 0.012 * breath * w
            }
            // walking: each foot lifts in turn (most at the shoe, nothing at the hem) and
            // swings a little toward where she's going; the skirt sways with her hips
            if stride > 0.01 && q.y < hemY + 0.05 {
                let legW = smooth(hemY, feetY + 0.02, q.y)
                let left = smooth(gap + 0.012, gap - 0.012, q.x)          // 1 on her left leg (screen left)
                let lift = (left * max(0, sStep) + (1 - left) * max(0, -sStep)) * legW
                y += lift * 0.045 * stride
                x += lift * dir * 0.018 * stride
                let skirt = bell(hemY + 0.03, 0.03, q.y)
                x += cStep * 0.006 * stride * skirt
            }
            dst.append(SIMD2(x, y))
        }
        return SKWarpGeometryGrid(columns: cols, rows: rows, sourcePositions: src, destinationPositions: dst)
    }

    private func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private func bell(_ c: Float, _ w: Float, _ x: Float) -> Float { exp(-((x - c) * (x - c)) / (2 * w * w)) }
}
