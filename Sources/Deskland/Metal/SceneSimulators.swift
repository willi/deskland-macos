import Foundation
import AppKit
import CoreGraphics
import Metal
import simd

struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed
    }

    mutating func next() -> Float {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t ^= t &+ ((t ^ (t >> 7)) &* (61 | t))
        let out = t ^ (t >> 14)
        return Float(out) / 4294967296.0
    }
}

enum SpriteTextureLoader {
    static func resourceURL(_ subpath: String) -> URL? {
        if let url = Bundle.module.url(forResource: "Resources/\(subpath)", withExtension: nil) {
            return url
        }
        let ns = subpath as NSString
        let dir = "Resources/" + ns.deletingLastPathComponent
        let base = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext = ns.pathExtension
        if let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: dir) {
            return url
        }
        if let resDir = Bundle.main.resourceURL {
            let candidate = resDir.appendingPathComponent(subpath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func loadCGImage(_ subpath: String) -> CGImage? {
        guard let url = resourceURL(subpath),
              let src = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: src.size)
        return src.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func drawImageTopDown(
        _ ctx: CGContext,
        _ image: CGImage,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y + height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    static func unpremultiplyRGBA(_ bytes: inout [UInt8]) {
        let count = bytes.count
        var i = 0
        while i + 3 < count {
            let a = Int(bytes[i + 3])
            if a > 0 && a < 255 {
                bytes[i]     = UInt8(min(255, (Int(bytes[i]) * 255 + a / 2) / a))
                bytes[i + 1] = UInt8(min(255, (Int(bytes[i + 1]) * 255 + a / 2) / a))
                bytes[i + 2] = UInt8(min(255, (Int(bytes[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
    }

    static func makeSquareSpriteTexture(
        subpath: String,
        size: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> MTLTexture? {
        guard let cg = loadCGImage(subpath) else { return nil }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: size,
                      height: size,
                      bitsPerComponent: 8,
                      bytesPerRow: size * 4,
                      space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard ok else { return nil }
        unpremultiplyRGBA(&pixels)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: size * 4
        )
        if let cb = commandQueue.makeCommandBuffer(),
           let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return tex
    }
}

final class BeachSimulator {
    struct Kayak {
        var x: Float
        var y: Float
        var h: Float
        var v: Float
        var ph: Float
        var wander: Float
    }

    struct Seabird {
        var x: Float
        var y: Float
        var h: Float
        var v: Float
        var mode: Float
        var modeT: Float
        var ph: Float
        var flap: Bool
        var flapT: Float
        var wander: Float
    }

    struct Ripple {
        var x: Float
        var y: Float
        var age: Float
        var strength: Float
    }

    struct PalmStyle {
        let file: String
        let footX: CGFloat
        let footY: CGFloat
        let crownX: Float
        let crownY: Float
        let radius: Float
        let width: CGFloat
        let height: CGFloat
        let size: Float
        let faceSea: Bool
    }

    struct PalmInstance {
        var x: Float
        var y: Float
        var scale: Float
        var variant: Int
        var mirror: Float
        var opacity: Float
        var retiring: Bool
    }

    static let palmStyles: [PalmStyle] = [
        PalmStyle(file: "assets/beach-coconut-palm-v2.png",        footX: 0.454, footY: 0.98, crownX: 9,   crownY: -84, radius: 80, width: 168, height: 156, size: 1.0,  faceSea: false),
        PalmStyle(file: "assets/beach-coconut-palm-curved.png",    footX: 0.470, footY: 0.98, crownX: 18,  crownY: -80, radius: 84, width: 168, height: 156, size: 1.0,  faceSea: true),
        PalmStyle(file: "assets/beach-coconut-palm-airy.png",      footX: 0.415, footY: 0.98, crownX: 27,  crownY: -82, radius: 84, width: 168, height: 156, size: 1.0,  faceSea: false),
        PalmStyle(file: "assets/beach-coconut-palm-windswept.png", footX: 0.250, footY: 0.98, crownX: 40,  crownY: -78, radius: 78, width: 148, height: 138, size: 1.0,  faceSea: false),
        PalmStyle(file: "assets/beach-coconut-palm-arch.png",      footX: 0.840, footY: 0.98, crownX: -45, crownY: -65, radius: 70, width: 128, height: 119, size: 1.35, faceSea: true)
    ]

    private(set) var kayaks: [Kayak] = []
    private(set) var birds: [Seabird] = []
    private(set) var ripples: [Ripple] = []
    private(set) var palms: [PalmInstance] = []
    private var cachedPlacements: [PalmInstance]?
    private var lastPalmSignature: String = ""

    private(set) var palmAtlas: MTLTexture?
    private var atlasAttempted = false

    var hasActiveRipples: Bool {
        !ripples.isEmpty
    }

    func ensureAtlas(device: MTLDevice, commandQueue: MTLCommandQueue) {
        guard !atlasAttempted else { return }
        atlasAttempted = true
        palmAtlas = Self.buildPalmAtlas(device: device, commandQueue: commandQueue)
    }

    func resetForReseed() {
        kayaks.removeAll()
        cachedPlacements = nil
        lastPalmSignature = ""
    }

    func invalidatePalmLayout() {
        cachedPlacements = nil
        lastPalmSignature = ""
    }

    func addRipple(x: Float, y: Float, strength: Float = 1.0, field: TerrainField) {
        guard field.sample(x: x, y: y) > 2.0 else { return }
        if ripples.count >= 6 {
            ripples.removeFirst()
        }
        ripples.append(Ripple(x: x, y: y, age: 0, strength: strength))
    }

    func step(
        dt: Float,
        field: TerrainField,
        obstacles: [IconObstacle],
        seed: Int,
        wantKayaks: Int,
        wantBirds: Int,
        wantPalms: Int,
        bottomInset: Float,
        nightWeight: Float
    ) {
        let W = field.width
        let H = field.height

        for i in stride(from: ripples.count - 1, through: 0, by: -1) {
            ripples[i].age += dt
            if ripples[i].age >= 3.0 {
                ripples.remove(at: i)
            }
        }

        let kTarget = max(0, min(4, wantKayaks))
        syncKayaks(want: kTarget, field: field, bottomInset: bottomInset)
        stepKayaks(dt: dt, field: field, bottomInset: bottomInset)

        let nightFactor: Float = nightWeight > 0.75 ? 0.35 : 1.0
        let bTarget = max(0, min(8, Int((Float(wantBirds) * nightFactor).rounded())))
        syncBirds(want: bTarget, width: W, height: H, bottomInset: bottomInset)
        stepBirds(dt: dt, width: W, height: H, bottomInset: bottomInset)

        let pTarget = max(0, min(10, wantPalms))
        let sig = "\(Int(W))x\(Int(H)):\(seed):\(obstacles.count):\(obstacles.first?.x ?? 0):\(obstacles.last?.y ?? 0)"
        if sig != lastPalmSignature {
            lastPalmSignature = sig
            cachedPlacements = pTarget > 0 ? choosePalms(field: field, obstacles: obstacles, seed: seed, bottomInset: bottomInset) : []
            reconcilePalms(want: pTarget, field: field)
        } else if (cachedPlacements == nil && pTarget > 0) {
            cachedPlacements = choosePalms(field: field, obstacles: obstacles, seed: seed, bottomInset: bottomInset)
            reconcilePalms(want: pTarget, field: field)
        } else {
            let activeNonRetiring = palms.filter { !$0.retiring }.count
            let desiredActive = min(pTarget, cachedPlacements?.count ?? 0)
            if activeNonRetiring != desiredActive {
                reconcilePalms(want: pTarget, field: field)
            }
        }

        let fadeRate = 1.0 - exp(-dt * 4.0)
        for i in stride(from: palms.count - 1, through: 0, by: -1) {
            let onSand = simd_clamp(-field.sample(x: palms[i].x, y: palms[i].y) / 4.0, 0, 1)
            let target: Float = palms[i].retiring ? 0.0 : onSand
            palms[i].opacity += (target - palms[i].opacity) * fadeRate
            if palms[i].retiring && palms[i].opacity < 0.003 {
                palms.remove(at: i)
            }
        }
    }

    private func spawnKayak(field: TerrainField, bottomInset: Float) -> Kayak? {
        let W = field.width
        let H2 = max(120, field.height - bottomInset)
        guard W > 140, H2 > 140 else { return nil }
        for _ in 0..<320 {
            let x = 60 + Float.random(in: 0..<(W - 120))
            let y = 60 + Float.random(in: 0..<(H2 - 120))
            if field.sample(x: x, y: y) > 170 &&
               kayaks.allSatisfy({ hypot($0.x - x, $0.y - y) > 160 }) {
                return Kayak(
                    x: x,
                    y: y,
                    h: Float.random(in: 0..<(2 * .pi)),
                    v: Float.random(in: 7...11),
                    ph: Float.random(in: 0...6),
                    wander: Float.random(in: 0...100)
                )
            }
        }
        return nil
    }

    private func syncKayaks(want: Int, field: TerrainField, bottomInset: Float) {
        while kayaks.count > want { kayaks.removeLast() }
        while kayaks.count < want {
            guard let k = spawnKayak(field: field, bottomInset: bottomInset) else { break }
            kayaks.append(k)
        }
    }

    private func stepKayaks(dt: Float, field: TerrainField, bottomInset: Float) {
        guard !kayaks.isEmpty else { return }
        let W = field.width
        let H2 = max(100, field.height - bottomInset)
        let clearance: Float = 64.0
        var plans: [(h: Float, dx: Float, dy: Float)] = []
        plans.reserveCapacity(kayaks.count)

        for i in 0..<kayaks.count {
            var heading = kayaks[i].h
            let ax = kayaks[i].x + cos(heading) * 70
            let ay = kayaks[i].y + sin(heading) * 70
            let margin = ax < 40 || ay < 40 || ax > W - 40 || ay > H2 - 40
            if field.sample(x: ax, y: ay) < 150 || margin {
                var gx = field.sample(x: kayaks[i].x + 10, y: kayaks[i].y) - field.sample(x: kayaks[i].x - 10, y: kayaks[i].y)
                var gy = field.sample(x: kayaks[i].x, y: kayaks[i].y + 10) - field.sample(x: kayaks[i].x, y: kayaks[i].y - 10)
                if margin {
                    gx += (W * 0.5 - kayaks[i].x) * 0.02
                    gy += (H2 * 0.5 - kayaks[i].y) * 0.02
                }
                var d = atan2(gy, gx) - kayaks[i].h
                d = atan2(sin(d), cos(d))
                heading += (d >= 0 ? 1 : -1) * min(abs(d), 0.7 * dt)
            } else {
                kayaks[i].wander += dt * 0.3
                let n = Float(TerrainField.vnoise(Double(kayaks[i].wander), Double(i * 10), 11.0))
                heading += (n - 0.5) * 0.25 * dt
            }

            let fx = cos(kayaks[i].h)
            let fy = sin(kayaks[i].h)
            var steerX = cos(heading)
            var steerY = sin(heading)
            var speed: Float = 1.0
            var avoiding = false

            for j in 0..<kayaks.count where i != j {
                let other = kayaks[j]
                let dx = other.x - kayaks[i].x
                let dy = other.y - kayaks[i].y
                let dist = hypot(dx, dy)
                if dist > 210 { continue }
                let rvx = cos(other.h) * other.v - fx * kayaks[i].v
                let rvy = sin(other.h) * other.v - fy * kayaks[i].v
                let closing = dx * rvx + dy * rvy
                let ahead = simd_clamp(-closing / max(0.01, rvx * rvx + rvy * rvy), 0, 7)
                let closest = hypot(dx + rvx * ahead, dy + rvy * ahead)
                let r1 = simd_clamp((110 - dist) / 46, 0, 1)
                let r2: Float = closing < 0 ? (1 - min(1, closest / 90)) * (1 - ahead / 8) : 0
                let risk = max(r1, r2)
                if risk <= 0 { continue }
                avoiding = true
                let awayX = dist > 0.001 ? -dx / dist : -fy
                let awayY = dist > 0.001 ? -dy / dist : fx
                steerX += (awayX * 2.0 - fy * 1.6) * risk
                steerY += (awayY * 2.0 + fx * 1.6) * risk
                if dx * fx + dy * fy > 0 && closing < 0 {
                    speed = min(speed, 0.25 + 0.75 * simd_clamp((dist - clearance) / 50, 0, 1))
                }
            }

            if avoiding {
                let targetA = atan2(steerY, steerX)
                let d = atan2(sin(targetA - kayaks[i].h), cos(targetA - kayaks[i].h))
                heading = kayaks[i].h + (d >= 0 ? 1 : -1) * min(abs(d), dt)
            }

            kayaks[i].ph += dt * 2.4
            let v = kayaks[i].v * (0.75 + 0.25 * abs(sin(kayaks[i].ph))) * speed
            plans.append((heading, cos(heading) * v * dt, sin(heading) * v * dt))
        }

        for _ in 0..<kayaks.count {
            for i in 0..<kayaks.count {
                if i + 1 >= kayaks.count { continue }
                for j in (i + 1)..<kayaks.count {
                    let dx = kayaks[j].x - kayaks[i].x
                    let dy = kayaks[j].y - kayaks[i].y
                    let vx = plans[j].dx - plans[i].dx
                    let vy = plans[j].dy - plans[i].dy
                    let vv = vx * vx + vy * vy
                    let dot = dx * vx + dy * vy
                    if dot >= 0 || vv < 1e-12 { continue }
                    let closestAt = simd_clamp(-dot / vv, 0, 1)
                    if hypot(dx + vx * closestAt, dy + vy * closestAt) >= clearance { continue }
                    let gap = dx * dx + dy * dy - clearance * clearance
                    let frac: Float = gap <= 0 ? 0 : simd_clamp(gap / (-dot + sqrt(max(0, dot * dot - vv * gap))) - 0.001, 0, 1)
                    plans[i].dx *= frac; plans[i].dy *= frac
                    plans[j].dx *= frac; plans[j].dy *= frac
                }
            }
        }

        for i in stride(from: kayaks.count - 1, through: 0, by: -1) {
            kayaks[i].h = plans[i].h
            kayaks[i].x += plans[i].dx
            kayaks[i].y += plans[i].dy
            if field.sample(x: kayaks[i].x, y: kayaks[i].y) < 40 {
                if let replacement = spawnKayak(field: field, bottomInset: bottomInset) {
                    kayaks[i] = replacement
                } else {
                    kayaks.remove(at: i)
                }
            }
        }
    }

    private func spawnBird(fromEdge: Bool, width: Float, height: Float, bottomInset: Float) -> Seabird {
        let H2 = max(100, height - bottomInset)
        var x = Float.random(in: 0..<max(100, width))
        var y = Float.random(in: 0..<H2)
        if fromEdge {
            let side = Int.random(in: 0..<4)
            switch side {
            case 0: x = -40
            case 1: x = width + 40
            case 2: y = -40
            default: y = H2 + 40
            }
        }
        let h = atan2(H2 * 0.5 - y, width * 0.5 - x) + Float.random(in: -0.6...0.6)
        return Seabird(
            x: x, y: y, h: h,
            v: Float.random(in: 36...52),
            mode: 0, modeT: Float.random(in: 2...6),
            ph: 0, flap: false, flapT: Float.random(in: 0...3),
            wander: Float.random(in: 0...100)
        )
    }

    private func syncBirds(want: Int, width: Float, height: Float, bottomInset: Float) {
        let initial = birds.isEmpty
        while birds.count > want { birds.removeLast() }
        while birds.count < want {
            birds.append(spawnBird(fromEdge: !initial, width: width, height: height, bottomInset: bottomInset))
        }
    }

    private func stepBirds(dt: Float, width: Float, height: Float, bottomInset: Float) {
        let H2 = max(100, height - bottomInset)
        let m: Float = 90
        for i in 0..<birds.count {
            birds[i].modeT -= dt
            if birds[i].modeT <= 0 {
                birds[i].mode = Float.random(in: 0...1) < 0.4 ? (Bool.random() ? -1 : 1) : 0
                birds[i].modeT = birds[i].mode != 0 ? Float.random(in: 4...10) : Float.random(in: 3...8)
            }
            birds[i].wander += dt * 0.4
            if birds[i].x < -m || birds[i].x > width + m || birds[i].y < -m || birds[i].y > H2 + m {
                let target = atan2(H2 * 0.5 - birds[i].y, width * 0.5 - birds[i].x)
                let d = atan2(sin(target - birds[i].h), cos(target - birds[i].h))
                birds[i].h += (d >= 0 ? 1 : -1) * min(abs(d), 1.3 * dt)
            } else {
                let n = Float(TerrainField.vnoise(Double(birds[i].wander), Double(i) * 7.3, 19.0))
                birds[i].h += (birds[i].mode * 0.55 + (n - 0.5) * 0.8) * dt
            }
            birds[i].flapT -= dt
            if birds[i].flapT <= 0 {
                birds[i].flap.toggle()
                birds[i].flapT = birds[i].flap ? Float.random(in: 0.8...2.0) : Float.random(in: 2.5...6.5)
            }
            if birds[i].flap || cos(birds[i].ph) < 0.97 {
                birds[i].ph = (birds[i].ph + dt * 9.0).truncatingRemainder(dividingBy: 2 * .pi)
            }
            let v = birds[i].v * (birds[i].flap ? 1.15 : 1.0)
            birds[i].x += cos(birds[i].h) * v * dt
            birds[i].y += sin(birds[i].h) * v * dt
        }
    }

    private func reconcilePalms(want: Int, field: TerrainField) {
        let wasEmpty = palms.isEmpty
        let next = Array((cachedPlacements ?? []).prefix(want))
        for i in 0..<palms.count {
            palms[i].retiring = true
        }
        for p in next {
            if let idx = palms.firstIndex(where: {
                hypot($0.x - p.x, $0.y - p.y) < 26 && abs($0.scale - p.scale) < 0.02 && $0.mirror == p.mirror
            }) {
                palms[idx].retiring = false
                palms[idx].variant = p.variant
            } else {
                var fresh = p
                fresh.opacity = wasEmpty ? simd_clamp(-field.sample(x: p.x, y: p.y) / 4.0, 0, 1) : 0
                fresh.retiring = false
                palms.append(fresh)
            }
        }
    }

    private func choosePalms(
        field: TerrainField,
        obstacles: [IconObstacle],
        seed: Int,
        bottomInset: Float
    ) -> [PalmInstance] {
        let W = field.width
        let H = field.height
        var rng = Mulberry32(seed: UInt32(truncatingIfNeeded: seed) ^ 0x41FC72)
        var styleRng = Mulberry32(seed: UInt32(truncatingIfNeeded: seed) ^ 0x6AC309)

        var order = Array(0..<Self.palmStyles.count)
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() * Float(i + 1))
            order.swapAt(i, min(i, j))
        }
        while order.count < 10 {
            order.append(min(Self.palmStyles.count - 1, Int(styleRng.next() * Float(Self.palmStyles.count))))
        }

        func palmClear(_ px: Float, _ py: Float, _ radius: Float) -> Bool {
            for ob in obstacles {
                let dx = max(ob.x - 7 - px, max(0, px - ob.x - ob.w - 7))
                let dy = max(ob.y - 7 - py, max(0, py - ob.y - ob.h - 7))
                if hypot(dx, dy) <= radius { return false }
            }
            return true
        }

        var chosen: [PalmInstance] = []
        for variant in order {
            let style = Self.palmStyles[variant]
            let spacing: Float = 60.0 + rng.next() * 35.0
            let scale: Float = 0.62 * 0.80 * style.size
            let radius = style.radius * scale
            let offsetX = rng.next() * 13.0
            let offsetY = rng.next() * 13.0

            var best: PalmInstance?
            var candidates: Float = 0

            var y = 100.0 * scale + offsetY
            let maxY = H - bottomInset - 55.0 * scale
            let maxX = W - radius - 5.0
            while y < maxY {
                var x = radius + 5.0 + offsetX
                while x < maxX {
                    let shore = field.sampleB(x: x, y: y)
                    if shore <= -25.0 && shore >= -58.0 {
                        let tooClose = chosen.contains { hypot($0.x - x, $0.y - y) < spacing }
                        if !tooClose {
                            let seaX: Float = style.faceSea ? (field.sampleB(x: x + 8, y: y) - field.sampleB(x: x - 8, y: y)) : 0
                            let mirror: Float = (style.faceSea && seaX * style.crownX < 0) ? -1.0 : 1.0
                            let crownX = x + style.crownX * scale * mirror
                            let crownY = y + style.crownY * scale
                            if crownX >= radius + 3 && crownX <= W - radius - 3 &&
                               crownY >= radius + 3 &&
                               palmClear(x, y - 16 * scale, 10 * scale) &&
                               palmClear(crownX, crownY, radius) {
                                candidates += 1
                                if rng.next() < (1.0 / candidates) {
                                    best = PalmInstance(
                                        x: x, y: y, scale: scale, variant: variant,
                                        mirror: mirror, opacity: 0, retiring: false
                                    )
                                }
                            }
                        }
                    }
                    x += 13.0
                }
                y += 13.0
            }
            if let best {
                chosen.append(best)
            }
        }
        return chosen
    }

    private static func buildPalmAtlas(device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLTexture? {
        let cellW = 224
        let cellH = 256
        let scale = 2
        let atlasW = cellW * palmStyles.count * scale
        let atlasH = cellH * scale

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var atlasBytes = [UInt8](repeating: 0, count: atlasW * atlasH * 4)

        let images = palmStyles.map { SpriteTextureLoader.loadCGImage($0.file) }
        guard images.allSatisfy({ $0 != nil }) else { return nil }

        atlasBytes.withUnsafeMutableBytes { rawAtlas in
            guard let atlasBase = rawAtlas.baseAddress,
                  let ctx = CGContext(
                      data: atlasBase,
                      width: atlasW,
                      height: atlasH,
                      bitsPerComponent: 8,
                      bytesPerRow: atlasW * 4,
                      space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }

            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(atlasH))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

            for (variant, style) in palmStyles.enumerated() {
                guard let image = images[variant] else { continue }
                let footX = style.footX * style.width
                let footY = style.footY * style.height

                let shW = cellW * scale
                let shH = cellH * scale
                var shadowBytes = [UInt8](repeating: 0, count: shW * shH * 4)
                shadowBytes.withUnsafeMutableBytes { rawSh in
                    guard let shBase = rawSh.baseAddress,
                          let shCtx = CGContext(
                              data: shBase,
                              width: shW,
                              height: shH,
                              bitsPerComponent: 8,
                              bytesPerRow: shW * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          ) else { return }
                    shCtx.interpolationQuality = .high
                    shCtx.translateBy(x: 0, y: CGFloat(shH))
                    shCtx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                    shCtx.translateBy(x: 112, y: 162)
                    shCtx.concatenate(CGAffineTransform(a: 0.85, b: 0.08, c: 0, d: -0.50, tx: 0, ty: 0))
                    SpriteTextureLoader.drawImageTopDown(
                        shCtx, image,
                        x: -footX, y: -footY,
                        width: style.width, height: style.height
                    )
                }

                for p in stride(from: 0, to: shadowBytes.count, by: 4) {
                    let a = Int(shadowBytes[p + 3])
                    if a > 0 {
                        let sa = (a * 51) / 255
                        shadowBytes[p]     = UInt8((0x3C * sa) / 255)
                        shadowBytes[p + 1] = UInt8((0x62 * sa) / 255)
                        shadowBytes[p + 2] = UInt8((0x57 * sa) / 255)
                        shadowBytes[p + 3] = UInt8(sa)
                    }
                }

                ctx.saveGState()
                ctx.translateBy(x: CGFloat(variant * cellW), y: 0)

                if let shProvider = CGDataProvider(data: Data(shadowBytes) as CFData),
                   let shImage = CGImage(
                       width: shW,
                       height: shH,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: shW * 4,
                       space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: shProvider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent
                   ) {
                    SpriteTextureLoader.drawImageTopDown(ctx, shImage, x: 0, y: 0, width: CGFloat(cellW), height: CGFloat(cellH))
                }

                ctx.saveGState()
                ctx.setFillColor(red: 0x51 / 255.0, green: 0x60 / 255.0, blue: 0x51 / 255.0, alpha: 0.17)
                ctx.fillEllipse(in: CGRect(x: 112 - 4.4, y: 162 - 1.6, width: 8.8, height: 3.2))
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: 112, y: 162)
                SpriteTextureLoader.drawImageTopDown(
                    ctx, image,
                    x: -footX, y: -footY,
                    width: style.width, height: style.height
                )
                ctx.restoreGState()

                ctx.restoreGState()
            }
        }

        SpriteTextureLoader.unpremultiplyRGBA(&atlasBytes)
        for i in stride(from: 0, to: atlasBytes.count, by: 4) {
            if atlasBytes[i + 3] == 0 { continue }
            var r = Float(atlasBytes[i])
            var g = Float(atlasBytes[i + 1])
            var b = Float(atlasBytes[i + 2])
            let yellow = simd_clamp((r / max(g, 1.0) - 0.60) / 0.35, 0, 1) * simd_clamp((g - b) / 50.0, 0, 1)
            r *= 1.0 - yellow * 0.22
            g *= 1.0 - yellow * 0.06
            b += yellow * 10.0
            let gray = r * 0.2126 + g * 0.7152 + b * 0.0722
            atlasBytes[i]     = UInt8(simd_clamp((gray + (r - gray) * 0.70) * 0.97, 0, 255))
            atlasBytes[i + 1] = UInt8(simd_clamp((gray + (g - gray) * 0.70) * 0.97, 0, 255))
            atlasBytes[i + 2] = UInt8(simd_clamp((gray + (b - gray) * 0.70) * 0.97, 0, 255))
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasW,
            height: atlasH,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, atlasW, atlasH),
            mipmapLevel: 0,
            withBytes: atlasBytes,
            bytesPerRow: atlasW * 4
        )
        if let cb = commandQueue.makeCommandBuffer(),
           let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return tex
    }
}

final class SpatialCircleGrid {
    static let cellG: Float = 48.0
    static let circK: Int = 36

    private(set) var cgW: Int = 0
    private(set) var cgH: Int = 0
    private(set) var texture: MTLTexture?
    private var buffer: [Float] = []
    private var counts: [UInt8] = []

    func upload(circles: [SIMD4<Float>], width: Float, height: Float, device: MTLDevice) {
        let gw = Int(ceil(width / Self.cellG)) + 7
        let gh = Int(ceil(height / Self.cellG)) + 7
        if texture == nil || gw != cgW || gh != cgH {
            cgW = gw
            cgH = gh
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float,
                width: gw * Self.circK,
                height: gh,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            texture = device.makeTexture(descriptor: desc)
            buffer = [Float](repeating: 0, count: gw * Self.circK * gh * 4)
            counts = [UInt8](repeating: 0, count: gw * gh)
        }
        guard let texture else { return }

        buffer.withUnsafeMutableBufferPointer { buf in
            buf.initialize(repeating: 0)
        }
        counts.withUnsafeMutableBufferPointer { cnt in
            cnt.initialize(repeating: 0)
        }

        let sorted = circles.sorted { $0.z > $1.z }
        let g = Self.cellG
        let kMax = UInt8(Self.circK)

        buffer.withUnsafeMutableBufferPointer { buf in
            counts.withUnsafeMutableBufferPointer { cnt in
                for c in sorted {
                    let x = c.x
                    let y = c.y
                    let r = c.z + 6.0
                    let x0 = max(0, Int(floor((x - r) / g)) + 4)
                    let x1 = min(gw - 1, Int(floor((x + r) / g)) + 4)
                    let y0 = max(0, Int(floor((y - r) / g)) + 4)
                    let y1 = min(gh - 1, Int(floor((y + r) / g)) + 4)
                    if x0 > x1 || y0 > y1 { continue }
                    let r2 = r * r
                    for gy in y0...y1 {
                        let cellMinY = Float(gy - 4) * g
                        let cellMaxY = Float(gy - 3) * g
                        let ny = simd_clamp(y, cellMinY, cellMaxY)
                        let dy2 = (ny - y) * (ny - y)
                        if dy2 > r2 { continue }
                        let rowBase = gy * gw
                        for gx in x0...x1 {
                            let ci = rowBase + gx
                            if cnt[ci] >= kMax { continue }
                            let cellMinX = Float(gx - 4) * g
                            let cellMaxX = Float(gx - 3) * g
                            let nx = simd_clamp(x, cellMinX, cellMaxX)
                            if (nx - x) * (nx - x) + dy2 > r2 { continue }
                            let slot = Int(cnt[ci])
                            cnt[ci] = UInt8(slot + 1)
                            let o = (ci * Self.circK + slot) * 4
                            buf[o]     = x
                            buf[o + 1] = y
                            buf[o + 2] = c.z
                            buf[o + 3] = c.w
                        }
                    }
                }
            }
        }

        buffer.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, gw * Self.circK, gh),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: gw * Self.circK * 4 * MemoryLayout<Float>.stride
                )
            }
        }
    }
}

final class MeadowSimulator {
    struct SkyCloud {
        var x: Float
        var y: Float
        var circles: [SIMD4<Float>]
        var v: Float
        var grow: Float
        var hw: Float
        var dying: Bool = false
    }

    struct BoyTrip {
        var start: Float
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var after: SIMD2<Float>?
        var duration: Float
        var cycles: Int
        var enter: Bool
        var exit: Bool
    }

    struct BoyLegIK {
        var hip: SIMD2<Float>
        var knee: SIMD2<Float>
        var ankle: SIMD2<Float>
        var angle: Float
        var contact: Bool
        var lift: Float
    }

    let circleGrid = SpatialCircleGrid()

    private var skyClouds: [SkyCloud] = []
    private var flowT: Float = 0
    private var massCircles: [SIMD4<Float>] = []
    private var lastMassTime: Float = -1e9
    private var lastMassW: Float = 0
    private var lastMassH: Float = 0
    private var lastMassEdge: Float = -999
    private var lastMassSeed: Int = -1

    private(set) var boyFaceTex: MTLTexture?
    private(set) var boyRunTex: MTLTexture?
    private(set) var catTex: MTLTexture?
    private var spritesLoaded = false

    private(set) var actorTex: MTLTexture?
    private(set) var actorShadowTex: MTLTexture?
    private var actorTargetW: Int = 0
    private var actorTargetH: Int = 0
    private(set) var actorRect: SIMD4<Float> = .zero
    private(set) var hasActor: Bool = false
    private(set) var boyUniforms = MeadowBoyUniforms()
    private var boyScissorRegions: [[MTLScissorRect]] = [[], []]

    private var boyTime: Float = 0
    private var boyPos: SIMD2<Float>?
    private var boyTarget: SIMD2<Float> = .zero
    private var boyLayoutSig: String = ""
    private var boyTrip: BoyTrip?
    private var nextRunAt: Float = 7.0
    private var returnAt: Float?
    private var kitePos: SIMD2<Float>?
    private var lastBoyScale: Float = 0
    private var nextPullAt: Float = 2.2
    private var pullStarted: Float = -1e9
    private var lastLinePull: Float = 0
    private var kiteReaction = (x: Float(0), y: Float(0), vx: Float(0), vy: Float(0), angle: Float(0), spin: Float(0))

    private var catTime: Float = 0
    private var catSig: String = ""
    private var catPlace: (x: Float, y: Float, size: Float)?
    private(set) var catRect: SIMD4<Float> = .zero
    private(set) var catExtra: SIMD4<Float> = .zero
    private(set) var hasCat: Bool = false

    func ensureSprites(device: MTLDevice, commandQueue: MTLCommandQueue) {
        guard !spritesLoaded else { return }
        spritesLoaded = true
        boyFaceTex = SpriteTextureLoader.makeSquareSpriteTexture(
            subpath: "assets/meadow-kite-boy-level-face.png",
            size: 384,
            device: device,
            commandQueue: commandQueue
        )
        boyRunTex = SpriteTextureLoader.makeSquareSpriteTexture(
            subpath: "assets/meadow-kite-boy-diagonal-run.png",
            size: 768,
            device: device,
            commandQueue: commandQueue
        )
        catTex = SpriteTextureLoader.makeSquareSpriteTexture(
            subpath: "assets/meadow-black-kitten.png",
            size: 384,
            device: device,
            commandQueue: commandQueue
        )
    }

    func invalidateMass() {
        lastMassTime = -1e9
        catSig = ""
        boyLayoutSig = ""
    }

    @inline(__always)
    private static func sstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private static func wobX(_ x: Float, _ y: Float, _ r: Float, _ ph: Float, _ flowT: Float) -> Float {
        (4.5 + 0.12 * r) * (0.85 * sin(flowT * 0.24 + x * 0.011 + y * 0.004) + 0.3 * sin(flowT * 0.3 + ph * 6.283))
    }

    @inline(__always)
    private static func wobY(_ x: Float, _ y: Float, _ r: Float, _ ph: Float, _ flowT: Float) -> Float {
        (4.5 + 0.12 * r) * (0.65 * sin(flowT * 0.2 + y * 0.013 - x * 0.006 + 1.7) + 0.25 * cos(flowT * 0.28 + ph * 6.283))
    }

    func step(
        dt: Float,
        time: Float,
        field: TerrainField,
        obstacles: [IconObstacle],
        seed: Int,
        edge: Float,
        cover: Float,
        flow: Float,
        sigma: Float,
        showBoy: Bool = true,
        showCat: Bool = true,
        drawScale: Float,
        bottomInset: Float,
        device: MTLDevice
    ) {
        let W = field.width
        let H = field.height

        stepSkyClouds(dt: dt, width: W, height: H, bottomInset: bottomInset, cover: cover, flow: flow)

        let morphing = field.isAnimatingTransition ||
            abs(lastMassW - W) > 1 || abs(lastMassH - H) > 1 ||
            abs(lastMassEdge - edge) > 0.2 || lastMassSeed != seed
        if morphing || (time - lastMassTime > 0.5) {
            massCircles = buildMassCircles(field: field, edge: edge, seed: seed)
            lastMassW = W
            lastMassH = H
            lastMassEdge = edge
            lastMassSeed = seed
            lastMassTime = time
        }

        var combined: [SIMD4<Float>] = []
        combined.reserveCapacity(massCircles.count + skyClouds.count * 28)
        let ft = flowT
        for c in massCircles {
            let nx = c.x + Self.wobX(c.x, c.y, c.z, c.w, ft)
            let ny = c.y + Self.wobY(c.x, c.y, c.z, c.w, ft)
            combined.append(SIMD4<Float>(nx, ny, c.z, c.w))
        }
        for cloud in skyClouds {
            let g = cloud.grow * cloud.grow * (3 - 2 * cloud.grow)
            for (idx, p) in cloud.circles.enumerated() {
                let rb = p.z * g * (1.0 + 0.04 * sin(ft * (0.09 + 0.035 * p.w) + p.w * 6.283 + Float(idx)))
                if rb > 0.5 {
                    let nx = cloud.x + p.x + Self.wobX(p.x, p.y, p.z, p.w, ft)
                    let ny = cloud.y + p.y + Self.wobY(p.x, p.y, p.z, p.w, ft)
                    combined.append(SIMD4<Float>(nx, ny, rb, p.w))
                }
            }
        }
        circleGrid.upload(circles: combined, width: W, height: H, device: device)

        if showBoy {
            stepKiteBoy(
                dt: dt,
                field: field,
                edge: edge,
                width: W,
                height: H,
                bottomInset: bottomInset,
                drawScale: drawScale,
                device: device
            )
        } else {
            hasActor = false
        }

        if showCat {
            stepKitten(
                dt: dt,
                width: W,
                height: H,
                bottomInset: bottomInset,
                seed: seed,
                obstacles: obstacles,
                sigma: sigma
            )
        } else {
            hasCat = false
        }
    }

    func encodeOffscreenActorPass(commandBuffer: MTLCommandBuffer, boyPipeline: MTLRenderPipelineState) {
        guard hasActor,
              let actorTex,
              let actorShadowTex,
              let boyFaceTex,
              let boyRunTex else { return }

        let targets = [actorShadowTex, actorTex]
        for passIdx in 0..<2 {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = targets[passIdx]
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setRenderPipelineState(boyPipeline)
            var u = boyUniforms
            u.kiteAndTime.w = (passIdx == 0) ? 1.0 : 0.0
            enc.setFragmentBytes(&u, length: MemoryLayout<MeadowBoyUniforms>.stride, index: 0)
            enc.setFragmentTexture(boyFaceTex, index: 0)
            enc.setFragmentTexture(boyRunTex, index: 1)

            for sc in boyScissorRegions[passIdx] where sc.width > 0 && sc.height > 0 {
                enc.setScissorRect(sc)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }
    }

    private func makeSkyCloud(x: Float, height: Float, bottomInset: Float) -> SkyCloud {
        let R: Float = 95.0 * 1.2
        let n = Int.random(in: 3...5)
        let w = R * (1.0 + Float(n) * 0.5)
        var body: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = n == 1 ? 0 : Float(i) / Float(n - 1) - 0.5
            let r = R * (0.6 - abs(t) * 0.45 + Float.random(in: 0...0.12))
            body.append(SIMD3(t * w, -r * 0.55, r))
        }
        for i in 0..<(n - 1) {
            let t = n == 2 ? 0 : Float(i) / Float(n - 2) - 0.5
            let r = R * Float.random(in: 0.55...0.80)
            body.append(SIMD3(t * w * 0.6 + Float.random(in: -0.5...0.5) * R * 0.4, -R * Float.random(in: 0.5...0.85), r))
        }
        if Float.random(in: 0...1) < 0.6 {
            body.append(SIMD3(Float.random(in: -0.5...0.5) * w * 0.3, -R * 1.05, R * Float.random(in: 0.4...0.55)))
        }

        func ciOf(_ px: Float, _ py: Float) -> Float {
            var d: Float = 1e9
            for b in body {
                d = min(d, hypot(px - b.x, py - b.y) - b.z)
            }
            return d
        }

        var x0: Float = 1e9, x1: Float = -1e9, y0: Float = 1e9, y1: Float = -1e9
        for b in body {
            x0 = min(x0, b.x - b.z); x1 = max(x1, b.x + b.z)
            y0 = min(y0, b.y - b.z); y1 = max(y1, b.y + b.z)
        }

        var circles: [SIMD4<Float>] = []
        let S: Float = 0.62 / 1.2
        let Rm = R * S

        func addLayer(G: Float, sMin: Float, sMax: Float, band: Float, attach: Bool, bandFn: (Float) -> Float) {
            let gy0 = Int(floor((y0 - G) / G))
            let gy1 = Int(ceil((y1 + G) / G))
            let gx0 = Int(floor((x0 - G) / G))
            let gx1 = Int(ceil((x1 + G) / G))
            for gy in gy0...gy1 {
                for gx in gx0...gx1 {
                    let px = (Float(gx) + Float.random(in: 0.1...0.9)) * G
                    let py = (Float(gy) + Float.random(in: 0.1...0.9)) * G
                    let ci = ciOf(px, py)
                    if ci > 0 || ci < band { continue }
                    var r = G * Float.random(in: sMin...sMax) * bandFn(ci)
                    if attach {
                        var att: Float = 0
                        for c in circles {
                            att = max(att, Self.sstep(0.2 * r, 0.6 * r, c.z + r - hypot(c.x - px, c.y - py)))
                        }
                        r *= att
                    }
                    r *= Self.sstep(5, 11, r)
                    if r > 0.5 {
                        circles.append(SIMD4(px, py, r, Float.random(in: 0...1)))
                    }
                }
            }
        }

        let Gb: Float = 90
        addLayer(G: Gb, sMin: 0.55, sMax: 0.85, band: -1e9, attach: false) { ci in
            Self.sstep(-0.2 * Gb, -0.65 * Gb, ci)
        }
        addLayer(G: Rm, sMin: 0.60, sMax: 0.95, band: -1e9, attach: false) { ci in
            Self.sstep(-0.1 * Rm, -0.7 * Rm, ci)
        }
        for b in body where b.z > 0.75 * Rm {
            circles.append(SIMD4(b.x, b.y, b.z - 0.75 * Rm, Float.random(in: 0...1)))
        }
        addLayer(G: 34 * 0.85, sMin: 0.50, sMax: 0.90, band: -1.0 * Rm, attach: true) { ci in
            Self.sstep(-0.05 * Rm, -0.35 * Rm, ci) * (1 - Self.sstep(-0.7 * Rm, -1.0 * Rm, ci))
        }
        addLayer(G: 24 * 0.85, sMin: 0.45, sMax: 0.80, band: -0.6 * Rm, attach: true) { ci in
            Self.sstep(0, -0.2 * Rm, ci) * (1 - Self.sstep(-0.4 * Rm, -0.6 * Rm, ci))
        }

        let usableH = max(160, height - bottomInset - 120)
        let y = 80 + Float.random(in: 0..<usableH)
        return SkyCloud(
            x: x,
            y: y,
            circles: circles,
            v: Float.random(in: 0.7...1.3),
            grow: 0,
            hw: max(-x0, x1) + 20
        )
    }

    private func stepSkyClouds(dt: Float, width: Float, height: Float, bottomInset: Float, cover: Float, flow: Float) {
        flowT += dt * flow
        let want = max(0, min(14, Int((cover * 10).rounded())))
        let aliveIndices = skyClouds.indices.filter { !skyClouds[$0].dying }
        if aliveIndices.count > want {
            for idx in aliveIndices.dropFirst(want) {
                skyClouds[idx].dying = true
            }
        } else if aliveIndices.count < want {
            for _ in aliveIndices.count..<want {
                var best = makeSkyCloud(x: Float.random(in: 0..<max(100, width)), height: height, bottomInset: bottomInset)
                var bestD: Float = -1
                for _ in 0..<16 {
                    let cand = makeSkyCloud(x: Float.random(in: 0..<max(100, width)), height: height, bottomInset: bottomInset)
                    var dmin: Float = 1e9
                    for o in skyClouds {
                        dmin = min(dmin, hypot((o.x - cand.x) / 1.6, o.y - cand.y))
                    }
                    if dmin > bestD {
                        bestD = dmin
                        best = cand
                    }
                }
                skyClouds.append(best)
            }
        }

        for i in stride(from: skyClouds.count - 1, through: 0, by: -1) {
            skyClouds[i].x += flow * 10.0 * skyClouds[i].v * dt
            if skyClouds[i].dying {
                skyClouds[i].grow -= dt * 0.5
            } else {
                skyClouds[i].grow = min(1.0, skyClouds[i].grow + dt * 0.5)
            }
            if skyClouds[i].grow <= 0 {
                skyClouds.remove(at: i)
                continue
            }
            if skyClouds[i].x - skyClouds[i].hw > width + 50 {
                var replacement = makeSkyCloud(x: -skyClouds[i].hw - 50, height: height, bottomInset: bottomInset)
                replacement.grow = 1.0
                skyClouds[i] = replacement
            }
        }
    }

    private func buildMassCircles(field: TerrainField, edge: Float, seed: Int) -> [SIMD4<Float>] {
        let W = field.width
        let H = field.height
        let R: Float = 95.0
        let sd = Double(seed)
        var list: [SIMD4<Float>] = []
        var big: [SIMD2<Int>: SIMD3<Float>] = [:]

        func rnd1(_ cx: Int, _ cy: Int, _ k: Double) -> Float {
            Float(TerrainField.hash2(cx, cy, sd + k * 3.17))
        }

        func buildLayer(G: Float, k0: Double, sMin: Float, sMax: Float, minBand: Float, isBig: Bool, bandFn: (Float) -> Float) {
            let cy0 = -Int(ceil(2 * R / G))
            let cy1 = Int(ceil((H + 2 * R) / G))
            let cx0 = -Int(ceil(2 * R / G))
            let cx1 = Int(ceil((W + 2 * R) / G))
            for cy in cy0...cy1 {
                for cx in cx0...cx1 {
                    let ox = rnd1(cx, cy, k0)
                    let oy = rnd1(cx, cy, k0 + 1)
                    let rr = rnd1(cx, cy, k0 + 2)
                    let ph = rnd1(cx, cy, k0 + 3)
                    let x = (Float(cx) + 0.1 + ox * 0.8) * G
                    let y = (Float(cy) + 0.1 + oy * 0.8) * G
                    let ci = field.sample(x: x, y: y) - edge
                    if ci > 0 || ci < minBand - 10 { continue }
                    var r = G * (sMin + (sMax - sMin) * rr) * bandFn(ci)
                    let gap = ci + 0.6 * R
                    var att = Self.sstep(gap - 4, gap + 12, r)
                    if !isBig {
                        let bx = Int(floor(x / R))
                        let by = Int(floor(y / R))
                        for j in (by - 1)...(by + 1) {
                            for i in (bx - 1)...(bx + 1) {
                                if let o = big[SIMD2(i, j)] {
                                    let ov = o.z + r - hypot(o.x - x, o.y - y)
                                    att = max(att, Self.sstep(0.2 * r, 0.6 * r, ov))
                                }
                            }
                        }
                    }
                    r *= att
                    r *= Self.sstep(5, 11, r)
                    if r < 0.5 { continue }
                    if isBig {
                        big[SIMD2(cx, cy)] = SIMD3(x, y, r)
                    }
                    let breathingR = r * (1.0 + 0.04 * sin(flowT * (0.09 + 0.035 * ph) + ph * 6.283))
                    list.append(SIMD4(x, y, breathingR, ph))
                }
            }
        }

        buildLayer(G: R, k0: 1, sMin: 0.55, sMax: 0.90, minBand: -1e9, isBig: true) { ci in
            Self.sstep(-0.15 * R, -0.80 * R, ci)
        }
        buildLayer(G: 34, k0: 11, sMin: 0.50, sMax: 0.90, minBand: -1.0 * R, isBig: false) { ci in
            Self.sstep(-0.05 * R, -0.30 * R, ci) * (1 - Self.sstep(-0.70 * R, -1.0 * R, ci))
        }
        buildLayer(G: 24, k0: 21, sMin: 0.45, sMax: 0.80, minBand: -0.6 * R, isBig: false) { ci in
            Self.sstep(0, -0.15 * R, ci) * (1 - Self.sstep(-0.40 * R, -0.60 * R, ci))
        }
        return list
    }

    private static func runDestination(from: SIMD2<Float>, s: Float, width: Float, height: Float, bottomInset: Float) -> (pos: SIMD2<Float>, exit: Bool) {
        let usableH = max(200, height - bottomInset)
        let dist = simd_clamp(usableH * 0.27, 165, 315)
        let exit = (from.y - dist) < (116 * s + 24)
        let y: Float = exit ? (-610 * s - 24) : (from.y - dist)
        let x = max(96 * s + 12, from.x - (from.y - y) * 0.65)
        return (SIMD2(x, y), exit)
    }

    private func startTrip(from: SIMD2<Float>, to: SIMD2<Float>, s: Float, enter: Bool = false, exit: Bool = false) -> BoyTrip {
        let dist = hypot(to.x - from.x, to.y - from.y)
        let cycles = max(2, Int((dist / max(1, s * 80)).rounded()))
        let duration = max(2.0, max(dist / 55.0, Float(cycles) * 0.52))
        return BoyTrip(start: boyTime, from: from, to: to, after: nil, duration: duration, cycles: cycles, enter: enter, exit: exit)
    }

    private func evalTripPose(elapsed: Float, cycles: Int, duration: Float, enter: Bool, exit: Bool) -> (frame: Float, back: Bool, progress: Float, running: Bool, squeeze: Float, phase: Float, gait: Float, bob: Float, done: Bool) {
        let turnDur: Float = enter ? 0 : 0.22
        let runEnd = turnDur + duration
        let turnBackAt = runEnd + 0.18
        let strideLead: Float = enter ? 0 : 0.07

        if elapsed < turnDur - strideLead {
            let t = max(0, elapsed / max(0.001, turnDur))
            return (t < 0.25 ? 3 : (t < 0.68 ? 0 : 3), t >= 0.25, 0, false, 1.0 - 0.2 * sin(t * .pi), 0, 0, 0, false)
        }
        if elapsed < runEnd {
            let runTime = elapsed - turnDur
            let stepTime = max(0, runTime + strideLead)
            let plantTime: Float = enter ? 0 : 0.02
            let moveTime = max(0, runTime - plantTime)
            let moveDuration = max(0.05, duration - plantTime)
            let acc: Float = 0.16, dec: Float = 0.22
            func ramp(_ t: Float, _ r: Float) -> Float {
                if t >= r { return t - r * 0.5 }
                let u = max(0, t / r)
                return r * (u * u * u - 0.5 * u * u * u * u)
            }
            let progress = simd_clamp(
                (ramp(moveTime, acc) - ramp(max(0, moveTime - moveDuration + dec), dec)) /
                max(0.01, moveDuration - (acc + dec) * 0.5),
                0, 1
            )
            let lead: Float = enter ? 0 : 0.18
            let phase = (lead * Self.sstep(0, 1, stepTime / 0.10) + (Float(cycles) - lead) * progress) * 2 * .pi
            let gait = Self.sstep(0, 1, stepTime / 0.07) * Self.sstep(0, 1, (duration - runTime) / 0.12)
            let squeeze: Float = elapsed < turnDur ? (1.0 - 0.2 * sin(elapsed / max(0.001, turnDur) * .pi)) : 1.0
            let bob = -(1.0 - cos(phase * 2)) * 0.65 * gait
            return (3, true, progress, true, squeeze, phase, gait, bob, false)
        }
        if exit {
            return (3, true, 1, false, 1, 0, 0, 0, true)
        }
        if elapsed < turnBackAt {
            return (3, true, 1, false, 1, 0, 0, 0, false)
        }
        if elapsed < turnBackAt + 0.22 {
            let t = (elapsed - turnBackAt) / 0.22
            return (t < 0.32 ? 3 : 0, t < 0.75, 1, false, 1.0 - 0.2 * sin(t * .pi), 0, 0, 0, false)
        }
        return (3, false, 1, false, 1, 0, 0, 0, true)
    }

    private func solveRunningRig(gait: Float, phase: Float, bob: Float) -> (left: BoyLegIK, right: BoyLegIK, arm: Float, reelArm: Float) {
        func solve(hip: SIMD2<Float>, knee: SIMD2<Float>, ankle: SIMD2<Float>, offset: Float, front: SIMD2<Float>, back: SIMD2<Float>, lift: Float, kick: Float) -> BoyLegIK {
            let rawU = (phase / (2 * .pi) + offset).truncatingRemainder(dividingBy: 1.0)
            let u = rawU < 0 ? rawU + 1.0 : rawU
            let swing = u >= 0.5
            let t = swing ? (u - 0.5) * 2.0 : u * 2.0
            let recovery = max(0, (t - 0.18) / 0.82)
            let step = swing ? (recovery * recovery * (3 - 2 * recovery)) : t
            let fold = swing ? pow(sin(.pi * t), 2) : 0
            let a = swing ? back : front
            let b = swing ? front : back
            let x = a.x + (b.x - a.x) * step + kick * fold
            let y = a.y + (b.y - a.y) * step
            let h = swing ? min(fold * lift, max(0, y - 5)) * gait : 0
            var foot = SIMD2<Float>(
                ankle.x + (hip.x + x - ankle.x) * gait,
                ankle.y + (hip.y + y - ankle.y) * gait - bob - h
            )
            let upper = hypot(knee.x - hip.x, knee.y - hip.y)
            let lower = hypot(ankle.x - knee.x, ankle.y - knee.y)
            let dx = foot.x - hip.x
            let dy = foot.y - hip.y
            let raw = hypot(dx, dy)
            let dist = simd_clamp(raw, abs(upper - lower) + 0.001, upper + lower - 0.001)
            let ux = dx / max(raw, 0.001)
            let uy = dy / max(raw, 0.001)
            foot = SIMD2(hip.x + ux * dist, hip.y + uy * dist)
            let along = (upper * upper - lower * lower + dist * dist) / (2 * dist)
            let bend = sqrt(max(0, upper * upper - along * along))
            let joint = SIMD2(hip.x + ux * along - uy * bend, hip.y + uy * along + ux * bend)
            return BoyLegIK(hip: hip, knee: joint, ankle: foot, angle: -fold * 1.05 * gait, contact: !swing, lift: h)
        }

        let left = solve(hip: SIMD2(-12, 37), knee: SIMD2(-14, 47), ankle: SIMD2(-15, 57), offset: 0.0, front: SIMD2(-7.5, 8.5), back: SIMD2(1.4, 19.0), lift: 19, kick: 9)
        let right = solve(hip: SIMD2(14, 35), knee: SIMD2(18, 44), ankle: SIMD2(21, 51), offset: 0.5, front: SIMD2(0.5, 7.2), back: SIMD2(7.0, 15.8), lift: 16, kick: 5)
        let arm = -sin(phase) * 0.42 * gait
        let reelArm = (sin(phase) * 0.26 + sin(phase * 2) * 0.035) * gait
        return (left, right, arm, reelArm)
    }

    private func stepKiteBoy(
        dt: Float,
        field: TerrainField,
        edge: Float,
        width: Float,
        height: Float,
        bottomInset: Float,
        drawScale: Float,
        device: MTLDevice
    ) {
        guard boyFaceTex != nil, boyRunTex != nil else {
            hasActor = false
            return
        }

        let clampedDt = min(0.05, max(0, dt))
        boyTime += clampedDt
        let usableH = max(200, height - bottomInset)
        let s = simd_clamp(min(width / 1379.0, usableH / 1141.0), 0.24, 1.25) * 0.35

        let sig = "\(Int(width))x\(Int(height)):\(Int(bottomInset))"
        if sig != boyLayoutSig {
            boyLayoutSig = sig
            boyTarget = chooseBoyPosition(s: s, width: width, usableH: usableH, field: field, edge: edge)
            if boyPos == nil { boyPos = boyTarget }
            if let pos = boyPos, boyTrip != nil {
                boyTrip = BoyTrip(start: boyTime - 2.22, from: pos, to: pos, after: boyTarget, duration: 2.0, cycles: 2, enter: false, exit: false)
            }
            nextRunAt = boyTime + 7.0
        }

        if let ret = returnAt {
            if boyTime < ret {
                hasActor = false
                return
            }
            let startX = max(96 * s + 12, min(width * 0.70, width - 612 * s - 12))
            let startPos = SIMD2<Float>(startX, height + 116 * s + 24)
            let destY = usableH * 0.70
            let destPos = SIMD2<Float>(max(96 * s + 12, startX - (startPos.y - destY) * 0.65), destY)
            boyPos = startPos
            boyTarget = destPos
            boyTrip = startTrip(from: startPos, to: destPos, s: s, enter: true, exit: false)
            kitePos = nil
            returnAt = nil
            pullStarted = -1e9
            lastLinePull = 0
            kiteReaction = (0, 0, 0, 0, 0, 0)
        }

        if boyPos == nil { boyPos = boyTarget }
        guard var pos = boyPos else { return }

        if boyTrip == nil {
            let move = 1.0 - exp(-clampedDt * 0.7)
            pos += (boyTarget - pos) * move
            if boyTime >= nextRunAt && hypot(pos.x - boyTarget.x, pos.y - boyTarget.y) < 2.0 {
                let dest = Self.runDestination(from: pos, s: s, width: width, height: height, bottomInset: bottomInset)
                boyTrip = startTrip(from: pos, to: dest.pos, s: s, enter: false, exit: dest.exit)
                pullStarted = -1e9
            }
        }

        let activity: (frame: Float, back: Bool, progress: Float, running: Bool, squeeze: Float, phase: Float, gait: Float, bob: Float, done: Bool)
        if let trip = boyTrip {
            activity = evalTripPose(elapsed: boyTime - trip.start, cycles: trip.cycles, duration: trip.duration, enter: trip.enter, exit: trip.exit)
            pos = trip.from + (trip.to - trip.from) * activity.progress
            if activity.done {
                if trip.exit {
                    boyTrip = nil
                    boyPos = pos
                    returnAt = boyTime + 6.0
                    hasActor = false
                    return
                }
                boyTarget = trip.after ?? pos
                boyTrip = nil
                nextRunAt = boyTime + 18.0
                nextPullAt = max(nextPullAt, boyTime + 2.2)
            }
        } else {
            activity = evalTripPose(elapsed: 6.0, cycles: 4, duration: 2.0, enter: false, exit: false)
        }
        boyPos = pos

        let waveTime = boyTime.truncatingRemainder(dividingBy: 9.0)
        if boyTrip == nil && !activity.back && boyTime >= nextPullAt && (nextRunAt - boyTime) > 3.6 && (waveTime < 2.8 || waveTime > 5.0) {
            pullStarted = boyTime
            nextPullAt = boyTime + 7.8
        }

        let tugAge = boyTime - pullStarted
        let tugActive = tugAge >= 0 && tugAge < 1.12
        let tugReach: Float = tugActive ? Self.sstep(0, 1, tugAge / 0.16) * (1 - Self.sstep(0, 1, (tugAge - 0.16) / 0.20)) : 0
        let tugPull: Float = tugActive ? Self.sstep(0, 1, (tugAge - 0.16) / 0.20) * (1 - Self.sstep(0, 1, (tugAge - 0.50) / 0.62)) : 0
        let wavePull: Float = tugActive ? 0 : pow(sin(.pi * simd_clamp((waveTime - 4.0) / 0.6, 0, 1)), 2)

        let linePull: Float = activity.back ? 0 : max(tugPull, wavePull)
        let impulse = max(0, linePull - lastLinePull)
        lastLinePull = linePull

        kiteReaction.vx -= 100 * impulse
        kiteReaction.vy -= 120 * impulse
        kiteReaction.spin += 2.8 * impulse
        kiteReaction.vx += (-18 * kiteReaction.x - 3.4 * kiteReaction.vx) * clampedDt
        kiteReaction.vy += (-22 * kiteReaction.y - 4.0 * kiteReaction.vy) * clampedDt
        kiteReaction.spin += (-24 * kiteReaction.angle - 3.8 * kiteReaction.spin) * clampedDt
        kiteReaction.x += kiteReaction.vx * clampedDt
        kiteReaction.y += kiteReaction.vy * clampedDt
        kiteReaction.angle += kiteReaction.spin * clampedDt

        let runWind: Float = activity.running ? sin(.pi * activity.progress) : 0
        let gust = (sin(boyTime * 4.8) * 60 + sin(boyTime * 7.1) * 8) * runWind
        let baseKx = 215 + sin(boyTime * 0.72) * 21 + sin(boyTime * 1.23) * 5 + gust
        let baseKy = 205 + sin(boyTime * 0.49 + 0.6) * 10
        prepareBoyUniformsAndTargets(
            pos: pos,
            s: s,
            clampedDt: clampedDt,
            activity: activity,
            tugActive: tugActive,
            tugReach: tugReach,
            tugPull: tugPull,
            wavePull: wavePull,
            linePull: linePull,
            runWind: runWind,
            baseKx: baseKx,
            baseKy: baseKy,
            drawScale: drawScale,
            device: device
        )
    }

    private func prepareBoyUniformsAndTargets(
        pos: SIMD2<Float>,
        s: Float,
        clampedDt: Float,
        activity: (frame: Float, back: Bool, progress: Float, running: Bool, squeeze: Float, phase: Float, gait: Float, bob: Float, done: Bool),
        tugActive: Bool,
        tugReach: Float,
        tugPull: Float,
        wavePull: Float,
        linePull: Float,
        runWind: Float,
        baseKx: Float,
        baseKy: Float,
        drawScale: Float,
        device: MTLDevice
    ) {
        let desiredKite = SIMD2<Float>(pos.x + baseKx * s, pos.y + baseKy * s)
        if kitePos == nil || abs(lastBoyScale - s) > 1e-4 {
            kitePos = desiredKite
        }
        lastBoyScale = s
        let follow = 1.0 - exp(-clampedDt / 0.23)
        var kp = kitePos ?? desiredKite
        kp += (desiredKite - kp) * follow
        kitePos = kp

        let kx = baseKx + simd_clamp((kp.x - desiredKite.x) / s, -30, 32) + kiteReaction.x - linePull * 10.0
        let ky = baseKy + simd_clamp((kp.y - desiredKite.y) / s, -30, 32) + kiteReaction.y - linePull * 12.0
        let kiteRock = kiteReaction.angle + linePull * 0.10

        let pull = pow(0.5 + 0.5 * sin(boyTime * 1.35), 3)
        let shift = sin(boyTime * 1.05)
        let body = SIMD2<Float>(sin(boyTime * 0.85) * 1.7 - tugPull * 1.8, sin(boyTime * 1.7) * 0.65 - tugPull * 0.8)
        let tugOff = SIMD2<Float>(tugReach * 4.0 - tugPull * 12.0, tugReach * 3.0 - tugPull * 8.0)
        let reel: Float = -0.18 + (tugActive ? -tugPull * 0.22 : wavePull * 1.14)
        let angle = reel + 0.18
        let ca = cos(angle), sa = sin(angle)
        let qx: Float = -21.0 + ca * (-49.0 + 21.0) - sa * (-45.5 + 9.0) - tugOff.x * 0.35
        let qy: Float = -9.0 + sa * (-49.0 + 21.0) + ca * (-45.5 + 9.0) - tugOff.y * 0.35
        let py = (qy + body.y * 78.0 / 170.0) / (1.0 + body.y / 170.0)
        var hand = SIMD2<Float>(qx + body.x * (78.0 - py) / 170.0, py)
        let legs = SIMD2<Float>(max(0, shift) * 3.8, max(0, -shift) * 3.2)

        let rig = solveRunningRig(gait: activity.gait, phase: activity.phase, bob: activity.bob)

        let feet: [SIMD2<Float>]
        let soles: [SIMD2<Float>]
        if activity.running {
            func heel(_ leg: BoyLegIK, _ off: SIMD2<Float>) -> SIMD2<Float> {
                let c = cos(leg.angle), sn = sin(leg.angle)
                return SIMD2(leg.ankle.x + c * off.x - sn * off.y, leg.ankle.y + sn * off.x + c * off.y + activity.bob - 10.0)
            }
            let s0 = heel(rig.left, SIMD2(-0.52, 15.94))
            let s1 = heel(rig.right, SIMD2(-3.42, 15.63))
            soles = [s0, s1]
            feet = [SIMD2(s0.x, s0.y + rig.left.lift), SIMD2(s1.x, s1.y + rig.right.lift)]
        } else if activity.back {
            let r0: SIMD2<Float> = activity.frame == 0 ? SIMD2(-10.06, 78.11) : SIMD2(-15.52, 72.94)
            let r1: SIMD2<Float> = activity.frame == 0 ? SIMD2(23.76, 72.66) : SIMD2(17.58, 66.63)
            let f0 = SIMD2(r0.x * activity.squeeze, r0.y + activity.bob - 10.0)
            let f1 = SIMD2(r1.x * activity.squeeze, r1.y + activity.bob - 10.0)
            feet = [f0, f1]
            soles = feet
        } else {
            let f0 = SIMD2<Float>(-22.5 * activity.squeeze, 72.0)
            let f1 = SIMD2<Float>(37.8 * activity.squeeze, 63.3)
            feet = [f0, f1]
            soles = [
                SIMD2(f0.x - legs.x * 0.24 * activity.squeeze, f0.y - legs.x),
                SIMD2(f1.x + legs.y * 0.24 * activity.squeeze, f1.y - legs.y)
            ]
        }

        let dx = feet[1].x - feet[0].x
        let spacing = (dx >= 0 ? Float(1) : Float(-1)) * max(12.0, abs(dx))
        let slope: Float = activity.running ? -0.19 : simd_clamp((feet[1].y - feet[0].y) / spacing, -0.8, 0.5)
        let intercept: Float
        if activity.running {
            let sup = rig.left.contact ? soles[0] : soles[1]
            intercept = sup.y - slope * sup.x
        } else {
            intercept = (feet[0].y + feet[1].y - slope * (feet[0].x + feet[1].x)) * 0.5
        }
        let cLW: Float = activity.running ? (rig.left.contact ? 1.0 : 0.22) : 1.0
        let cRW: Float = activity.running ? (rig.right.contact ? 1.0 : 0.22) : 1.0

        if activity.back {
            let grips: [SIMD2<Float>] = [SIMD2(44, -23), SIMD2(37, -23), SIMD2(49, -25), SIMD2(37, -23)]
            let g = grips[min(3, max(0, Int(activity.frame)))]
            let a = activity.running ? rig.reelArm : 0
            let c = cos(a), sn = sin(a)
            hand = SIMD2(
                (22.0 + c * (g.x - 22.0) - sn * (g.y + 7.0)) * activity.squeeze,
                -7.0 + sn * (g.x - 22.0) + c * (g.y + 7.0) - 10.0 + activity.bob
            )
        } else {
            hand.x *= activity.squeeze
        }

        let k = max(1.0, drawScale)
        let leftPx = Int(floor((pos.x - 96.0 * s) * k)) - 1
        let topPx = Int(floor((pos.y - 116.0 * s) * k)) - 1
        let wPx = max(16, Int(ceil(708.0 * s * k)) + 2)
        let hPx = max(16, Int(ceil(726.0 * s * k)) + 2)

        if actorTex == nil || actorShadowTex == nil || wPx != actorTargetW || hPx != actorTargetH {
            actorTargetW = wPx
            actorTargetH = hPx
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: wPx,
                height: hPx,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            actorShadowTex = device.makeTexture(descriptor: desc)
            actorTex = device.makeTexture(descriptor: desc)
        }

        let rectW = Float(wPx) / k
        let rectH = Float(hPx) / k
        let offX = Float(leftPx) / k
        let offY = Float(topPx) / k
        actorRect = SIMD4<Float>(offX, offY, rectW, rectH)

        var u = MeadowBoyUniforms()
        u.resAndOffset = SIMD4(rectW, rectH, offX, offY)
        u.place = SIMD4(pos.x, pos.y, s, k)
        u.kiteAndTime = SIMD4(kx, ky, boyTime, 0)
        u.pose = SIMD4(0, sin(boyTime * 0.9 + 0.4) * 1.5, reel, pull)
        u.motion = SIMD4(activity.frame, activity.back ? 1 : 0, activity.squeeze, activity.bob)
        u.rig = SIMD4(activity.running ? 1 : 0, rig.arm, rig.reelArm, runWind)
        u.leftHipKnee = SIMD4(rig.left.hip.x, rig.left.hip.y, rig.left.knee.x, rig.left.knee.y)
        u.rightHipKnee = SIMD4(rig.right.hip.x, rig.right.hip.y, rig.right.knee.x, rig.right.knee.y)
        u.ankles = SIMD4(rig.left.ankle.x, rig.left.ankle.y, rig.right.ankle.x, rig.right.ankle.y)
        u.feetAndGround = SIMD4(rig.left.angle, rig.right.angle, slope, intercept)
        u.contactLAndTension = SIMD4(feet[0].x, feet[0].y - 0.5, cLW, linePull)
        u.contactRAndRock = SIMD4(feet[1].x, feet[1].y - 0.5, cRW, kiteRock)
        u.bodyAndLegs = SIMD4(body.x, body.y, legs.x, legs.y)
        u.handAndTug = SIMD4(hand.x, hand.y, tugOff.x, tugOff.y)
        boyUniforms = u

        let rawRegions: [[(Float, Float, Float, Float)]] = [
            [(-70, 25, 185, 230), (105, 140, 612, 610)],
            [(-90, -110, 116, 90), (12, -35, 205, 260), (12, 65, 514, 476)]
        ]
        boyScissorRegions = rawRegions.map { passBoxes in
            passBoxes.compactMap { (x0, y0, x1, y1) in
                let l = max(0, Int(floor((pos.x + x0 * s) * k)) - leftPx - 2)
                let r = min(wPx, Int(ceil((pos.x + x1 * s) * k)) - leftPx + 2)
                let t = max(0, Int(floor((pos.y + y0 * s) * k)) - topPx - 2)
                let b = min(hPx, Int(ceil((pos.y + y1 * s) * k)) - topPx + 2)
                guard r > l, b > t else { return nil }
                return MTLScissorRect(x: l, y: t, width: r - l, height: b - t)
            }
        }
        hasActor = true
    }

    private func chooseBoyPosition(s: Float, width: Float, usableH: Float, field: TerrainField, edge: Float) -> SIMD2<Float> {
        let preferred = boyPos ?? SIMD2<Float>(width * 0.54, usableH * 0.48)
        var best: SIMD2<Float>?
        var bestScore: Float = .greatestFiniteMagnitude
        let fys: [Float] = [0.48, 0.38, 0.58, 0.28, 0.66]
        let fxs: [Float] = [0.52, 0.64, 0.74, 0.38, 0.26, 0.80]
        for fy in fys {
            for fx in fxs {
                let c = SIMD2<Float>(width * fx, usableH * fy)
                if c.x - 96 * s < 12 || c.x + 612 * s > width - 12 ||
                   c.y - 116 * s < 12 || c.y + 610 * s > usableH - 12 {
                    continue
                }
                let boyField = field.sample(x: c.x, y: c.y)
                let kiteField = field.sample(x: c.x + 215 * s, y: c.y + 205 * s)
                let cloudPenalty: Float = (boyField < edge + 42 ? 600.0 : 0.0) + (kiteField < edge + 20 ? 180.0 : 0.0)
                let score = hypot(c.x - preferred.x, c.y - preferred.y) * 0.01 + cloudPenalty
                if score < bestScore {
                    bestScore = score
                    best = c
                }
            }
        }
        return best ?? SIMD2<Float>(width * 0.58, usableH * 0.42)
    }

    private func stepKitten(
        dt: Float,
        width: Float,
        height: Float,
        bottomInset: Float,
        seed: Int,
        obstacles: [IconObstacle],
        sigma: Float
    ) {
        guard catTex != nil else {
            hasCat = false
            return
        }
        let boyRef = boyPos ?? SIMD2<Float>(width * 0.54, max(200, height - bottomInset) * 0.48)
        catTime += min(0.05, max(0, dt))
        let usableH = max(200, height - bottomInset)
        let sig = "\(Int(width))x\(Int(height)):\(Int(bottomInset)):\(seed):\(obstacles.count)"
        if sig != catSig {
            catSig = sig
            catPlace = chooseCatPlace(
                boyStart: boyRef,
                width: width,
                height: height,
                usableH: usableH,
                bottomInset: bottomInset,
                seed: seed,
                obstacles: obstacles,
                cloudSize: sigma
            )
        }
        guard let place = catPlace else {
            hasCat = false
            return
        }

        let period = Float(10 + abs(seed % 4))
        let age = (catTime + Float(abs(seed % 1300)) / 1000.0).truncatingRemainder(dividingBy: period) - 3.0
        let tailAngle: Float
        if age >= 0 && age < 1.6 {
            let t = age / 1.6
            tailAngle = sin(t * .pi * 4.0) * pow(sin(t * .pi), 2) * 0.34
        } else {
            tailAngle = 0
        }

        catRect = SIMD4<Float>(place.x - place.size * 0.5, place.y - place.size * 0.5, place.size, place.size)
        catExtra = SIMD4<Float>(place.size * 0.045, place.size * 0.06, tailAngle, 0)
        hasCat = true
    }

    private func chooseCatPlace(
        boyStart: SIMD2<Float>,
        width: Float,
        height: Float,
        usableH: Float,
        bottomInset: Float,
        seed: Int,
        obstacles: [IconObstacle],
        cloudSize: Float
    ) -> (x: Float, y: Float, size: Float)? {
        let scale = simd_clamp(min(width / 1379.0, usableH / 1141.0), 0.24, 1.25) * 0.35
        let size = simd_clamp(min(width / 1379.0, usableH / 1141.0) * 78.0, 28.0, 90.0) * 0.578
        let radius = size * 0.58
        let pad = radius + 12.0
        let clearance = radius + 96.0 * scale + 14.0
        guard width > pad * 2, usableH > pad * 2 else { return nil }

        var lanes: [(SIMD2<Float>, SIMD2<Float>)] = []
        func traceRoute(from start: SIMD2<Float>) {
            var cur = start
            for _ in 0..<32 {
                let next = Self.runDestination(from: cur, s: scale, width: width, height: height, bottomInset: bottomInset)
                lanes.append((cur, next.pos))
                cur = next.pos
                if next.exit { break }
            }
        }
        traceRoute(from: boyStart)
        let bottom = SIMD2<Float>(max(96 * scale + 12, min(width * 0.70, width - 612 * scale - 12)), height + 116 * scale + 24)
        let entryY = usableH * 0.70
        let entry = SIMD2<Float>(max(96 * scale + 12, bottom.x - (bottom.y - entryY) * 0.65), entryY)
        lanes.append((bottom, entry))
        traceRoute(from: entry)

        func segDist(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let d = b - a
            let t = simd_clamp(simd_dot(p - a, d) / max(simd_dot(d, d), 1), 0, 1)
            return simd_length(p - a - d * t)
        }

        var rng = Mulberry32(seed: UInt32(truncatingIfNeeded: seed) ^ 0x71A43D25)
        var best: (x: Float, y: Float, size: Float)?
        var bestScore: Float = .greatestFiniteMagnitude

        for i in 0..<337 {
            let rx: Float = i < 256 ? rng.next() : (Float((i - 256) % 9) + 0.5) / 9.0
            let ry: Float = i < 256 ? rng.next() : (Float((i - 256) / 9) + 0.5) / 9.0
            let p = SIMD2<Float>(pad + rx * (width - pad * 2), pad + ry * (usableH - pad * 2))
            var minRoute: Float = .greatestFiniteMagnitude
            for (a, b) in lanes {
                minRoute = min(minRoute, segDist(p, a, b))
            }
            if minRoute < clearance { continue }

            var score: Float = 0
            for ob in obstacles {
                let dx = max(ob.x - p.x, max(0, p.x - ob.x - ob.w))
                let dy = max(ob.y - p.y, max(0, p.y - ob.y - ob.h))
                score += max(0, radius + cloudSize + 25.0 - hypot(dx, dy))
            }
            if score < bestScore {
                bestScore = score
                best = (p.x, p.y, size)
                if score == 0 { break }
            }
        }
        return best
    }
}

final class ForestSimulator {
    struct TreePuff {
        var baseX: Float
        var baseY: Float
        var radius: Float
        var tone: Float
        var phase: Float
    }

    struct WoodlandBird {
        var x: Float
        var y: Float
        var heading: Float
        var targetTreeIdx: Int
        var perched: Bool
        var timer: Float
        var flapPhase: Float
    }

    let circleGrid = SpatialCircleGrid()

    private var puffs: [TreePuff] = []
    private var treeCenters: [SIMD2<Float>] = []
    private(set) var birds: [WoodlandBird] = []
    private var layoutSig: String = ""

    func invalidateLayout() {
        layoutSig = ""
    }

    func step(
        dt: Float,
        time: Float,
        field: TerrainField,
        seed: Int,
        density: Float,
        wind: Float,
        wantBirds: Int,
        nightWeight: Float,
        device: MTLDevice
    ) {
        let W = field.width
        let H = field.height
        let sig = "\(Int(W))x\(Int(H)):\(seed):\( String(format: "%.2f", density) ):\(field.isAnimatingTransition ? "m" : "s")"
        if sig != layoutSig || field.isAnimatingTransition {
            layoutSig = sig
            rebuildCanopy(field: field, seed: seed, density: density)
        }

        var animated: [SIMD4<Float>] = []
        animated.reserveCapacity(puffs.count)
        let swayAmp = 2.6 * wind
        for p in puffs {
            let sVal = field.sample(x: p.baseX, y: p.baseY)
            let clearingGrow = simd_clamp((sVal - 4.0) / 26.0, 0, 1)
            if clearingGrow <= 0.02 { continue }
            let r = p.radius * (clearingGrow * clearingGrow * (3 - 2 * clearingGrow))
            if r < 3.0 { continue }
            let dx = swayAmp * sin(time * 0.85 + p.baseX * 0.012 + p.baseY * 0.006 + p.phase)
            let dy = swayAmp * 0.65 * cos(time * 0.72 + p.baseY * 0.011 - p.baseX * 0.005 + p.phase)
            animated.append(SIMD4<Float>(p.baseX + dx, p.baseY + dy, r, p.tone))
        }
        circleGrid.upload(circles: animated, width: W, height: H, device: device)

        let effectiveBirds = nightWeight > 0.7 ? min(wantBirds, 1) : max(0, min(8, wantBirds))
        stepBirds(dt: dt, want: effectiveBirds, width: W, height: H)
    }

    private func rebuildCanopy(field: TerrainField, seed: Int, density: Float) {
        let W = field.width
        let H = field.height
        let sd = Double(seed)
        var newPuffs: [TreePuff] = []
        var centers: [SIMD2<Float>] = []

        let spacing = max(46.0, 74.0 - density * 24.0)
        let cols = Int(ceil((W + 120) / spacing))
        let rows = Int(ceil((H + 120) / spacing))

        for ry in -1...rows {
            for cx in -1...cols {
                let h0 = Float(TerrainField.hash2(cx, ry, sd + 5.1))
                if h0 > min(0.96, 0.52 + density * 0.36) { continue }
                let jx = Float(TerrainField.hash2(cx, ry, sd + 11.7)) - 0.5
                let jy = Float(TerrainField.hash2(cx, ry, sd + 23.3)) - 0.5
                let tx = Float(cx) * spacing + jx * spacing * 0.78
                let ty = Float(ry) * spacing + jy * spacing * 0.78

                if field.sample(x: tx, y: ty) < 2.0 { continue }
                centers.append(SIMD2(tx, ty))

                let baseR = spacing * (0.42 + 0.28 * Float(TerrainField.hash2(cx, ry, sd + 31.9)))
                let speciesTone = Float(TerrainField.hash2(cx, ry, sd + 43.1))
                let phase = Float(TerrainField.hash2(cx, ry, sd + 59.7)) * 6.283

                newPuffs.append(TreePuff(baseX: tx, baseY: ty, radius: baseR, tone: speciesTone, phase: phase))
                let lobes = 3 + Int(Float(TerrainField.hash2(cx, ry, sd + 71.3)) * 2.0)
                for l in 0..<lobes {
                    let ang = Float(l) * (6.283 / Float(lobes)) + phase
                    let dist = baseR * (0.42 + 0.22 * Float(TerrainField.hash2(cx + l * 7, ry, sd + 83.9)))
                    let lr = baseR * (0.55 + 0.22 * Float(TerrainField.hash2(cx, ry + l * 13, sd + 97.1)))
                    let lTone = fract(speciesTone + Float(l) * 0.04)
                    newPuffs.append(TreePuff(
                        baseX: tx + cos(ang) * dist,
                        baseY: ty + sin(ang) * dist,
                        radius: lr,
                        tone: lTone,
                        phase: phase + Float(l) * 0.4
                    ))
                }
            }
        }
        puffs = newPuffs
        treeCenters = centers
    }

    private func stepBirds(dt: Float, want: Int, width: Float, height: Float) {
        guard !treeCenters.isEmpty else {
            birds.removeAll()
            return
        }
        while birds.count > want { birds.removeLast() }
        while birds.count < want {
            let idx = Int.random(in: 0..<treeCenters.count)
            let c = treeCenters[idx]
            birds.append(WoodlandBird(
                x: c.x, y: c.y,
                heading: Float.random(in: 0..<(2 * .pi)),
                targetTreeIdx: idx,
                perched: true,
                timer: Float.random(in: 1.5...6.0),
                flapPhase: Float.random(in: 0...6.28)
            ))
        }

        for i in 0..<birds.count {
            if birds[i].targetTreeIdx >= treeCenters.count {
                birds[i].targetTreeIdx = Int.random(in: 0..<treeCenters.count)
            }
            if birds[i].perched {
                birds[i].timer -= dt
                if birds[i].timer <= 0 {
                    var nextIdx = Int.random(in: 0..<treeCenters.count)
                    for _ in 0..<12 {
                        let cand = Int.random(in: 0..<treeCenters.count)
                        let d = simd_distance(treeCenters[cand], SIMD2(birds[i].x, birds[i].y))
                        if d > 80 && d < 420 {
                            nextIdx = cand
                            break
                        }
                    }
                    birds[i].targetTreeIdx = nextIdx
                    birds[i].perched = false
                }
            } else {
                let target = treeCenters[birds[i].targetTreeIdx]
                let dx = target.x - birds[i].x
                let dy = target.y - birds[i].y
                let dist = hypot(dx, dy)
                if dist < 6.0 {
                    birds[i].x = target.x
                    birds[i].y = target.y
                    birds[i].perched = true
                    birds[i].timer = Float.random(in: 3.0...9.0)
                } else {
                    let desiredH = atan2(dy, dx)
                    let d = atan2(sin(desiredH - birds[i].heading), cos(desiredH - birds[i].heading))
                    // Tighten turn radius near target so off-axis birds don't orbit outside the 6pt landing radius.
                    let turnRate: Float = dist < 40 ? 14.0 : 4.5
                    birds[i].heading += (d >= 0 ? 1 : -1) * min(abs(d), turnRate * dt)
                    let speed: Float = 68.0 * (dist < 40 ? max(0.35, dist / 40) : 1.0)
                    birds[i].x += cos(birds[i].heading) * speed * dt
                    birds[i].y += sin(birds[i].heading) * speed * dt
                    birds[i].flapPhase = (birds[i].flapPhase + dt * 15.0).truncatingRemainder(dividingBy: 2 * .pi)
                }
            }
        }
    }

    @inline(__always)
    private func fract(_ x: Float) -> Float {
        x - floor(x)
    }
}
