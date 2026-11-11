import Foundation
import Metal
import simd

final class TerrainField {
    static let step: Float = 5.0

    private(set) var width: Float = 1
    private(set) var height: Float = 1
    private(set) var gridW: Int = 2
    private(set) var gridH: Int = 2
    private(set) var seed: Double = 42.0

    private var warpX: [Float] = []
    private var warpY: [Float] = []

    private(set) var fieldA: [Float] = []
    private(set) var fieldB: [Float] = []
    private var liveTarget: [Float] = []
    private var halfBuffer: [Float16] = []

    private(set) var texFA: MTLTexture?
    private(set) var texFB: MTLTexture?

    private(set) var curMix: Float = 1.0
    private var morphElapsed: Float = 1.0
    private var morphDuration: Float = 0.9
    private(set) var isLiveSmoothing: Bool = false

    var isAnimatingTransition: Bool {
        curMix < 0.999 || isLiveSmoothing
    }

    init() {}

    @inline(__always)
    static func hash2(_ i: Int, _ j: Int, _ seed: Double) -> Double {
        let h = sin(Double(i) * 127.1 + Double(j) * 311.7 + seed * 74.7) * 43758.5453
        return h - floor(h)
    }

    static func vnoise(_ x: Double, _ y: Double, _ seed: Double) -> Double {
        let ix = Int(floor(x))
        let iy = Int(floor(y))
        let fx = x - Double(ix)
        let fy = y - Double(iy)
        let ux = fx * fx * (3.0 - 2.0 * fx)
        let uy = fy * fy * (3.0 - 2.0 * fy)
        let a = hash2(ix, iy, seed)
        let b = hash2(ix + 1, iy, seed)
        let c = hash2(ix, iy + 1, seed)
        let d = hash2(ix + 1, iy + 1, seed)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    static func fbm(_ x: Double, _ y: Double, _ seed: Double, octaves: Int = 4) -> Double {
        var v = 0.0
        var amp = 0.5
        var f = 1.0
        for o in 0..<octaves {
            v += amp * (vnoise(x * f, y * f, seed + Double(o) * 19.3) - 0.5) * 2.0
            f *= 2.03
            amp *= 0.5
        }
        return v
    }

    func ensureSize(width: Float, height: Float, seed: Double, device: MTLDevice) -> Bool {
        let w = max(64, width)
        let h = max(64, height)
        let gw = Int(ceil(w / Self.step)) + 1
        let gh = Int(ceil(h / Self.step)) + 1
        let count = gw * gh

        let sizeChanged = (gw != gridW || gh != gridH || texFA == nil || texFB == nil)
        let seedChanged = abs(seed - self.seed) > 1e-6

        self.width = w
        self.height = h
        self.gridW = gw
        self.gridH = gh
        self.seed = seed

        if sizeChanged {
            fieldA = [Float](repeating: 400, count: count)
            fieldB = [Float](repeating: 400, count: count)
            liveTarget = [Float](repeating: 400, count: count)
            halfBuffer = [Float16](repeating: 400, count: count)

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: gw,
                height: gh,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            texFA = device.makeTexture(descriptor: desc)
            texFB = device.makeTexture(descriptor: desc)
        }

        if sizeChanged || seedChanged {
            buildWarpTable()
        }

        return sizeChanged || seedChanged
    }

    private func buildWarpTable() {
        let count = gridW * gridH
        if warpX.count != count {
            warpX = [Float](repeating: 0, count: count)
            warpY = [Float](repeating: 0, count: count)
        }
        let sd = seed
        let st = Double(Self.step)
        for j in 0..<gridH {
            let y = Double(j) * st * 0.0028
            let row = j * gridW
            for i in 0..<gridW {
                let x = Double(i) * st * 0.0028
                warpX[row + i] = Float(Self.fbm(x, y, sd + 1.0, octaves: 4) * 0.5)
                warpY[row + i] = Float(Self.fbm(x + 17.1, y + 31.7, sd + 2.0, octaves: 4) * 0.5)
            }
        }
    }

    func computeRawField(obstacles: [IconObstacle], sigma: Float, warp: Float, into out: inout [Float]) {
        let count = gridW * gridH
        if out.count != count {
            out = [Float](repeating: 400, count: count)
        }

        let sig = max(8.0, sigma)
        let is1 = 1.0 / (sig * sig)
        let wa = warp * 2.2
        let wmax = wa * 0.5
        let st = Self.step
        let gw = gridW
        let gh = gridH
        let c0 = Float((-Darwin.log(0.35)).squareRoot())
        let fMin = Float(Darwin.exp(-30.0))

        guard !obstacles.isEmpty else {
            let emptyVal = sig * (Float(30.0).squareRoot() - c0)
            for k in 0..<count { out[k] = emptyVal }
            return
        }

        var f1 = [Float](repeating: 0, count: count)
        warpX.withUnsafeBufferPointer { wxPtr in
            warpY.withUnsafeBufferPointer { wyPtr in
                f1.withUnsafeMutableBufferPointer { f1Ptr in
                    for ob in obstacles {
                        let cx = ob.cx
                        let cy = ob.cy
                        let chw = ob.hw * 0.5
                        let chh = ob.hh * 0.5
                        let R = 5.5 * sig + max(ob.hw, ob.hh) * 0.5 + wmax
                        let gx0 = max(0, Int(floor((cx - R) / st)))
                        let gx1 = min(gw - 1, Int(ceil((cx + R) / st)))
                        let gy0 = max(0, Int(floor((cy - R) / st)))
                        let gy1 = min(gh - 1, Int(ceil((cy + R) / st)))
                        if gx0 > gx1 || gy0 > gy1 { continue }

                        for gy in gy0...gy1 {
                            let baseY = Float(gy) * st
                            let row = gy * gw
                            for gx in gx0...gx1 {
                                let idx = row + gx
                                let qx = Float(gx) * st + wxPtr[idx] * wa
                                let qy = baseY + wyPtr[idx] * wa
                                let dx = max(abs(qx - cx) - chw, 0)
                                let dy = max(abs(qy - cy) - chh, 0)
                                f1Ptr[idx] += exp(-(dx * dx + dy * dy) * is1)
                            }
                        }
                    }
                }
            }
        }

        f1.withUnsafeBufferPointer { f1Ptr in
            out.withUnsafeMutableBufferPointer { outPtr in
                for i in 0..<count {
                    let g = log(max(f1Ptr[i], fMin))
                    outPtr[i] = sig * (sqrt(max(-g, 0)) - c0) - sig * 0.6 * max(g, 0)
                }
            }
        }
    }

    func commit(
        obstacles: [IconObstacle],
        sigma: Float,
        warp: Float,
        instant: Bool,
        duration: Float = 0.9
    ) {
        isLiveSmoothing = false
        if instant {
            computeRawField(obstacles: obstacles, sigma: sigma, warp: warp, into: &fieldB)
            fieldA = fieldB
            liveTarget = fieldB
            upload(fieldA, to: texFA)
            upload(fieldB, to: texFB)
            curMix = 1.0
            morphElapsed = duration
            morphDuration = max(0.05, duration)
            return
        }

        let count = fieldA.count
        let m = curMix
        if m < 0.999 {
            for i in 0..<count {
                fieldA[i] = fieldA[i] * (1.0 - m) + fieldB[i] * m
            }
        } else {
            fieldA = fieldB
        }
        computeRawField(obstacles: obstacles, sigma: sigma, warp: warp, into: &fieldB)
        liveTarget = fieldB
        upload(fieldA, to: texFA)
        upload(fieldB, to: texFB)
        curMix = 0.0
        morphElapsed = 0.0
        morphDuration = max(0.08, duration)
    }

    func updateLiveDragTarget(obstacles: [IconObstacle], sigma: Float, warp: Float) {
        if curMix < 0.999 {
            let m = curMix
            for i in 0..<fieldB.count {
                fieldB[i] = fieldA[i] * (1.0 - m) + fieldB[i] * m
            }
            curMix = 1.0
        }
        computeRawField(obstacles: obstacles, sigma: sigma, warp: warp, into: &liveTarget)
        isLiveSmoothing = true
    }

    @discardableResult
    func step(dt: Float) -> Bool {
        var changed = false
        if curMix < 1.0 {
            morphElapsed += dt
            let t = simd_clamp(morphElapsed / morphDuration, 0, 1)
            curMix = t * t * (3.0 - 2.0 * t)
            if t >= 1.0 {
                curMix = 1.0
            }
            changed = true
        }

        if isLiveSmoothing {
            let alpha = min(1.0, dt * 16.0)
            var maxDelta: Float = 0
            let count = min(fieldB.count, liveTarget.count)
            fieldB.withUnsafeMutableBufferPointer { fb in
                liveTarget.withUnsafeBufferPointer { tgt in
                    for i in 0..<count {
                        let diff = tgt[i] - fb[i]
                        let ad = abs(diff)
                        if ad > maxDelta { maxDelta = ad }
                        fb[i] += diff * alpha
                    }
                }
            }
            curMix = 1.0
            upload(fieldB, to: texFB)
            changed = true
            if maxDelta < 0.15 {
                fieldB = liveTarget
                upload(fieldB, to: texFB)
                isLiveSmoothing = false
            }
        }

        return changed
    }

    private func upload(_ src: [Float], to texture: MTLTexture?) {
        guard let texture, src.count == gridW * gridH else { return }
        if halfBuffer.count != src.count {
            halfBuffer = [Float16](repeating: 0, count: src.count)
        }
        src.withUnsafeBufferPointer { sPtr in
            halfBuffer.withUnsafeMutableBufferPointer { hPtr in
                for i in 0..<sPtr.count {
                    hPtr[i] = Float16(sPtr[i])
                }
                if let base = hPtr.baseAddress {
                    let region = MTLRegionMake2D(0, 0, gridW, gridH)
                    texture.replace(
                        region: region,
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: gridW * MemoryLayout<Float16>.stride
                    )
                }
            }
        }
    }

    func sample(x: Float, y: Float) -> Float {
        guard !fieldB.isEmpty else { return 400 }
        let gx = simd_clamp(x / Self.step, 0, Float(gridW - 1) - 1e-4)
        let gy = simd_clamp(y / Self.step, 0, Float(gridH - 1) - 1e-4)
        let i = Int(gx)
        let j = Int(gy)
        let fx = gx - Float(i)
        let fy = gy - Float(j)
        let m = curMix

        @inline(__always)
        func val(_ idx: Int) -> Float {
            if m >= 0.999 { return fieldB[idx] }
            return fieldA[idx] * (1.0 - m) + fieldB[idx] * m
        }

        let r0 = j * gridW + i
        let r1 = (j + 1) * gridW + i
        let v00 = val(r0)
        let v10 = val(r0 + 1)
        let v01 = val(r1)
        let v11 = val(r1 + 1)
        let top = v00 * (1 - fx) + v10 * fx
        let bot = v01 * (1 - fx) + v11 * fx
        return top * (1 - fy) + bot * fy
    }

    func sampleB(x: Float, y: Float) -> Float {
        guard !fieldB.isEmpty else { return 400 }
        let gx = simd_clamp(x / Self.step, 0, Float(gridW - 1) - 1e-4)
        let gy = simd_clamp(y / Self.step, 0, Float(gridH - 1) - 1e-4)
        let i = Int(gx)
        let j = Int(gy)
        let fx = gx - Float(i)
        let fy = gy - Float(j)
        let r0 = j * gridW + i
        let r1 = (j + 1) * gridW + i
        let top = fieldB[r0] * (1 - fx) + fieldB[r0 + 1] * fx
        let bot = fieldB[r1] * (1 - fx) + fieldB[r1 + 1] * fx
        return top * (1 - fy) + bot * fy
    }

    static func makeNoiseTexture(device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLTexture? {
        let N = 256
        var data = [UInt8](repeating: 0, count: N * N * 4)

        func pnoise(_ x: Double, _ y: Double, _ period: Int, _ sd: Double) -> Double {
            let ix = Int(floor(x))
            let iy = Int(floor(y))
            let fx = x - Double(ix)
            let fy = y - Double(iy)
            let ux = fx * fx * (3.0 - 2.0 * fx)
            let uy = fy * fy * (3.0 - 2.0 * fy)
            let p = period
            let i0 = ((ix % p) + p) % p
            let j0 = ((iy % p) + p) % p
            let i1 = (i0 + 1) % p
            let j1 = (j0 + 1) % p
            let a = hash2(i0, j0, sd)
            let b = hash2(i1, j0, sd)
            let c = hash2(i0, j1, sd)
            let d = hash2(i1, j1, sd)
            return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
        }

        func tileFbm(_ u: Double, _ v: Double, _ periods: [Int], _ sd: Double) -> Double {
            var s = 0.0
            var w = 0.5
            var tw = 0.0
            for (i, p) in periods.enumerated() {
                s += w * pnoise(u * Double(p), v * Double(p), p, sd + Double(i * 13))
                tw += w
                w *= 0.5
            }
            return s / tw
        }

        let chans: [[Int]] = [[8, 16, 32, 64], [8, 16, 32, 64], [8, 16, 32], [16, 32, 64, 128]]
        for y in 0..<N {
            let v = Double(y) / Double(N)
            for x in 0..<N {
                let u = Double(x) / Double(N)
                let idx = (y * N + x) * 4
                for c in 0..<4 {
                    let n = tileFbm(u, v, chans[c], Double(100 + c * 50))
                    let contrasted = min(1.0, max(0.0, (n - 0.5) * 1.9 + 0.5))
                    data[idx + c] = UInt8(min(255, max(0, Int(contrasted * 255.0))))
                }
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: N,
            height: N,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, N, N),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: N * 4
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
