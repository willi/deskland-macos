import AppKit
import Metal
import QuartzCore
import simd

@MainActor
final class MetalSharedResources {
    static let shared = MetalSharedResources()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let noiseTex: MTLTexture?
    let emptyTex: MTLTexture?

    let beachPipeline: MTLRenderPipelineState?
    let palmPipeline: MTLRenderPipelineState?
    let meadowPipeline: MTLRenderPipelineState?
    let meadowBoyPipeline: MTLRenderPipelineState?
    let forestPipeline: MTLRenderPipelineState?

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            device = nil
            commandQueue = nil
            noiseTex = nil
            emptyTex = nil
            beachPipeline = nil
            palmPipeline = nil
            meadowPipeline = nil
            meadowBoyPipeline = nil
            forestPipeline = nil
            return
        }
        self.device = dev
        self.commandQueue = queue
        self.noiseTex = TerrainField.makeNoiseTexture(device: dev, commandQueue: queue)

        let emptyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        emptyDesc.usage = [.shaderRead]
        emptyDesc.storageMode = .shared
        let fallback = dev.makeTexture(descriptor: emptyDesc)
        var zero: UInt32 = 0
        fallback?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.emptyTex = fallback

        guard let lib = Self.loadShaderLibrary(device: dev) else {
            beachPipeline = nil
            palmPipeline = nil
            meadowPipeline = nil
            meadowBoyPipeline = nil
            forestPipeline = nil
            return
        }

        let fsVert = lib.makeFunction(name: "fullscreenVertex")

        func makeFullscreenPipeline(fragmentName: String, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState? {
            guard let fsVert, let frag = lib.makeFunction(name: fragmentName) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = fsVert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            return try? dev.makeRenderPipelineState(descriptor: desc)
        }

        self.beachPipeline = makeFullscreenPipeline(fragmentName: "beachFragment")
        self.meadowPipeline = makeFullscreenPipeline(fragmentName: "meadowFragment")
        self.meadowBoyPipeline = makeFullscreenPipeline(fragmentName: "meadowBoyFragment", pixelFormat: .rgba8Unorm)
        self.forestPipeline = makeFullscreenPipeline(fragmentName: "forestFragment")

        if let pVert = lib.makeFunction(name: "palmVertex"),
           let pFrag = lib.makeFunction(name: "palmFragment") {
            let pDesc = MTLRenderPipelineDescriptor()
            pDesc.vertexFunction = pVert
            pDesc.fragmentFunction = pFrag
            let att = pDesc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.palmPipeline = try? dev.makeRenderPipelineState(descriptor: pDesc)
        } else {
            self.palmPipeline = nil
        }
    }

    private static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let mainURL = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: mainURL) {
            return lib
        }
        if let def = device.makeDefaultLibrary(), def.makeFunction(name: "beachFragment") != nil {
            return def
        }
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
            Bundle.module.url(forResource: "Metal/Shaders", withExtension: "metal"),
            Bundle.main.url(forResource: "Shaders", withExtension: "metal")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let src = try? String(contentsOf: url, encoding: .utf8) {
                let opts = MTLCompileOptions()
                opts.mathMode = .fast
                if let lib = try? device.makeLibrary(source: src, options: opts) {
                    return lib
                }
            }
        }
        return nil
    }
}

@MainActor
final class MetalSceneView: NSView {
    let isPreview: Bool

    private var metalLayer: CAMetalLayer!
    private var displayLink: CADisplayLink?

    private let terrain = TerrainField()
    private let beachSim = BeachSimulator()
    private let meadowSim = MeadowSimulator()
    private let forestSim = ForestSimulator()

    private(set) var themeID: String = "beach"

    var params: [String: Double] = [:]
    var seed: Int = 421337
    var timeOfDayMode: TimeOfDayMode = .dynamic
    var customHour: Double = 17.8
    var ambientCap: AmbientFrameCap = .balanced30 {
        didSet { updateDisplayLinkRate() }
    }
    var bottomInset: Float = 72.0

