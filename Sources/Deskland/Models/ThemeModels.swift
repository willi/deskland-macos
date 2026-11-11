import Foundation
import CoreGraphics
import simd

struct ThemeRegistry: Codable, Sendable {
    let version: Int
    var themes: [ThemeDefinition]
}

struct ThemeDefinition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var adaptive: Bool?
    var name: String
    var desc: String
    var page: String?
    var renderer: String?
    var status: String?
    var product: String?
    var locked: Bool?
    var thumb: String?
    var groups: [ThemeParamGroup]?
    var externalFolderPath: String?

    var isReady: Bool { status == "ready" && locked != true }
    var isBuiltInMetal: Bool {
        (id == "beach" || id == "meadow" || id == "forest") && externalFolderPath == nil
    }
}

struct ThemeParamGroup: Codable, Sendable, Equatable {
    var name: String
    var params: [ThemeParam]
}

struct ThemeParam: Codable, Identifiable, Sendable, Equatable {
    var id: String { key }
    let key: String
    var label: String
    var hint: String?
    var min: Double?
    var max: Double?
    var step: Double?
    var `default`: Double
    var unit: String?
    var format: String?
    var options: [String]?

    func formattedValue(_ value: Double) -> String {
        if let options, !options.isEmpty {
            let idx = Swift.max(0, Swift.min(options.count - 1, Int(value.rounded())))
            return options[idx]
        }
        if format == "times" {
            return String(format: "×%.2f", value)
        }
        if format == "percent" {
            return "\(Int((value * 100).rounded()))%"
        }
        let isIntStep = step.map { abs($0.rounded() - $0) < 1e-6 } ?? true
        let numStr = isIntStep ? "\(Int(value.rounded()))" : String(format: "%.2f", value)
        if let unit, !unit.isEmpty {
            return "\(numStr) \(unit)"
        }
        return numStr
    }
}

struct DesklandI18n: Sendable {
    var ui: [String: String] = [:]
    var host: [String: String] = [:]
    var themes: [String: ThemeTranslation] = [:]

    struct ThemeTranslation: Codable, Sendable {
        var name: String?
        var desc: String?
        var groups: [String]?
        var params: [String: ParamTranslation]?
    }

    struct ParamTranslation: Codable, Sendable {
        var label: String?
        var hint: String?
        var unit: String?
        var options: [String]?
    }
}

extension DesklandI18n: Codable {}

enum DesktopIconMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case desklandInteractive = "interactive"
    case finderUnderlay = "finder"

    var id: String { rawValue }
}

enum TimeOfDayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dynamic = "dynamic"
    case day = "day"
    case sunset = "sunset"
    case night = "night"
    case dawn = "dawn"
    case custom = "custom"

    var id: String { rawValue }
}

enum AmbientFrameCap: Int, Codable, CaseIterable, Identifiable, Sendable {
    case eco24 = 24
    case balanced30 = 30
    case smooth60 = 60
    case proMotion120 = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .eco24: return "24 Hz (Eco)"
        case .balanced30: return "30 Hz (Balanced)"
        case .smooth60: return "60 Hz"
        case .proMotion120: return "120 Hz Always"
        }
    }
}

struct SolarState: Sendable {
    var hour: Float
    var sunsetWeight: Float
    var nightWeight: Float
    var lightDir: SIMD2<Float>

    var sea0: SIMD3<Float>
    var sea1: SIMD3<Float>
    var sea2: SIMD3<Float>
    var sea3: SIMD3<Float>
    var sea4: SIMD3<Float>
    var sand0: SIMD3<Float>
    var sand1: SIMD3<Float>
    var sand2: SIMD3<Float>
    var sand3: SIMD3<Float>
    var wetSand: SIMD3<Float>
    var foam: SIMD3<Float>
    var sparkColor: SIMD3<Float>
    var bed0: SIMD3<Float>
    var bed1: SIMD3<Float>
    var shoalTint0: SIMD3<Float>
    var shoalTint1: SIMD3<Float>
    var palmTint: SIMD3<Float>

