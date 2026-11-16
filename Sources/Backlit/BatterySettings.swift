import Foundation
import SwiftUI

enum BatteryChargeStyle: String, Codable, CaseIterable, Identifiable {
    case breathe, steady, level
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breathe: return "Automatic pulse"
        case .steady: return "Steady"
        case .level: return "Match battery level"
        }
    }
}

enum BatteryReadyStyle: String, Codable, CaseIterable, Identifiable {
    case glow, pulse, blink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BatteryResponseOptions: Codable, Equatable {
    var chargingStyle: BatteryChargeStyle = .breathe
    var pulsePeriod = 6.0
    var pulseMinimum = 0.0
    var readyEnabled = false
    var readyThreshold = 1.0
    var readyStyle: BatteryReadyStyle = .pulse
    var readyDuration = 10.0
    enum CodingKeys: String, CodingKey { case chargingStyle, pulsePeriod, pulseMinimum, readyEnabled, readyThreshold, readyStyle, readyDuration }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chargingStyle = (try? values.decode(BatteryChargeStyle.self, forKey: .chargingStyle)) ?? .breathe
        pulsePeriod = Self.bound((try? values.decode(Double.self, forKey: .pulsePeriod)) ?? 6, 3...10, fallback: 6)
        pulseMinimum = Self.bound((try? values.decode(Double.self, forKey: .pulseMinimum)) ?? 0, 0...1, fallback: 0)
        readyEnabled = (try? values.decode(Bool.self, forKey: .readyEnabled)) ?? false
        readyThreshold = Self.bound((try? values.decode(Double.self, forKey: .readyThreshold)) ?? 1, 0.5...1, fallback: 1)
        readyStyle = (try? values.decode(BatteryReadyStyle.self, forKey: .readyStyle)) ?? .pulse
        readyDuration = Self.bound((try? values.decode(Double.self, forKey: .readyDuration)) ?? 10, 1...60, fallback: 10)
    }
    static func bound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

struct BatterySettingsControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(model.t("While plugged in", th:"ขณะเสียบปลั๊ก"), selection: $model.batteryOptions.chargingStyle) {
                ForEach(BatteryChargeStyle.allCases) { style in Text(model.display(style.title)).tag(style) }
            }.accessibilityLabel(model.t("Battery charging behavior", th:"รูปแบบไฟขณะชาร์จ"))
            if model.batteryOptions.chargingStyle == .breathe {
                HStack { Text(model.t("Pulse cycle", th:"รอบสว่าง-หรี่")); Spacer(); Text(model.t(String(format: "%.1f seconds", model.batteryOptions.pulsePeriod), th: String(format: "%.1f วินาที", model.batteryOptions.pulsePeriod))).monospacedDigit() }
                Slider(value: $model.batteryOptions.pulsePeriod, in: 3...10, step: 0.5).accessibilityLabel(model.t("Battery pulse cycle seconds", th:"จำนวนวินาทีต่อรอบสว่าง-หรี่"))
                HStack { Text(model.t("Dim to", th:"หรี่ต่ำสุดที่")); Spacer(); Text("\(Effects.percent(model.batteryOptions.pulseMinimum))%").monospacedDigit() }
                Slider(value: $model.batteryOptions.pulseMinimum, in: 0...1).accessibilityLabel(model.t("Charging pulse minimum brightness", th:"ความสว่างต่ำสุดขณะชาร์จ"))
                Text(model.t("0% goes fully dark between pulses.", th:"ตั้ง 0% ไฟจะดับสนิทระหว่างแต่ละรอบ")).foregroundStyle(.secondary)
                Text(model.t("Pulses only while actively charging, then stays solid when charging pauses or finishes.", th:"สว่าง-หรี่เฉพาะตอนกำลังชาร์จ และสว่างคงที่เมื่อหยุดชาร์จหรือชาร์จเต็ม")).foregroundStyle(.secondary)
            } else if model.batteryOptions.chargingStyle == .steady {
                Text(model.t("No charging pulse. Holds 100% logo output while plugged in.", th:"ไม่สว่าง-หรี่ขณะชาร์จ โลโก้จะสว่าง 100% ตลอดที่เสียบปลั๊ก")).foregroundStyle(.secondary)
            } else {
                Text(model.t("Follows the battery percentage while plugged in too.", th:"สว่างตามเปอร์เซ็นต์แบตเตอรี่ แม้เสียบปลั๊กอยู่")).foregroundStyle(.secondary)
            }
            Text(model.t("Unplugged, logo brightness matches battery charge down to 0%. Manual brightness does not affect Battery mode.", th:"เมื่อถอดปลั๊ก ความสว่างโลโก้จะเท่ากับระดับแบตเตอรี่ไปจนถึง 0% และการปรับความสว่างเองไม่มีผลในโหมดแบตเตอรี่")).foregroundStyle(.secondary)
            Divider()
            Toggle(model.t("Charge-ready signal", th:"แจ้งเมื่อชาร์จถึงเป้า"), isOn: $model.batteryOptions.readyEnabled).toggleStyle(.switch).controlSize(.small)
            if model.batteryOptions.readyEnabled {
                HStack {
                    Text(model.t("Ready at", th:"แจ้งเมื่อถึง"))
                    Slider(value: $model.batteryOptions.readyThreshold, in: 0.5...1, step: 0.01).accessibilityLabel(model.t("Charge-ready threshold", th:"ระดับแบตเตอรี่ที่จะแจ้ง"))
                    Text("\(Int((model.batteryOptions.readyThreshold * 100).rounded()))%").monospacedDigit()
                }
                Picker(model.t("Signal", th:"สัญญาณ"), selection: $model.batteryOptions.readyStyle) {
                    ForEach(BatteryReadyStyle.allCases) { style in Text(model.display(style.title)).tag(style) }
                }
                Stepper(model.t("For \(Int(model.batteryOptions.readyDuration)) seconds", th:"นาน \(Int(model.batteryOptions.readyDuration)) วินาที"), value: $model.batteryOptions.readyDuration, in: 1...60)
                Text(model.t("Optional: briefly overrides normal Battery behavior when charge reaches your threshold while plugged in. Does not repeat until charge drops or you unplug.", th:"ไม่บังคับ: เมื่อชาร์จถึงระดับที่ตั้งไว้ขณะเสียบปลั๊ก ไฟจะแสดงสัญญาณนี้สั้นๆ แทนรูปแบบปกติ และจะไม่แจ้งซ้ำจนกว่าแบตเตอรี่จะลดลงหรือถอดปลั๊ก")).foregroundStyle(.secondary)
            }
            Button(model.t("Restore Battery Defaults", th:"คืนค่าเริ่มต้นของโหมดแบตเตอรี่")) { model.batteryOptions = BatteryResponseOptions() }
                .disabled(model.batteryOptions == BatteryResponseOptions())
            Text(model.t("Default: automatic charging pulse, 6-second cycle, dims to 0%, charge-ready signal off.", th:"ค่าเริ่มต้น: สว่าง-หรี่อัตโนมัติขณะชาร์จ รอบละ 6 วินาที หรี่ต่ำสุด 0% และปิดการแจ้งเมื่อชาร์จถึงเป้า")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 12))
    }
}