    var isManuallyPaused: Bool = false {
        didSet { updateDisplayLinkState() }
    }
    var isSystemOccluded: Bool = false {
        didSet { updateDisplayLinkState() }
    }
    var isDraggingIcons: Bool = false {
        didSet { updateDisplayLinkRate() }
    }
    private var isHostWindowOccluded: Bool = false {
        didSet { if oldValue != isHostWindowOccluded { updateDisplayLinkState() } }
    }
    private var windowOcclusionObserver: NSObjectProtocol?

    private(set) var obstacles: [IconObstacle] = []
    private var hasReceivedInitialObstacles = false

    private var animTime: Float = 0
    private var lastFrameTimestamp: CFTimeInterval?
    private var highRateBoostUntil: CFTimeInterval = 0
    private var currentTargetHz: Float = 0
    private(set) var measuredFPS: Double = 0
    private(set) var totalPresentedFrames: Int = 0
    private var fpsAccumCount: Int = 0
    private var fpsWindowStart: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    var onTelemetryUpdate: ((Double, Int, Bool) -> Void)?

    init(frame frameRect: NSRect, isPreview: Bool = false) {
        self.isPreview = isPreview
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setupMetalLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        configureMetalLayer(layer)
        self.metalLayer = layer
        return layer
    }

    private func setupMetalLayer() {
        guard let layer = self.layer as? CAMetalLayer else { return }
        configureMetalLayer(layer)
        self.metalLayer = layer
    }

    private func configureMetalLayer(_ layer: CAMetalLayer) {
        let shared = MetalSharedResources.shared
        layer.device = shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
            layer.colorspace = cs
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeHostWindowOcclusion()
        if window != nil {
            setupMetalLayer()
            syncDrawableSize()
            startDisplayLinkIfNeeded()
            updateDisplayLinkState()
            renderImmediateFrame()
        } else {
            stopDisplayLink()
        }
    }