    var grassLight: SIMD3<Float>
    var grassMid: SIMD3<Float>
    var grassDeep: SIMD3<Float>
    var grassInk: SIMD3<Float>
    var meadowShadow: SIMD3<Float>
    var cloudHighlight: SIMD3<Float>
    var cloudBody: SIMD3<Float>
    var cloudShade: SIMD3<Float>
    var shadowOffset: SIMD2<Float>

    var clearingLight: SIMD3<Float>
    var clearingMid: SIMD3<Float>
    var canopy0: SIMD3<Float>
    var canopy1: SIMD3<Float>
    var canopy2: SIMD3<Float>
    var canopyRim: SIMD3<Float>
    var forestShadow: SIMD3<Float>

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func evaluate(mode: TimeOfDayMode, customHour: Double, date: Date = Date()) -> SolarState {
        let h: Float
        switch mode {
        case .dynamic:
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute, .second], from: date)
            let hh = Float(comps.hour ?? 12)
            let mm = Float(comps.minute ?? 0) / 60.0
            let ss = Float(comps.second ?? 0) / 3600.0
            h = hh + mm + ss
        case .day:
            h = 12.0
        case .sunset:
            h = 18.15
        case .night:
            h = 23.0
        case .dawn:
            h = 6.05
        case .custom:
            h = Float(customHour.truncatingRemainder(dividingBy: 24.0))
        }

        let dawnRise = smooth(4.8, 6.0, h) * (1.0 - smooth(6.1, 7.5, h))
        let sunsetRise = smooth(16.5, 18.1, h) * (1.0 - smooth(18.25, 19.9, h))
        let twilight = smooth(18.6, 19.5, h) * (1.0 - smooth(19.6, 20.7, h))
        let nightMorning = 1.0 - smooth(5.1, 6.9, h)
        let nightEvening = smooth(18.9, 20.6, h)
        let night = simd_clamp(max(nightMorning, nightEvening), 0, 1)
        let warm = simd_clamp(sunsetRise + dawnRise * 0.78, 0, 1)

        let daySea0 = SIMD3<Float>(0.74, 0.93, 0.87)
        let daySea1 = SIMD3<Float>(0.47, 0.87, 0.84)
        let daySea2 = SIMD3<Float>(0.17, 0.76, 0.81)
        let daySea3 = SIMD3<Float>(0.03, 0.66, 0.79)
        let daySea4 = SIMD3<Float>(0.00, 0.56, 0.73)
        let daySand0 = SIMD3<Float>(0.97, 0.93, 0.88)
        let daySand1 = SIMD3<Float>(0.91, 0.85, 0.84)
        let daySand2 = SIMD3<Float>(0.82, 0.76, 0.79)
        let daySand3 = SIMD3<Float>(0.71, 0.67, 0.75)
        let dayWet   = SIMD3<Float>(0.93, 0.86, 0.72)
        let dayFoam  = SIMD3<Float>(0.98, 0.99, 0.98)
        let daySpark = SIMD3<Float>(0.96, 1.00, 1.00)
        let dayBed0  = SIMD3<Float>(0.97, 0.91, 0.79)
        let dayBed1  = SIMD3<Float>(0.88, 0.90, 0.77)
        let dayTint0 = SIMD3<Float>(0.93, 0.99, 0.96)
        let dayTint1 = SIMD3<Float>(0.62, 0.92, 0.88)

        let sunSea0 = SIMD3<Float>(0.99, 0.76, 0.55)
        let sunSea1 = SIMD3<Float>(0.95, 0.54, 0.43)
        let sunSea2 = SIMD3<Float>(0.79, 0.37, 0.42)
        let sunSea3 = SIMD3<Float>(0.54, 0.27, 0.44)
        let sunSea4 = SIMD3<Float>(0.31, 0.20, 0.41)
        let sunSand0 = SIMD3<Float>(0.97, 0.79, 0.66)
        let sunSand1 = SIMD3<Float>(0.90, 0.68, 0.59)
        let sunSand2 = SIMD3<Float>(0.79, 0.56, 0.54)
        let sunSand3 = SIMD3<Float>(0.66, 0.46, 0.52)
        let sunWet   = SIMD3<Float>(0.88, 0.61, 0.47)
        let sunFoam  = SIMD3<Float>(1.00, 0.90, 0.80)
        let sunSpark = SIMD3<Float>(1.00, 0.78, 0.42)
        let sunBed0  = SIMD3<Float>(0.97, 0.75, 0.56)
        let sunBed1  = SIMD3<Float>(0.86, 0.58, 0.49)
        let sunTint0 = SIMD3<Float>(1.00, 0.89, 0.78)
        let sunTint1 = SIMD3<Float>(0.94, 0.64, 0.56)

        let ngtSea0 = SIMD3<Float>(0.18, 0.34, 0.52)
        let ngtSea1 = SIMD3<Float>(0.12, 0.26, 0.45)
        let ngtSea2 = SIMD3<Float>(0.08, 0.19, 0.37)
        let ngtSea3 = SIMD3<Float>(0.05, 0.13, 0.29)
        let ngtSea4 = SIMD3<Float>(0.03, 0.09, 0.22)
        let ngtSand0 = SIMD3<Float>(0.30, 0.35, 0.46)
        let ngtSand1 = SIMD3<Float>(0.26, 0.31, 0.42)
        let ngtSand2 = SIMD3<Float>(0.22, 0.26, 0.37)
        let ngtSand3 = SIMD3<Float>(0.18, 0.22, 0.33)
        let ngtWet   = SIMD3<Float>(0.21, 0.27, 0.39)
        let ngtFoam  = SIMD3<Float>(0.66, 0.82, 0.95)
        let ngtSpark = SIMD3<Float>(0.78, 0.90, 1.00)
        let ngtBed0  = SIMD3<Float>(0.26, 0.33, 0.46)
        let ngtBed1  = SIMD3<Float>(0.18, 0.26, 0.40)
        let ngtTint0 = SIMD3<Float>(0.65, 0.80, 0.95)
        let ngtTint1 = SIMD3<Float>(0.42, 0.62, 0.84)

        func blend3(_ d: SIMD3<Float>, _ s: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
            let afterWarm = simd_mix(d, s, SIMD3<Float>(repeating: warm))
            let duskShift = afterWarm * SIMD3<Float>(repeating: 1.0 - twilight * 0.12) + SIMD3<Float>(0.05, 0.02, 0.10) * twilight
            return simd_mix(duskShift, n, SIMD3<Float>(repeating: night))
        }

        let grassLight = blend3(SIMD3(0.76, 0.83, 0.52), SIMD3(0.86, 0.69, 0.42), SIMD3(0.17, 0.26, 0.28))
        let grassMid   = blend3(SIMD3(0.62, 0.75, 0.42), SIMD3(0.72, 0.54, 0.34), SIMD3(0.13, 0.21, 0.24))
        let grassDeep  = blend3(SIMD3(0.52, 0.68, 0.36), SIMD3(0.58, 0.42, 0.30), SIMD3(0.09, 0.16, 0.20))
        let grassInk   = blend3(SIMD3(0.24, 0.38, 0.18), SIMD3(0.32, 0.22, 0.16), SIMD3(0.05, 0.10, 0.14))
        let mShadow    = blend3(SIMD3(0.56, 0.66, 0.52), SIMD3(0.52, 0.42, 0.52), SIMD3(0.48, 0.54, 0.68))
        let cloudHi    = blend3(SIMD3(1.00, 1.00, 0.99), SIMD3(1.00, 0.84, 0.68), SIMD3(0.56, 0.68, 0.86))
        let cloudBody  = blend3(SIMD3(0.90, 0.93, 0.96), SIMD3(0.92, 0.72, 0.68), SIMD3(0.26, 0.33, 0.47))
        let cloudShade = blend3(SIMD3(0.80, 0.85, 0.90), SIMD3(0.74, 0.55, 0.62), SIMD3(0.19, 0.25, 0.38))

        let clrLight = blend3(SIMD3(0.77, 0.84, 0.54), SIMD3(0.87, 0.68, 0.44), SIMD3(0.16, 0.24, 0.27))
        let clrMid   = blend3(SIMD3(0.64, 0.76, 0.45), SIMD3(0.71, 0.52, 0.36), SIMD3(0.12, 0.19, 0.23))
        let can0     = blend3(SIMD3(0.20, 0.45, 0.30), SIMD3(0.42, 0.28, 0.24), SIMD3(0.07, 0.14, 0.19))
        let can1     = blend3(SIMD3(0.31, 0.58, 0.37), SIMD3(0.64, 0.38, 0.27), SIMD3(0.10, 0.19, 0.25))
        let can2     = blend3(SIMD3(0.48, 0.68, 0.35), SIMD3(0.84, 0.52, 0.31), SIMD3(0.14, 0.25, 0.31))
        let canRim   = blend3(SIMD3(0.72, 0.84, 0.50), SIMD3(0.99, 0.72, 0.42), SIMD3(0.36, 0.52, 0.68))
        let fShadow  = blend3(SIMD3(0.48, 0.58, 0.46), SIMD3(0.46, 0.36, 0.46), SIMD3(0.45, 0.50, 0.64))

        let palmTint = blend3(SIMD3(1.0, 1.0, 1.0), SIMD3(1.04, 0.80, 0.66), SIMD3(0.38, 0.48, 0.66))

        let angle = (h / 24.0) * (.pi * 2.0) - .pi * 0.5
        let lightDir = simd_normalize(SIMD2<Float>(-0.6 + 0.25 * cos(angle), -0.8))
        let shadowStretch: Float = 1.0 + warm * 0.38
        let shadowOff = SIMD2<Float>(115.0 * shadowStretch, 156.0 * shadowStretch)

        return SolarState(
            hour: h,
            sunsetWeight: warm,
            nightWeight: night,
            lightDir: lightDir,
            sea0: blend3(daySea0, sunSea0, ngtSea0),
            sea1: blend3(daySea1, sunSea1, ngtSea1),
            sea2: blend3(daySea2, sunSea2, ngtSea2),
            sea3: blend3(daySea3, sunSea3, ngtSea3),
            sea4: blend3(daySea4, sunSea4, ngtSea4),
            sand0: blend3(daySand0, sunSand0, ngtSand0),
            sand1: blend3(daySand1, sunSand1, ngtSand1),
            sand2: blend3(daySand2, sunSand2, ngtSand2),
            sand3: blend3(daySand3, sunSand3, ngtSand3),
            wetSand: blend3(dayWet, sunWet, ngtWet),
            foam: blend3(dayFoam, sunFoam, ngtFoam),
            sparkColor: blend3(daySpark, sunSpark, ngtSpark),
            bed0: blend3(dayBed0, sunBed0, ngtBed0),
            bed1: blend3(dayBed1, sunBed1, ngtBed1),
            shoalTint0: blend3(dayTint0, sunTint0, ngtTint0),
            shoalTint1: blend3(dayTint1, sunTint1, ngtTint1),
            palmTint: palmTint,
            grassLight: grassLight,
            grassMid: grassMid,
            grassDeep: grassDeep,
            grassInk: grassInk,
            meadowShadow: mShadow,
            cloudHighlight: cloudHi,
            cloudBody: cloudBody,
            cloudShade: cloudShade,
            shadowOffset: shadowOff,
            clearingLight: clrLight,
            clearingMid: clrMid,
            canopy0: can0,
            canopy1: can1,
            canopy2: can2,
            canopyRim: canRim,
            forestShadow: fShadow
        )
    }
}
