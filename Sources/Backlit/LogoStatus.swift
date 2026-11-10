import Foundation

/// Reports hardware-disabled separately from the requested effect level.
/// A confirmed mapping/enable flag does not measure emitted light or nits.
struct LogoStatus: Equatable {
    let level: Double
    let detail: String
    let statusLabel: String?

    init(requested: Double, hardwareEnabled: Bool?, controlling: Bool, lidClosed: Bool, preview: Bool) {
        if preview {
            statusLabel = "Preview only"
            level = Effects.clamp(requested)
            detail = "Preview · \(Effects.percent(level))% requested"
        } else if hardwareEnabled == false {
            statusLabel = lidClosed ? "Off · lid closed" : "Off"
            level = 0
            detail = lidClosed ? "Logo off · lid closed" : "Logo off · hardware disabled"
        } else if !controlling {
            statusLabel = "State unavailable"
            level = 0
            detail = "Logo state unavailable · not controlling hardware"
        } else if hardwareEnabled == nil {
            statusLabel = "State unavailable"
            level = 0
            detail = "Logo state unavailable · \(Effects.percent(requested))% requested"
        } else {
            statusLabel = nil
            level = Effects.clamp(requested)
            detail = "\(Effects.percent(level))% requested · hardware enabled"
        }
    }
}
