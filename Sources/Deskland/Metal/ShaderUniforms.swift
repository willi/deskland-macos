import simd

struct BeachUniforms {
    var resAndGrid: SIMD4<Float> = .zero
    var core: SIMD4<Float> = .zero
    var wave0: SIMD4<Float> = .zero
    var wave1: SIMD4<Float> = .zero
    var counts: SIMD4<Float> = .zero
    var solar: SIMD4<Float> = .zero

    var sea0: SIMD4<Float> = .zero
    var sea1: SIMD4<Float> = .zero
    var sea2: SIMD4<Float> = .zero
    var sea3: SIMD4<Float> = .zero
    var sea4: SIMD4<Float> = .zero
    var sand0: SIMD4<Float> = .zero
    var sand1: SIMD4<Float> = .zero
    var sand2: SIMD4<Float> = .zero
    var sand3: SIMD4<Float> = .zero
    var wetSand: SIMD4<Float> = .zero
    var foam: SIMD4<Float> = .zero
    var sparkColor: SIMD4<Float> = .zero
    var bed0: SIMD4<Float> = .zero
    var bed1: SIMD4<Float> = .zero
    var shoalTint0: SIMD4<Float> = .zero
    var shoalTint1: SIMD4<Float> = .zero
    var palmTint: SIMD4<Float> = .zero

    var kayaks: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var ripples: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero)
    var birds: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

struct PalmInstanceUniforms {
    var palm: SIMD4<Float> = .zero
    var extra: SIMD4<Float> = .zero
}

struct MeadowUniforms {
    var resAndGrid: SIMD4<Float> = .zero
    var core: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero
    var gridInfo: SIMD4<Float> = .zero
    var lighting: SIMD4<Float> = .zero
    var solar: SIMD4<Float> = .zero

    var actorRect: SIMD4<Float> = .zero
    var catRect: SIMD4<Float> = .zero
    var catExtra: SIMD4<Float> = .zero

    var grassLight: SIMD4<Float> = .zero
    var grassMid: SIMD4<Float> = .zero
    var grassDeep: SIMD4<Float> = .zero
    var grassInk: SIMD4<Float> = .zero
    var shadowTint: SIMD4<Float> = .zero
    var cloudHi: SIMD4<Float> = .zero
    var cloudBody: SIMD4<Float> = .zero
    var cloudShade: SIMD4<Float> = .zero
}

struct MeadowBoyUniforms {
    var resAndOffset: SIMD4<Float> = .zero
    var place: SIMD4<Float> = .zero
    var kiteAndTime: SIMD4<Float> = .zero
    var pose: SIMD4<Float> = .zero
    var motion: SIMD4<Float> = .zero
    var rig: SIMD4<Float> = .zero
    var leftHipKnee: SIMD4<Float> = .zero
    var rightHipKnee: SIMD4<Float> = .zero
    var ankles: SIMD4<Float> = .zero
    var feetAndGround: SIMD4<Float> = .zero
    var contactLAndTension: SIMD4<Float> = .zero
    var contactRAndRock: SIMD4<Float> = .zero
    var bodyAndLegs: SIMD4<Float> = .zero
    var handAndTug: SIMD4<Float> = .zero
    var solarTint: SIMD4<Float> = .zero
}

struct ForestUniforms {
    var resAndGrid: SIMD4<Float> = .zero
    var core: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero
    var gridInfo: SIMD4<Float> = .zero
    var lighting: SIMD4<Float> = .zero

    var clearingLight: SIMD4<Float> = .zero
    var clearingMid: SIMD4<Float> = .zero
    var canopy0: SIMD4<Float> = .zero
    var canopy1: SIMD4<Float> = .zero
    var canopy2: SIMD4<Float> = .zero
    var canopyRim: SIMD4<Float> = .zero
    var shadowTint: SIMD4<Float> = .zero
    var grassInk: SIMD4<Float> = .zero

    var birds: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var ripples: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
}

@inline(__always)
func simd4(_ v: SIMD3<Float>, _ w: Float = 0) -> SIMD4<Float> {
    SIMD4<Float>(v.x, v.y, v.z, w)
}