    private func observeHostWindowOcclusion() {
        if let token = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(token)
            windowOcclusionObserver = nil
        }
        guard isPreview, let window else {
            isHostWindowOccluded = false
            return
        }
        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let win = self.window else { return }
                self.isHostWindowOccluded = !win.occlusionState.contains(.visible)
            }
        }
        isHostWindowOccluded = !window.occlusionState.contains(.visible) && window.isVisible
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableSize()
    }

    private func effectiveRenderScale() -> CGFloat {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if isPreview {
            return min(backing, 1.35)
        }
        return min(backing, 2.0)
    }

    func syncDrawableSize() {
        guard let metalLayer, bounds.width > 8, bounds.height > 8 else { return }
        let scale = effectiveRenderScale()
        metalLayer.contentsScale = scale
        let dw = max(16, round(bounds.width * scale))
        let dh = max(16, round(bounds.height * scale))
        if abs(metalLayer.drawableSize.width - dw) > 0.5 || abs(metalLayer.drawableSize.height - dh) > 0.5 {
            metalLayer.drawableSize = CGSize(width: dw, height: dh)
            rebuildField(instant: true)
            boostFrameRate(duration: 0.4)
            renderImmediateFrame()
        }
    }

    func renderImmediateFrame() {
        guard window != nil,
              !isHiddenOrHasHiddenAncestor,
              let metalLayer,
              metalLayer.device != nil,
              metalLayer.drawableSize.width >= 16,
              metalLayer.drawableSize.height >= 16,
              let drawable = metalLayer.nextDrawable() else { return }
        encodeFrame(into: drawable.texture, drawableToPresent: drawable, dt: 1.0 / 60.0, renderScale: Float(effectiveRenderScale()))
    }

    func applyConfiguration(
        themeID: String,
        params: [String: Double],
        seed: Int,
        timeOfDayMode: TimeOfDayMode,
        customHour: Double,
        ambientCap: AmbientFrameCap
    ) {
        let oldSigma = param("sigma", fallback: defaultSigma(for: self.themeID))
        let oldWarp = param("warp", fallback: defaultWarp(for: self.themeID))
        let oldAdaptive = param("adaptive", fallback: 1.0)
        let oldSeed = self.seed
        let oldTheme = self.themeID

        self.themeID = themeID
        self.params = params
        self.seed = seed
        self.timeOfDayMode = timeOfDayMode
        self.customHour = customHour
        self.ambientCap = ambientCap

        let newSigma = param("sigma", fallback: defaultSigma(for: themeID))
        let newWarp = param("warp", fallback: defaultWarp(for: themeID))
        let newAdaptive = param("adaptive", fallback: 1.0)

        if oldSeed != seed {
            beachSim.resetForReseed()
            meadowSim.invalidateMass()
            forestSim.invalidateLayout()
            rebuildField(instant: false, fromEmpty: true)
            boostFrameRate(duration: 2.6)
        } else if oldTheme != themeID || abs(oldSigma - newSigma) > 0.01 || abs(oldWarp - newWarp) > 0.01 || abs(oldAdaptive - newAdaptive) > 0.01 {
            beachSim.invalidatePalmLayout()
            meadowSim.invalidateMass()
            forestSim.invalidateLayout()
            rebuildField(instant: true)
            boostFrameRate(duration: oldTheme != themeID ? 0.9 : 0.5)
            renderImmediateFrame()
        } else {
            boostFrameRate(duration: 0.35)
            if shouldPauseRendering {
                renderImmediateFrame()
            }
        }
    }

    func updateObstacles(_ next: [IconObstacle], liveDrag: Bool, instant: Bool = false) {
        let changed = (next != obstacles)
        obstacles = next
        guard changed || !hasReceivedInitialObstacles else { return }

        let firstLoad = !hasReceivedInitialObstacles
        hasReceivedInitialObstacles = true

        guard let device = MetalSharedResources.shared.device,
              bounds.width > 8, bounds.height > 8 else { return }

        _ = terrain.ensureSize(
            width: Float(bounds.width),
            height: Float(bounds.height),
            seed: Double(seed),
            device: device
        )

        let adaptive = param("adaptive", fallback: 1.0) > 0.5
        let effectiveObs = adaptive ? obstacles : []
        let sigma = Float(param("sigma", fallback: defaultSigma(for: themeID)))
        let warp = Float(param("warp", fallback: defaultWarp(for: themeID)))

        if liveDrag {
            terrain.updateLiveDragTarget(obstacles: effectiveObs, sigma: sigma, warp: warp)
            meadowSim.invalidateMass()
            forestSim.invalidateLayout()
            boostFrameRate(duration: 0.35)
        } else if instant {
            terrain.commit(obstacles: effectiveObs, sigma: sigma, warp: warp, instant: true)
            beachSim.invalidatePalmLayout()
            meadowSim.invalidateMass()
            forestSim.invalidateLayout()
        } else {
            terrain.commit(
                obstacles: effectiveObs,
                sigma: sigma,
                warp: warp,
                instant: false,
                duration: firstLoad ? 1.8 : 0.9
            )
            beachSim.invalidatePalmLayout()
            meadowSim.invalidateMass()
            forestSim.invalidateLayout()
            boostFrameRate(duration: firstLoad ? 1.9 : 1.0)
        }
    }

    func rebuildField(instant: Bool, fromEmpty: Bool = false) {
        guard let device = MetalSharedResources.shared.device,
              bounds.width > 8, bounds.height > 8 else { return }
        _ = terrain.ensureSize(
            width: Float(bounds.width),
            height: Float(bounds.height),
            seed: Double(seed),
            device: device
        )
        let adaptive = param("adaptive", fallback: 1.0) > 0.5
        let effectiveObs = adaptive ? obstacles : []
        let sigma = Float(param("sigma", fallback: defaultSigma(for: themeID)))
        let warp = Float(param("warp", fallback: defaultWarp(for: themeID)))

        if fromEmpty && !effectiveObs.isEmpty {
            terrain.commit(obstacles: [], sigma: sigma, warp: warp, instant: true)
            terrain.commit(obstacles: effectiveObs, sigma: sigma, warp: warp, instant: false, duration: 2.2)
        } else {
            terrain.commit(obstacles: effectiveObs, sigma: sigma, warp: warp, instant: instant)
        }
    }

    func triggerInteractionRipple(at point: CGPoint, strength: Float = 1.0) {
        if themeID == "beach" {
            beachSim.addRipple(x: Float(point.x), y: Float(point.y), strength: strength, field: terrain)
            if beachSim.hasActiveRipples {
                boostFrameRate(duration: 3.0)
            }
        } else {
            boostFrameRate(duration: 0.4)
        }
    }

    func boostFrameRate(duration: CFTimeInterval = 0.6) {
        let until = CFAbsoluteTimeGetCurrent() + duration
        if until > highRateBoostUntil {
            highRateBoostUntil = until
        }
        updateDisplayLinkRate()
        updateDisplayLinkState()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, window != nil else { return }
        let link = self.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        currentTargetHz = 0
        updateDisplayLinkRate()
        updateDisplayLinkState()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
    }

    private var shouldPauseRendering: Bool {
        if window == nil || isHiddenOrHasHiddenAncestor { return true }
        if isManuallyPaused || isSystemOccluded || isHostWindowOccluded { return true }
        return false
    }

    func updateDisplayLinkState() {
        guard let link = displayLink else { return }
        let pause = shouldPauseRendering
        if link.isPaused != pause {
            link.isPaused = pause
            if pause {
                lastFrameTimestamp = nil
                measuredFPS = 0
                onTelemetryUpdate?(0, 0, true)
            } else {
                fpsWindowStart = CFAbsoluteTimeGetCurrent()
                fpsAccumCount = 0
            }
        }
    }

    func updateDisplayLinkRate() {
        guard let link = displayLink else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let needsHighRate = isDraggingIcons ||
            terrain.isAnimatingTransition ||
            beachSim.hasActiveRipples ||
            (now < highRateBoostUntil)

        let target: Float
        let range: CAFrameRateRange
        if isPreview {
            target = needsHighRate ? 60 : 30
            range = CAFrameRateRange(minimum: 24, maximum: target, preferred: target)
        } else if needsHighRate {
            target = 120
            range = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            target = Float(ambientCap.rawValue)
            range = CAFrameRateRange(minimum: min(24, target), maximum: target, preferred: target)
        }

        if abs(currentTargetHz - target) > 0.5 {
            currentTargetHz = target
            link.preferredFrameRateRange = range
        }
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        guard !shouldPauseRendering else {
            updateDisplayLinkState()
            return
        }
        guard let metalLayer,
              metalLayer.device != nil,
              metalLayer.drawableSize.width >= 16,
              metalLayer.drawableSize.height >= 16,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let ts = link.targetTimestamp
        let rawDt: Float
        if let prev = lastFrameTimestamp {
            rawDt = Float(simd_clamp(ts - prev, 1.0 / 240.0, 0.05))
        } else {
            rawDt = 1.0 / 60.0
        }
        lastFrameTimestamp = ts
        animTime += rawDt

        updateDisplayLinkRate()

        fpsAccumCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 0.75 {
            measuredFPS = Double(fpsAccumCount) / elapsed
            fpsAccumCount = 0
            fpsWindowStart = now
            onTelemetryUpdate?(measuredFPS, Int(currentTargetHz), false)
        }

        encodeFrame(into: drawable.texture, drawableToPresent: drawable, dt: rawDt, renderScale: Float(effectiveRenderScale()))
    }

    @discardableResult
    private func encodeFrame(into targetTexture: MTLTexture, drawableToPresent: CAMetalDrawable?, dt: Float, renderScale scale: Float) -> Bool {
        let shared = MetalSharedResources.shared
        guard let device = shared.device,
              let queue = shared.commandQueue,
              let noiseTex = shared.noiseTex,
              let emptyTex = shared.emptyTex,
              let cb = queue.makeCommandBuffer() else { return false }

        let logicalW = Float(targetTexture.width) / scale
        let logicalH = Float(targetTexture.height) / scale

        if terrain.texFA == nil || abs(terrain.width - logicalW) > 2 || abs(terrain.height - logicalH) > 2 {
            _ = terrain.ensureSize(width: logicalW, height: logicalH, seed: Double(seed), device: device)
            rebuildField(instant: true)
        }
        terrain.step(dt: dt)

        guard let texFA = terrain.texFA, let texFB = terrain.texFB else { return false }

        let solar = SolarState.evaluate(mode: timeOfDayMode, customHour: customHour)
        let shaderSeed = Float(abs(seed) % 997) * 0.37

        switch themeID {
        case "meadow":
            guard let meadowPipe = shared.meadowPipeline,
                  let boyPipe = shared.meadowBoyPipeline else { return false }
            meadowSim.ensureSprites(device: device, commandQueue: queue)
            let edge = Float(param("edge", fallback: 0))
            let cover = Float(param("cover", fallback: 0.3))
            let flow = Float(param("flow", fallback: 1.0))
            let sigma = Float(param("sigma", fallback: 72))
            let showBoy = param("showBoy", fallback: 1.0) > 0.5
            let showCat = param("showCat", fallback: 1.0) > 0.5
            meadowSim.step(
                dt: dt,
                time: animTime,
                field: terrain,
                obstacles: obstacles,
                seed: seed,
                edge: edge,
                cover: cover,
                flow: flow,
                sigma: sigma,
                showBoy: showBoy,
                showCat: showCat,
                drawScale: scale,
                bottomInset: isPreview ? 28 : bottomInset,
                device: device
            )

            meadowSim.encodeOffscreenActorPass(commandBuffer: cb, boyPipeline: boyPipe)

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = targetTexture
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(meadowPipe)

            var u = MeadowUniforms()
            u.resAndGrid = SIMD4(logicalW, logicalH, Float(terrain.gridW), Float(terrain.gridH))
            u.core = SIMD4(scale, shaderSeed, TerrainField.step, terrain.curMix)
            u.params = SIMD4(animTime, edge, 0, SpatialCircleGrid.cellG)
            u.gridInfo = SIMD4(
                Float(meadowSim.circleGrid.cgW),
                Float(meadowSim.circleGrid.cgH),
                meadowSim.hasActor ? 1 : 0,
                meadowSim.hasCat ? 1 : 0
            )
            u.lighting = SIMD4(solar.shadowOffset.x, solar.shadowOffset.y, solar.lightDir.x, solar.lightDir.y)
            u.solar = SIMD4(solar.sunsetWeight, solar.nightWeight, 0, 0)
            u.actorRect = meadowSim.actorRect
            u.catRect = meadowSim.catRect
            u.catExtra = meadowSim.catExtra
            u.grassLight = simd4(solar.grassLight)
            u.grassMid = simd4(solar.grassMid)
            u.grassDeep = simd4(solar.grassDeep)
            u.grassInk = simd4(solar.grassInk)
            u.shadowTint = simd4(solar.meadowShadow)
            u.cloudHi = simd4(solar.cloudHighlight)
            u.cloudBody = simd4(solar.cloudBody)
            u.cloudShade = simd4(solar.cloudShade)

            enc.setFragmentBytes(&u, length: MemoryLayout<MeadowUniforms>.stride, index: 0)
            enc.setFragmentTexture(noiseTex, index: 0)
            enc.setFragmentTexture(texFA, index: 1)
            enc.setFragmentTexture(texFB, index: 2)
            enc.setFragmentTexture(meadowSim.circleGrid.texture ?? emptyTex, index: 3)
            enc.setFragmentTexture(meadowSim.actorTex ?? emptyTex, index: 4)
            enc.setFragmentTexture(meadowSim.actorShadowTex ?? emptyTex, index: 5)
            enc.setFragmentTexture(meadowSim.catTex ?? emptyTex, index: 6)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

        case "forest":
            guard let forestPipe = shared.forestPipeline else { return false }
            let density = Float(param("density", fallback: 0.72))
            let wind = Float(param("wind", fallback: 1.0))
            let sigma = Float(param("sigma", fallback: 82))
            let wantBirds = Int(param("birds", fallback: 4).rounded())

            forestSim.step(
                dt: dt,
                time: animTime,
                field: terrain,
                seed: seed,
                density: density,
                wind: wind,
                wantBirds: wantBirds,
                nightWeight: solar.nightWeight,
                device: device
            )

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = targetTexture
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(forestPipe)

            var u = ForestUniforms()
            u.resAndGrid = SIMD4(logicalW, logicalH, Float(terrain.gridW), Float(terrain.gridH))
            u.core = SIMD4(scale, shaderSeed, TerrainField.step, terrain.curMix)
            u.params = SIMD4(animTime, wind, sigma, SpatialCircleGrid.cellG)
            u.gridInfo = SIMD4(
                Float(forestSim.circleGrid.cgW),
                Float(forestSim.circleGrid.cgH),
                Float(forestSim.birds.count),
                solar.nightWeight
            )
            u.lighting = SIMD4(solar.lightDir.x, solar.lightDir.y, solar.sunsetWeight, 0)
            u.clearingLight = simd4(solar.clearingLight)
            u.clearingMid = simd4(solar.clearingMid)
            u.canopy0 = simd4(solar.canopy0)
            u.canopy1 = simd4(solar.canopy1)
            u.canopy2 = simd4(solar.canopy2)
            u.canopyRim = simd4(solar.canopyRim)
            u.shadowTint = simd4(solar.forestShadow)
            u.grassInk = simd4(solar.grassInk)

            withUnsafeMutablePointer(to: &u.birds) { ptr in
                let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SIMD4<Float>.self)
                for (i, b) in forestSim.birds.prefix(8).enumerated() {
                    let span: Float = b.perched ? 0.22 : (0.65 + 0.35 * cos(b.flapPhase))
                    buf[i] = SIMD4(b.x, b.y, b.heading, span)
                }
            }

            enc.setFragmentBytes(&u, length: MemoryLayout<ForestUniforms>.stride, index: 0)
            enc.setFragmentTexture(noiseTex, index: 0)
            enc.setFragmentTexture(texFA, index: 1)
            enc.setFragmentTexture(texFB, index: 2)
            enc.setFragmentTexture(forestSim.circleGrid.texture ?? emptyTex, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

        default:
            guard let beachPipe = shared.beachPipeline else { return false }
            beachSim.ensureAtlas(device: device, commandQueue: queue)

            let speed = Float(param("speed", fallback: 22))
            let spacing = Float(param("spacing", fallback: 70))
            let runup = Float(param("runup", fallback: 120))
            let wave = Float(param("wave", fallback: 1.6))
            let shallow = Float(param("shallow", fallback: 260))
            let shoal = Float(param("shoal", fallback: 110))
            let sigma = Float(param("sigma", fallback: 85))
            let wantKayaks = Int(param("kayaks", fallback: 2).rounded())
            let wantBirds = Int(param("birds", fallback: 3).rounded())
            let wantPalms = Int(param("palms", fallback: 4).rounded())

            beachSim.step(
                dt: dt,
                field: terrain,
                obstacles: obstacles,
                seed: seed,
                wantKayaks: wantKayaks,
                wantBirds: wantBirds,
                wantPalms: wantPalms,
                bottomInset: isPreview ? 28 : bottomInset,
                nightWeight: solar.nightWeight
            )

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = targetTexture
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(beachPipe)

            var u = BeachUniforms()
            u.resAndGrid = SIMD4(logicalW, logicalH, Float(terrain.gridW), Float(terrain.gridH))
            u.core = SIMD4(scale, shaderSeed, TerrainField.step, terrain.curMix)
            u.wave0 = SIMD4(animTime, speed, runup, wave)
            u.wave1 = SIMD4(max(40, spacing), sigma, max(20, shallow), shoal)
            u.counts = SIMD4(1.0, 0, Float(beachSim.kayaks.count), Float(beachSim.birds.count))
            u.solar = SIMD4(solar.sunsetWeight, solar.nightWeight, solar.lightDir.x, solar.lightDir.y)

            u.sea0 = simd4(solar.sea0)
            u.sea1 = simd4(solar.sea1)
            u.sea2 = simd4(solar.sea2)
            u.sea3 = simd4(solar.sea3)
            u.sea4 = simd4(solar.sea4)
            u.sand0 = simd4(solar.sand0)
            u.sand1 = simd4(solar.sand1)
            u.sand2 = simd4(solar.sand2)
            u.sand3 = simd4(solar.sand3)
            u.wetSand = simd4(solar.wetSand)
            u.foam = simd4(solar.foam)
            u.sparkColor = simd4(solar.sparkColor)
            u.bed0 = simd4(solar.bed0)
            u.bed1 = simd4(solar.bed1)
            u.shoalTint0 = simd4(solar.shoalTint0)
            u.shoalTint1 = simd4(solar.shoalTint1)
            u.palmTint = simd4(solar.palmTint)

            withUnsafeMutablePointer(to: &u.kayaks) { ptr in
                let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SIMD4<Float>.self)
                for (i, k) in beachSim.kayaks.prefix(4).enumerated() {
                    buf[i] = SIMD4(k.x, k.y, k.h, k.ph)
                }
            }
            withUnsafeMutablePointer(to: &u.ripples) { ptr in
                let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SIMD4<Float>.self)
                for (i, r) in beachSim.ripples.prefix(6).enumerated() {
                    buf[i] = SIMD4(r.x, r.y, r.age, r.strength)
                }
            }
            withUnsafeMutablePointer(to: &u.birds) { ptr in
                let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SIMD4<Float>.self)
                for (i, b) in beachSim.birds.prefix(8).enumerated() {
                    buf[i] = SIMD4(b.x, b.y, b.h, 0.68 + 0.32 * cos(b.ph))
                }
            }

            enc.setFragmentBytes(&u, length: MemoryLayout<BeachUniforms>.stride, index: 0)
            enc.setFragmentTexture(noiseTex, index: 0)
            enc.setFragmentTexture(texFA, index: 1)
            enc.setFragmentTexture(texFB, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if let palmPipe = shared.palmPipeline,
               let atlas = beachSim.palmAtlas,
               !beachSim.palms.isEmpty {
                enc.setRenderPipelineState(palmPipe)
                enc.setVertexBytes(&u, length: MemoryLayout<BeachUniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<BeachUniforms>.stride, index: 0)
                enc.setFragmentTexture(atlas, index: 0)
                let numVariants = Float(BeachSimulator.palmStyles.count)
                for palm in beachSim.palms where palm.opacity >= 0.003 {
                    var pu = PalmInstanceUniforms(
                        palm: SIMD4(palm.x, palm.y, palm.scale, Float(palm.variant)),
                        extra: SIMD4(palm.mirror, palm.opacity, numVariants, 0)
                    )
                    enc.setVertexBytes(&pu, length: MemoryLayout<PalmInstanceUniforms>.stride, index: 1)
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PalmInstanceUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }

            enc.endEncoding()
        }

        if let drawableToPresent {
            cb.present(drawableToPresent)
            totalPresentedFrames += 1
        }
        cb.commit()
        if drawableToPresent == nil {
            cb.waitUntilCompleted()
        }
        return true
    }

    func renderPrivacySnapshot(includeAnonymizedIcons: Bool = true) -> NSImage? {
        guard let device = MetalSharedResources.shared.device,
              bounds.width > 32, bounds.height > 32 else { return nil }
        let scale: CGFloat = 2.0
        let texW = Int(round(bounds.width * scale))
        let texH = Int(round(bounds.height * scale))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let offTex = device.makeTexture(descriptor: desc) else { return nil }

        guard encodeFrame(into: offTex, drawableToPresent: nil, dt: 0, renderScale: Float(scale)) else { return nil }

        let bytesPerRow = texW * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * texH)
        offTex.getBytes(&bgra, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0)

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return bgra.withUnsafeMutableBytes { raw -> NSImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: texW,
                      height: texH,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: cs,
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return nil }

            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(texH))
            ctx.scaleBy(x: scale, y: -scale)

            if includeAnonymizedIcons {
                let palette: [(CGFloat, CGFloat, CGFloat)] = [
                    (0.35, 0.68, 0.96),
                    (0.98, 0.75, 0.32),
                    (0.42, 0.80, 0.62),
                    (0.94, 0.48, 0.52),
                    (0.66, 0.56, 0.94)
                ]
                for (idx, ob) in obstacles.enumerated() {
                    let r = CGRect(x: CGFloat(ob.x), y: CGFloat(ob.y), width: CGFloat(ob.w), height: CGFloat(ob.h))

                    if r.width >= 130 && r.height >= 130 {
                        ctx.saveGState()
                        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: NSColor.black.withAlphaComponent(0.18).cgColor)
                        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.88)
                        let cardPath = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
                        ctx.addPath(cardPath)
                        ctx.fillPath()
                        ctx.restoreGState()

                        ctx.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.65)
                        ctx.setLineWidth(1.0)
                        ctx.addPath(cardPath)
                        ctx.strokePath()

                        let accent = palette[idx % palette.count]
                        let pill = CGRect(x: r.minX + 16, y: r.minY + 16, width: min(56, r.width * 0.36), height: 10)
                        ctx.setFillColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 0.80)
                        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil))
                        ctx.fillPath()

                        for row in 0..<3 {
                            let barW = (r.width - 32) * (row == 2 ? 0.62 : 0.88)
                            let bar = CGRect(x: r.minX + 16, y: r.minY + 42 + CGFloat(row) * 26, width: barW, height: 12)
                            ctx.setFillColor(red: 0.15, green: 0.18, blue: 0.24, alpha: 0.10)
                            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil))
                            ctx.fillPath()
                        }
                        continue
                    }

                    let iconSize = min(44.0, r.width * 0.58)
                    let iconRect = CGRect(
                        x: r.midX - iconSize * 0.5,
                        y: r.minY + 4,
                        width: iconSize,
                        height: iconSize * 0.84
                    )
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: NSColor.black.withAlphaComponent(0.22).cgColor)
                    let c = palette[idx % palette.count]
                    ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 0.94)
                    let bodyPath = CGPath(roundedRect: iconRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
                    ctx.addPath(bodyPath)
                    ctx.fillPath()
                    ctx.restoreGState()

                    let pillW = min(r.width * 0.72, 54.0 - CGFloat((idx * 7) % 16))
                    let pillRect = CGRect(
                        x: r.midX - pillW * 0.5,
                        y: iconRect.maxY + 6,
                        width: pillW,
                        height: 8
                    )
                    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.82)
                    ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.fillPath()
                }
            }

            ctx.restoreGState()
            guard let cgImg = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cgImg, size: bounds.size)
        }
    }

    private func param(_ key: String, fallback: Double) -> Double {
        params[key] ?? fallback
    }

    private func defaultSigma(for theme: String) -> Double {
        switch theme {
        case "meadow": return 72
        case "forest": return 82
        default: return 85
        }
    }

    private func defaultWarp(for theme: String) -> Double {
        switch theme {
        case "meadow": return 28
        case "forest": return 26
        default: return 34
        }
    }
}
