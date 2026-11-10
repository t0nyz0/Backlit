import Foundation

/// Reports hardware-disabled separately from the requested effect level.
/// A confirmed mapping/enable flag does not measure emitted light or nits.
struct LogoStatus: Equatable {
    let level: Double
    let detail: String

    init(requested: Double, hardwareEnabled: Bool?, controlling: Bool, lidClosed: Bool, preview: Bool) {
        if preview {
            level = Effects.clamp(requested)
            detail = "Preview · \(Effects.percent(level))% requested"
        } else if hardwareEnabled == false {
            level = 0
            detail = lidClosed ? "Logo off · lid closed" : "Logo off · hardware disabled"
        } else if !controlling {
            level = 0
            detail = "Logo state unavailable · not controlling hardware"
        } else if hardwareEnabled == nil {
            level = 0
            detail = "Logo state unavailable · \(Effects.percent(requested))% requested"
        } else {
            level = Effects.clamp(requested)
            detail = "\(Effects.percent(level))% requested · hardware enabled"
        }
    }
}
