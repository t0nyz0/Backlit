import Foundation

/// Thai text for messages that Backlit builds at runtime (status, notices,
/// pause reasons and option titles). They stay English in the model so tests,
/// logs and external replies are unchanged; views translate them on display.
/// Unknown text is shown as is, so a missing entry falls back to English.
enum ThaiText {
    static func translate(_ text: String) -> String {
        if let exact = messages[text] { return exact }
        for pattern in patterns {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.expression.firstMatch(in: text, range: range) else { continue }
            let groups = (1..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return pattern.build(groups)
        }
        return text
    }

    private struct Pattern {
        let expression: NSRegularExpression
        let build: ([String]) -> String
        init(_ pattern: String, _ build: @escaping ([String]) -> String) {
            expression = try! NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators])
            self.build = build
        }
    }

    private static let touchSources = ["trackpad": "แทร็คแพด", "screen": "หน้าจอ", "both": "หน้าจอหรือแทร็คแพด"]
    private static let audioStages = [
        "request system audio": "ขอใช้เสียงระบบ",
        "read the audio format": "อ่านรูปแบบเสียง",
        "prepare system audio": "เตรียมเสียงระบบ",
        "connect system audio": "เชื่อมต่อเสียงระบบ",
        "start system audio": "เริ่มเสียงระบบ",
    ]

    private static let patterns: [Pattern] = [
        Pattern(#"Logo control unavailable: (.+)"#) { "ควบคุมโลโก้ไม่ได้: " + translate($0[0]) },
        Pattern(#"Ready for (\w+) touch"#) { "พร้อมรับการแตะ" + (touchSources[$0[0]] ?? $0[0]) },
        Pattern(#"Waiting for (\w+) touch"#) { "รอการแตะ" + (touchSources[$0[0]] ?? $0[0]) },
        Pattern(#"Quit (.+) to use Backlit"#) { "ปิดแอป \($0[0]) ก่อนใช้ Backlit" },
        Pattern(#"Quit (.+) before changing logo settings\."#) { "ปิดแอป \($0[0]) ก่อนเปลี่ยนการตั้งค่าโลโก้" },
        Pattern(#"Quit (.+) before giving Backlit the logo\."#) { "ปิดแอป \($0[0]) ก่อน เพื่อให้ Backlit ควบคุมโลโก้ได้" },
        Pattern(#"Quit (.+) before restoring a previous Backlit session\."#) { "ปิดแอป \($0[0]) ก่อนกู้คืนเซสชัน Backlit ครั้งก่อน" },
        Pattern(#"Manual logo brightness: (\d+)%"#) { "ความสว่างโลโก้: \($0[0])%" },
        Pattern(#"Saved brightness: (\d+)% · logo is off"#) { "บันทึกความสว่างไว้ที่ \($0[0])% · โลโก้ปิดอยู่" },
        Pattern(#"Preview · (\d+)% requested"#) { "ตัวอย่าง · ตั้งไว้ \($0[0])%" },
        Pattern(#"Logo state unavailable · (\d+)% requested"#) { "ไม่ทราบสถานะโลโก้ · ตั้งไว้ \($0[0])%" },
        Pattern(#"(\d+)% requested · hardware enabled"#) { "ตั้งไว้ \($0[0])% · ฮาร์ดแวร์เปิดอยู่" },
        Pattern(#"Local connections were switched off because the listener failed\. (.*)"#) {
            "ปิดการเชื่อมต่อภายในเครื่องแล้ว เพราะตัวรับการเชื่อมต่อทำงานผิดพลาด " + translate($0[0])
        },
        Pattern(#"AI access remains off because its key could not be replaced\. (.*)"#) {
            "การเข้าถึงของ AI ยังปิดอยู่ เพราะเปลี่ยนคีย์ไม่สำเร็จ " + translate($0[0])
        },
        Pattern(#"A new pairing key could not be created, so Home Assistant sharing was switched off\. Choose New Pairing Key again before switching it back on\. \((.*)\)"#) {
            "สร้างรหัสจับคู่ใหม่ไม่สำเร็จ จึงปิดการแชร์กับ Home Assistant แล้ว กด “สร้างรหัสจับคู่ใหม่” อีกครั้งก่อนเปิดการแชร์ (\(translate($0[0])))"
        },
        Pattern(#"Safety verification failed: (.*) Restore your light before retrying\."#) {
            "ตรวจสอบความปลอดภัยไม่ผ่าน: \(translate($0[0])) กู้คืนไฟก่อนลองใหม่"
        },
        Pattern(#"Backlit could not (.+)\. Allow Backlit in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Backlit and retry\. \(macOS code (.+)\)"#) { groups in
            let stage = audioStages[groups[0]].map { action in action + "ไม่ได้" } ?? "ทำงานไม่สำเร็จ (\(groups[0]))"
            return "Backlit \(stage) อนุญาต Backlit ที่ System Settings → Privacy & Security → Screen & System Audio Recording แล้วเปิด Backlit ใหม่และลองอีกครั้ง (รหัส macOS \(groups[1]))"
        },
    ]

    static let messages: [String: String] = [
        // Behaviors and option titles
        "Steady": "สว่างคงที่",
        "Breathe": "จังหวะหายใจ",
        "Battery": "แบตเตอรี่",
        "Music": "เพลง",
        "Agents": "เอเจนต์",
        "Trackpad": "แทร็คแพด",
        "Typing": "การพิมพ์",
        "Smooth": "นุ่มนวล",
        "Balanced": "สมดุล",
        "Punchy": "หนักแน่น",
        "Automatic pulse": "สว่าง-หรี่อัตโนมัติ",
        "Match battery level": "ตามระดับแบตเตอรี่",
        "Glow": "สว่างค้าง",
        "Pulse": "สว่าง-หรี่",
        "Blink": "กะพริบ",
        "Off": "ปิด",
        "Status only": "ดูสถานะเท่านั้น",
        "Allow light changes": "อนุญาตให้ปรับไฟได้",
        "Toggle logo": "เปิด/ปิดโลโก้",
        "Decrease logo brightness": "ลดความสว่างโลโก้",
        "Increase logo brightness": "เพิ่มความสว่างโลโก้",
        "waiting": "รออยู่",
        "working": "กำลังทำงาน",
        "attention": "ต้องการให้คุณดู",
        "Waiting": "รออยู่",
        "Working": "กำลังทำงาน",
        "Attention": "ต้องการให้คุณดู",

        // Battery
        "Battery state unavailable": "อ่านสถานะแบตเตอรี่ไม่ได้",
        "On battery": "ใช้แบตเตอรี่",
        "Fully charged": "ชาร์จเต็มแล้ว",
        "Charging": "กำลังชาร์จ",
        "Plugged in · Not charging": "เสียบปลั๊กอยู่ · ไม่ได้ชาร์จ",
        "Charge-ready signal": "แจ้งเมื่อชาร์จถึงเป้า",
        "Pulsing while charging": "สว่าง-หรี่ระหว่างชาร์จ",
        "Steady while plugged in": "สว่างคงที่ขณะเสียบปลั๊ก",

        // Light status
        "Restore your light to finish the previous lid session": "กู้คืนไฟเพื่อปิดงานขณะพับจอครั้งก่อนให้เรียบร้อย",
        "Waiting for closed-lid cleanup": "รอเคลียร์งานขณะพับจอ",
        "Waiting to reconnect after wake": "รอเชื่อมต่อใหม่หลังเครื่องตื่น",
        "Reconnecting to your MacBook": "กำลังเชื่อมต่อ MacBook อีกครั้ง",
        "Closed-lid lighting paused after an error": "ไฟขณะพับจอหยุดชั่วคราวเพราะเกิดข้อผิดพลาด",
        "Restore your light to continue": "กู้คืนไฟเพื่อใช้งานต่อ",
        "Connecting to your MacBook": "กำลังเชื่อมต่อ MacBook",
        "Waiting for light output": "รอให้ไฟเริ่มทำงาน",
        "Light output paused": "ไฟหยุดชั่วคราว",
        "Moving with your music": "กำลังเต้นตามเพลง",
        "Ready for your music": "พร้อมเต้นตามเพลง",
        "Watching your agents": "กำลังติดตามเอเจนต์",
        "Input active · light on": "กำลังสัมผัส · ไฟติด",
        "Ready for trackpad or typing": "พร้อมรับการแตะแทร็คแพดหรือการพิมพ์",
        "Typing active · light on": "กำลังพิมพ์ · ไฟติด",
        "Mac is sleeping": "Mac กำลังพักเครื่อง",
        "User session inactive": "บัญชีผู้ใช้นี้ไม่ได้ใช้งานอยู่",
        "Paused while your Mac cools down": "หยุดชั่วคราวเพื่อรอให้ Mac เย็นลง",
        "Paused with your display": "หยุดชั่วคราวขณะหน้าจอดับ",
        "Paused in Low Power Mode": "หยุดชั่วคราวในโหมดพลังงานต่ำ",
        "Preview only": "แสดงตัวอย่างเท่านั้น",
        "Off · lid closed": "ปิด · พับจออยู่",
        "Logo off · lid closed": "โลโก้ปิด · พับจออยู่",
        "Logo off · hardware disabled": "โลโก้ปิด · ฮาร์ดแวร์ปิดอยู่",
        "State unavailable": "ไม่ทราบสถานะ",
        "Logo state unavailable · not controlling hardware": "ไม่ทราบสถานะโลโก้ · ไม่ได้ควบคุมฮาร์ดแวร์",

        // Logo hardware
        "No compatible illuminated logo was detected.": "ไม่พบโลโก้เรืองแสงที่รองรับ",
        "The logo control service is unavailable on this version of macOS.": "macOS เวอร์ชันนี้ไม่มีบริการควบคุมโลโก้",
        "The logo control service has an unsupported interface on this version of macOS.": "บริการควบคุมโลโก้ใน macOS เวอร์ชันนี้ใช้รูปแบบที่ Backlit ไม่รองรับ",
        "Compatible logo hardware detected.": "พบฮาร์ดแวร์โลโก้ที่รองรับ",
        "A previous session needs restoration. Choose Restore Logo Settings first.": "ต้องกู้คืนเซสชันก่อนหน้าก่อน",
        "Could not read the original logo configuration.": "อ่านการตั้งค่าโลโก้เดิมไม่ได้",
        "Another controller changed the logo. Backlit stopped writing; recovery is retained.": "มีโปรแกรมอื่นเปลี่ยนโลโก้ Backlit จึงหยุดควบคุมและเก็บข้อมูลกู้คืนไว้",
        "Backlit is already running in another window. Use the installed copy.": "Backlit เปิดอยู่แล้วในอีกหน้าต่างหนึ่ง ให้ใช้ตัวที่ติดตั้งไว้",
        "Compatible logo hardware is unavailable.": "ไม่พบฮาร์ดแวร์โลโก้ที่รองรับ",
        "A compatible live Mac is required.": "ต้องใช้กับ Mac จริงที่รองรับ",
        "Logo control is recovering after a system transition.": "กำลังกู้คืนการควบคุมโลโก้หลังระบบเปลี่ยนสถานะ",
        "Logo control is switching between open-lid and closed-lid lighting.": "กำลังสลับการควบคุมโลโก้ระหว่างกางจอกับพับจอ",

        // Closed lid
        "Remembered. Waiting for your Mac and light to be ready.": "จำการตั้งค่าไว้แล้ว รอให้ Mac และไฟพร้อมก่อน",
        "Paused after an error. Restore your light before retrying.": "หยุดชั่วคราวเพราะเกิดข้อผิดพลาด กู้คืนไฟก่อนลองใหม่",
        "Previous session verified. Reconnecting your remembered choice.": "ตรวจสอบเซสชันก่อนหน้าแล้ว กำลังกลับไปใช้การตั้งค่าที่จำไว้",
        "Remembered. Preview never starts a closed-lid session.": "จำการตั้งค่าไว้แล้ว แต่โหมดตัวอย่างจะไม่เปิดไฟขณะพับจอจริง",
        "Paused after an error. Turn “Keep logo on with lid closed” off and on after recovery.": "หยุดชั่วคราวเพราะเกิดข้อผิดพลาด หลังกู้คืนแล้วให้ปิดและเปิด “เปิดไฟโลโก้ค้างไว้ขณะพับจอ” อีกครั้ง",
        "Remembered. Paused for your Mac’s safety settings.": "จำการตั้งค่าไว้แล้ว หยุดชั่วคราวตามการตั้งค่าความปลอดภัยของ Mac",
        "Timer finished. Reopen the lid to begin another timed session.": "หมดเวลาแล้ว กางจอขึ้นก่อนเพื่อเริ่มจับเวลารอบใหม่",
        "Remembered. Open the lid before starting another timed session.": "จำการตั้งค่าไว้แล้ว กางจอขึ้นก่อนเริ่มจับเวลารอบใหม่",
        "Remembered. Waiting for a verified lid and timer state.": "จำการตั้งค่าไว้แล้ว รอยืนยันสถานะฝาจอและตัวจับเวลา",
        "Ready for the next lid closure.": "พร้อมทำงานเมื่อพับจอครั้งถัดไป",
        "Active. Safety limits still apply.": "กำลังทำงาน โดยยังมีขีดจำกัดด้านความปลอดภัยอยู่",
        "Waiting for closed-lid safety checks.": "รอตรวจความปลอดภัยก่อนเปิดไฟขณะพับจอ",
        "Starting closed-lid safety checks…": "กำลังเริ่มตรวจความปลอดภัยสำหรับการพับจอ…",
        "Cleaning up. Your choice is remembered.": "กำลังเคลียร์งาน และจำการตั้งค่าของคุณไว้แล้ว",
        "Recovery unconfirmed. Your closed-lid choice is saved and remains paused. Review recovery in Settings.": "ยังยืนยันการกู้คืนไม่ได้ การตั้งค่าขณะพับจอถูกบันทึกไว้และหยุดชั่วคราวอยู่ ตรวจสอบได้ในหน้าการตั้งค่า",
        "Closed-lid lighting paused after an error, so the logo is off. Restore your light in Settings, then turn “Keep logo on with lid closed” off and on to retry.": "ไฟขณะพับจอหยุดชั่วคราวเพราะเกิดข้อผิดพลาด โลโก้จึงดับอยู่ กู้คืนไฟในหน้าการตั้งค่า แล้วปิดและเปิด “เปิดไฟโลโก้ค้างไว้ขณะพับจอ” อีกครั้งเพื่อลองใหม่",
        "Automatic safety checks stopped after three attempts. Restore your light in Settings, then turn “Keep logo on with lid closed” off and on to retry.": "หยุดตรวจความปลอดภัยอัตโนมัติหลังลองครบ 3 ครั้ง กู้คืนไฟในหน้าการตั้งค่า แล้วปิดและเปิด “เปิดไฟโลโก้ค้างไว้ขณะพับจอ” อีกครั้งเพื่อลองใหม่",
        "Remembered. Waiting to verify the previous session before reconnecting.": "จำการตั้งค่าไว้แล้ว รอตรวจสอบเซสชันก่อนหน้าก่อนเชื่อมต่อใหม่",
        "Saved recovery timing could not be verified. Restore your light, then turn closed-lid lighting off and on to retry.": "ตรวจสอบเวลากู้คืนที่บันทึกไว้ไม่ได้ กู้คืนไฟ แล้วปิดและเปิดไฟขณะพับจออีกครั้งเพื่อลองใหม่",
        "The saved closed-lid safety state could not be recorded.": "บันทึกสถานะความปลอดภัยขณะพับจอไม่ได้",
        "The saved closed-lid choice is invalid.": "การตั้งค่าขณะพับจอที่บันทึกไว้ไม่ถูกต้อง",
        "The saved closed-lid failure is not eligible for automatic cleanup.": "ข้อผิดพลาดขณะพับจอที่บันทึกไว้เคลียร์อัตโนมัติไม่ได้",
        "A previous session still has a recovery record. Restore Light can request restoration; it does not confirm native handback.": "เซสชันก่อนหน้ายังมีข้อมูลกู้คืนค้างอยู่ ปุ่ม “กู้คืนไฟ” ส่งคำขอกู้คืนได้ แต่ยืนยันไม่ได้ว่าระบบรับการควบคุมกลับไปแล้ว",
        "Remembered. Waiting for fresh awake, unlocked hardware safety checks.": "จำการตั้งค่าไว้แล้ว รอตรวจความปลอดภัยของฮาร์ดแวร์รอบใหม่ขณะเครื่องตื่นและปลดล็อกอยู่",
        "Safety state changed during verification. Backlit will check again before reconnecting.": "สถานะความปลอดภัยเปลี่ยนระหว่างตรวจสอบ Backlit จะตรวจอีกครั้งก่อนเชื่อมต่อใหม่",
        "Recovery ownership changed during verification. Restore your light before retrying.": "สิทธิ์ควบคุมการกู้คืนเปลี่ยนระหว่างตรวจสอบ กู้คืนไฟก่อนลองใหม่",
        "Previous effects are still cleaning up. Waiting before another safety check.": "เอฟเฟกต์ก่อนหน้ายังเคลียร์ไม่เสร็จ รอสักครู่ก่อนตรวจความปลอดภัยอีกครั้ง",
        "Keyboard safety controls are unavailable. Closed-lid lighting was not enabled.": "ใช้ระบบป้องกันของคีย์บอร์ดไม่ได้ จึงไม่ได้เปิดไฟขณะพับจอ",
        "Could not preserve display and keyboard behavior. Closed-lid lighting was stopped.": "รักษาการทำงานของหน้าจอและคีย์บอร์ดไว้ไม่ได้ จึงหยุดไฟขณะพับจอแล้ว",
        "Could not restore the real lid state. Recovery has been retained.": "คืนสถานะฝาจอจริงไม่ได้ เก็บข้อมูลกู้คืนไว้แล้ว",
        "Could not safely apply closed-lid lighting. Restore Light before retrying.": "เปิดไฟขณะพับจออย่างปลอดภัยไม่ได้ กู้คืนไฟก่อนลองใหม่",
        "Could not restore normal lid sleep.": "คืนการพักเครื่องเมื่อพับจอตามปกติไม่ได้",

        // Touch and typing
        "Waiting for touch": "รอการสัมผัส",
        "Touch detected · hold to keep lit": "ตรวจพบการสัมผัส · วางนิ้วค้างไว้เพื่อให้ไฟติด",
        "Touch released · light off": "ยกนิ้วแล้ว · ไฟดับ",
        "Ready for trackpad contact": "พร้อมรับการสัมผัสแทร็คแพด",
        "Trackpad events are unavailable on this macOS build": "macOS รุ่นนี้อ่านการสัมผัสแทร็คแพดไม่ได้",
        "Typing response is off": "ปิดการตอบสนองการพิมพ์อยู่",
        "Typing access is allowed": "ได้รับสิทธิ์ตรวจจับการพิมพ์แล้ว",
        "Input Monitoring permission is required for typing response": "ต้องอนุญาต Input Monitoring ก่อน จึงจะตอบสนองการพิมพ์ได้",
        "Input Monitoring is allowed, but macOS could not create the typing event listener. Reopen Backlit and retry.": "อนุญาต Input Monitoring แล้ว แต่ macOS สร้างตัวตรวจจับการพิมพ์ไม่ได้ ปิดแล้วเปิด Backlit ใหม่ แล้วลองอีกครั้ง",
        "Could not start typing response": "เริ่มการตอบสนองการพิมพ์ไม่ได้",
        "Ready for typing": "พร้อมตอบสนองการพิมพ์",
        "Typing access is no longer available": "ไม่มีสิทธิ์ตรวจจับการพิมพ์แล้ว",
        "Typing was paused by macOS; turn typing response off and on to resume": "macOS หยุดการตรวจจับการพิมพ์ชั่วคราว ปิดแล้วเปิดการตอบสนองการพิมพ์อีกครั้งเพื่อใช้งานต่อ",
        "Typing input is disabled in preview.": "โหมดตัวอย่างไม่อ่านการพิมพ์",

        // Shortcuts and brightness keys
        "Hardware brightness keys use macOS.": "ปุ่มปรับความสว่างบนคีย์บอร์ดยังทำงานตามปกติของ macOS",
        "Experimental filter active. Test Shift + brightness on your keyboard; screen suppression is not yet verified.": "เปิดตัวกรองทดลองแล้ว ลองกด Shift + ปุ่มความสว่างบนคีย์บอร์ด (ยังไม่ได้ยืนยันว่าความสว่างหน้าจอจะไม่เปลี่ยนตาม)",
        "Allow Backlit in Accessibility, then enable this option again. Regular shortcuts need no new permission.": "อนุญาต Backlit ใน Accessibility แล้วเปิดตัวเลือกนี้อีกครั้ง ส่วนคีย์ลัดปกติไม่ต้องขอสิทธิ์เพิ่ม",
        "Allow Backlit in Input Monitoring, then enable this option again. The hardware-key filter stays off until listening access is allowed.": "อนุญาต Backlit ใน Input Monitoring แล้วเปิดตัวเลือกนี้อีกครั้ง ตัวกรองปุ่มความสว่างจะปิดอยู่จนกว่าจะได้รับสิทธิ์",
        "The brightness-key filter could not start. Regular shortcuts remain available.": "เริ่มตัวกรองปุ่มความสว่างไม่ได้ แต่คีย์ลัดปกติยังใช้ได้",
        "Hardware-key capture is disabled in isolated preview.": "โหมดตัวอย่างไม่ดักจับปุ่มบนคีย์บอร์ด",
        "That combination is assigned to another Backlit action.": "ปุ่มชุดนี้ใช้กับคำสั่งอื่นของ Backlit อยู่แล้ว",
        "Use Command, Control or Option with a regular key. Shift alone and hardware brightness keys are not supported.": "ใช้ Command, Control หรือ Option คู่กับปุ่มทั่วไป ไม่รองรับ Shift อย่างเดียวหรือปุ่มความสว่างบนคีย์บอร์ด",
        "Hardware brightness keys are left to macOS. Use an arrow, letter or other regular key.": "ปุ่มความสว่างบนคีย์บอร์ดสงวนไว้ให้ macOS ให้ใช้ลูกศร ตัวอักษร หรือปุ่มทั่วไปอื่นแทน",
        "Global shortcuts are unavailable.": "ใช้คีย์ลัดทั้งระบบไม่ได้",
        "Battery controls its own brightness. Select a manual behavior to use brightness shortcuts.": "โหมดแบตเตอรี่ปรับความสว่างเอง เลือกรูปแบบไฟอื่นก่อนจึงจะใช้คีย์ลัดปรับความสว่างได้",
        "Finish light recovery before using brightness shortcuts.": "กู้คืนไฟให้เสร็จก่อนใช้คีย์ลัดปรับความสว่าง",

        // Notices
        "Your light is ready.": "ไฟพร้อมใช้งานแล้ว",
        "Normal lid sleep was restored. A leftover session file could not be removed.": "กลับมาพักเครื่องเมื่อพับจอตามปกติแล้ว แต่ลบไฟล์เซสชันที่ค้างอยู่ไม่ได้",
        "Closed-lid cleanup could not be confirmed. Review power recovery in Settings, then retry.": "ยืนยันการเคลียร์งานหลังพับจอไม่ได้ ตรวจสอบการกู้คืนในหน้าการตั้งค่า แล้วลองใหม่",
        "A previous light session needs restoration. Use Restore Light to finish its cleanup.": "ต้องกู้คืนเซสชันไฟครั้งก่อน กด “กู้คืนไฟ” เพื่อเคลียร์ให้เสร็จ",
        "Enable Backlit links and other apps in Connections first.": "เปิด “อนุญาตลิงก์ Backlit และแอปอื่น” ในหน้าการเชื่อมต่อก่อน",
        "Light recovery is still in progress.": "ยังกู้คืนไฟไม่เสร็จ",
        "This is an isolated preview. Your real logo is unchanged.": "นี่คือโหมดตัวอย่าง โลโก้จริงของคุณไม่เปลี่ยนแปลง",
        "Restore your light before starting another session.": "กู้คืนไฟก่อนเริ่มเซสชันใหม่",
        "The closed-lid recovery choice could not be saved. Restore your light before retrying.": "บันทึกตัวเลือกการกู้คืนขณะพับจอไม่ได้ กู้คืนไฟก่อนลองใหม่",
        "Backlit will reconnect when your Mac is awake and unlocked.": "Backlit จะเชื่อมต่อใหม่เมื่อ Mac ตื่นและปลดล็อกแล้ว",
        "Closed-lid cleanup is in progress. Retry Restore Light when it finishes.": "กำลังเคลียร์งานขณะพับจอ เมื่อเสร็จแล้วให้กด “กู้คืนไฟ” อีกครั้ง",
        "Light or lid recovery remains unconfirmed. Recovery was retained.": "ยังยืนยันการกู้คืนไฟหรือฝาจอไม่ได้ เก็บข้อมูลกู้คืนไว้แล้ว",
        "Restoration was requested. Native handback remains unconfirmed, so the saved closed-lid choice stays paused.": "ส่งคำขอกู้คืนแล้ว แต่ยังยืนยันไม่ได้ว่าระบบรับการควบคุมกลับไป การตั้งค่าขณะพับจอจึงยังหยุดชั่วคราวอยู่",
        "Your light was restored. Turn closed-lid lighting off and on to retry.": "กู้คืนไฟแล้ว ปิดและเปิดไฟขณะพับจออีกครั้งเพื่อลองใหม่",
        "The saved logo and lid settings were restored.": "กู้คืนการตั้งค่าโลโก้และฝาจอที่บันทึกไว้แล้ว",
        "Preview uses a sample waveform. Live system audio is never started in preview.": "โหมดตัวอย่างใช้คลื่นเสียงจำลอง และจะไม่จับเสียงจริงจากระบบ",
        "Closed-lid operation is unavailable in isolated preview.": "โหมดตัวอย่างใช้การทำงานขณะพับจอไม่ได้",
        "Finish the previous closed-lid session cleanup before starting another.": "เคลียร์งานขณะพับจอครั้งก่อนให้เสร็จก่อนเริ่มใหม่",
        "The saved safety check could not be recorded. Restore your light before retrying.": "บันทึกผลตรวจความปลอดภัยไม่ได้ กู้คืนไฟก่อนลองใหม่",
        "The closed-lid helper could not be adopted.": "รับช่วงตัวช่วยการทำงานขณะพับจอไม่ได้",
        "Turn off closed-lid lighting and finish its cleanup before changing ambient limits.": "ปิดไฟขณะพับจอและรอเคลียร์ให้เสร็จก่อนเปลี่ยนขีดจำกัดความสว่าง",
        "Restore your light before changing ambient limits.": "กู้คืนไฟก่อนเปลี่ยนขีดจำกัดความสว่าง",
        "Ambient brightness limits were not changed.": "ขีดจำกัดความสว่างตามแสงรอบตัวยังไม่ได้เปลี่ยน",
        "The ambient brightness change could not be confirmed. Restore the saved limits before retrying.": "ยืนยันการเปลี่ยนขีดจำกัดความสว่างไม่ได้ คืนค่าขีดจำกัดที่บันทึกไว้ก่อนลองใหม่",
        "Authorization was cancelled.": "ยกเลิกการยืนยันสิทธิ์ผู้ดูแลระบบแล้ว",
        "The brightness-limit request could not be prepared.": "เตรียมคำขอเปลี่ยนขีดจำกัดความสว่างไม่ได้",
        "Light recovery is still in progress. Retry Quit when it finishes.": "ยังกู้คืนไฟไม่เสร็จ รอให้เสร็จแล้วค่อยออกจากแอปอีกครั้ง",
        "Restore your light before quitting; the previous lid session still needs recovery.": "กู้คืนไฟก่อนออกจากแอป เพราะงานขณะพับจอครั้งก่อนยังต้องกู้คืน",

        // Connections
        "Not connected": "ยังไม่เชื่อมต่อ",
        "Available on your local network": "ใช้งานได้ในเครือข่ายภายใน",
        "Available on this Mac": "ใช้งานได้บน Mac เครื่องนี้",
        "The previous local connection is still closing. Turn sharing off and on to retry.": "การเชื่อมต่อเดิมยังปิดไม่เสร็จ ปิดแล้วเปิดการแชร์อีกครั้งเพื่อลองใหม่",
        "Connections are disabled in isolated preview.": "โหมดตัวอย่างปิดการเชื่อมต่อไว้",
        "Hooks installed. Review and trust them in Codex Settings → Hooks, then start a new session.": "ติดตั้ง hooks แล้ว ตรวจสอบและกดเชื่อถือใน Codex Settings → Hooks แล้วเริ่มเซสชันใหม่",
        "Hooks installed. Start a new Claude Code session to see status.": "ติดตั้ง hooks แล้ว เริ่มเซสชัน Claude Code ใหม่เพื่อดูสถานะ",
        "Backlit's hooks were removed. Existing hooks were preserved.": "ลบ hooks ของ Backlit แล้ว ส่วน hooks อื่นที่มีอยู่ยังอยู่ครบ",
        "Network sharing is disabled in isolated preview.": "โหมดตัวอย่างปิดการแชร์ผ่านเครือข่ายไว้",
        "The AI connection was switched off because its Keychain key is unavailable. Enable it again in Connections.": "ปิดการเชื่อมต่อ AI แล้ว เพราะไม่พบคีย์ใน Keychain เปิดใหม่ได้ในหน้าการเชื่อมต่อ",
        "AI connections are disabled in isolated preview.": "โหมดตัวอย่างปิดการเชื่อมต่อ AI ไว้",
        "The AI connection key was replaced. Turn AI access off to stop all assistant connections.": "เปลี่ยนคีย์การเชื่อมต่อ AI แล้ว ถ้าต้องการตัดการเชื่อมต่อผู้ช่วยทั้งหมด ให้ปิดการเข้าถึงของ AI",
        "Setup command copied. Run it locally in your agent's terminal, then check its MCP connections.": "คัดลอกคำสั่งตั้งค่าแล้ว นำไปรันในเทอร์มินัลของเอเจนต์บนเครื่องนี้ แล้วตรวจดูการเชื่อมต่อ MCP",
        "Backlit link copied. Use it with a launcher that supports custom app links.": "คัดลอกลิงก์ Backlit แล้ว ใช้กับแอปเรียกคำสั่งที่รองรับลิงก์แบบกำหนดเอง",
        "Pairing key copied. Paste it into Home Assistant; keep it private.": "คัดลอกรหัสจับคู่แล้ว นำไปวางใน Home Assistant และเก็บรหัสนี้เป็นความลับ",
        "A new pairing key was created. Copy it and update Home Assistant; the old key no longer works.": "สร้างรหัสจับคู่ใหม่แล้ว คัดลอกไปอัปเดตใน Home Assistant รหัสเดิมใช้ไม่ได้อีกต่อไป",
        "Agent settings must be a JSON object. Nothing changed.": "ไฟล์ตั้งค่าเอเจนต์ต้องเป็นอ็อบเจกต์ JSON จึงยังไม่ได้เปลี่ยนอะไร",
        "Unrecognized hooks format. Nothing changed.": "ไม่รู้จักรูปแบบ hooks จึงยังไม่ได้เปลี่ยนอะไร",
        "Unrecognized event format. Nothing changed.": "ไม่รู้จักรูปแบบเหตุการณ์ จึงยังไม่ได้เปลี่ยนอะไร",
        "Unrecognized hook group. Nothing changed.": "ไม่รู้จักกลุ่ม hook จึงยังไม่ได้เปลี่ยนอะไร",
        "Agent settings is a symbolic link or special file. Choose its actual folder first.": "ไฟล์ตั้งค่าเอเจนต์เป็นลิงก์หรือไฟล์พิเศษ เลือกโฟลเดอร์จริงของไฟล์ก่อน",
        "Agent settings changed during connection. Try again.": "ไฟล์ตั้งค่าเอเจนต์เปลี่ยนระหว่างเชื่อมต่อ ลองอีกครั้ง",

        // System audio
        "System audio is unavailable.": "ใช้เสียงระบบไม่ได้",
        "No display is available for system audio capture.": "ไม่มีจอแสดงผลสำหรับการจับเสียงระบบ",
        "System audio stopped before it was ready.": "เสียงระบบหยุดก่อนพร้อมใช้งาน",
        "System audio access is off for Backlit. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Backlit or choose Retry System Audio. Backlit does not record your screen or microphone.": "Backlit ยังไม่ได้รับสิทธิ์ใช้เสียงระบบ อนุญาตได้ที่ System Settings → Privacy & Security → Screen & System Audio Recording แล้วเปิด Backlit ใหม่ หรือกด “ลองเชื่อมเสียงระบบอีกครั้ง” (Backlit ไม่บันทึกหน้าจอหรือไมโครโฟน)",
        "This output device uses an unsupported system-audio format.": "อุปกรณ์เสียงที่ใช้อยู่มีรูปแบบเสียงที่ไม่รองรับ",
        "macOS took too long to connect system audio.": "macOS ใช้เวลาเชื่อมต่อเสียงระบบนานเกินไป",

        // Updates
        "Updates are unavailable in preview.": "โหมดตัวอย่างอัปเดตไม่ได้",
        "In-app updates aren’t enabled for this build yet. A trusted update feed and signing key must be included by the publisher.": "บิลด์นี้ยังไม่เปิดการอัปเดตในแอป ผู้เผยแพร่ต้องใส่แหล่งอัปเดตที่เชื่อถือได้และคีย์ลงนามก่อน",
        "This update is incompatible with this build or Mac.": "อัปเดตนี้ใช้กับบิลด์นี้หรือ Mac เครื่องนี้ไม่ได้",
        "An update is waiting. Choose Install Update and Relaunch, or skip it in the update window before quitting.": "มีอัปเดตรออยู่ เลือก “ติดตั้งอัปเดตและเปิดใหม่” หรือกดข้ามในหน้าต่างอัปเดตก่อนออกจากแอป",
        "Start update checks from Settings.": "เริ่มตรวจหาอัปเดตได้จากหน้าการตั้งค่า",
        "Update paused. Finish restoring the light, then retry installation.": "หยุดอัปเดตชั่วคราว กู้คืนไฟให้เสร็จ แล้วลองติดตั้งอีกครั้ง",
        "Check for Updates": "ตรวจหาอัปเดต",
        "Download Latest Version": "ดาวน์โหลดเวอร์ชันล่าสุด",
        "Downloads are disabled in preview.": "โหมดตัวอย่างดาวน์โหลดไม่ได้",
        "Download the app, then quit Backlit and replace it in Applications.": "ดาวน์โหลดแอป ออกจาก Backlit แล้วนำตัวใหม่ไปแทนที่ในโฟลเดอร์ Applications",
        "Install Update and Relaunch": "ติดตั้งอัปเดตและเปิดใหม่",
        "Show Update Progress": "ดูความคืบหน้าการอัปเดต",
    ]
}
