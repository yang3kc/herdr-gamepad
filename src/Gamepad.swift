import Foundation
import IOKit.hid

/// W3C "standard gamepad" layout — the same numbering a browser reports.
///
/// Anchoring on this is the whole trick: every controller speaks its own
/// dialect of HID usages, but almost every user has already seen these
/// numbers in a browser gamepad tester. Map once into this layout and both
/// the config file and the docs get to speak one language.
enum Standard {
    static let buttonNames = [
        "a", "b", "x", "y",              //  0–3
        "lb", "rb",                      //  4–5
        "lt", "rt",                      //  6–7   analog triggers, exposed as buttons
        "back", "start",                 //  8–9
        "l3", "r3",                      // 10–11  stick clicks
        "dpad_up", "dpad_down", "dpad_left", "dpad_right",  // 12–15
        "guide",                         // 16
        "share",                         // 17     Xbox Series Share / DualSense Create.
                                         //        Not in the W3C layout, which predates it.
    ]
    static let axisNames = ["left_x", "left_y", "right_x", "right_y"]  // 0–3

    static func buttonIndex(_ name: String) -> Int? {
        buttonNames.firstIndex(of: name.lowercased())
    }
    static func axisIndex(_ name: String) -> Int? {
        axisNames.firstIndex(of: name.lowercased())
    }
    static func buttonName(_ i: Int) -> String {
        i >= 0 && i < buttonNames.count ? buttonNames[i] : "button\(i)"
    }
}

/// HID usage pages this reader listens to.
///
/// A pad spreads its inputs over several pages, and which page a given input
/// lands on depends on the pad and even on the transport. An Xbox Series pad
/// over Bluetooth puts the sticks on Generic Desktop, the triggers on
/// Simulation (Brake / Accelerator), the face buttons on Button, and Share on
/// Consumer (Record). The same pad under Apple's wired driver puts the
/// triggers on Generic Desktop as Z / Rz.
enum HIDPage {
    static let genericDesktop = UInt32(kHIDPage_GenericDesktop)
    static let simulation     = UInt32(kHIDPage_Simulation)
    static let button         = UInt32(kHIDPage_Button)
    static let consumer       = UInt32(kHIDPage_Consumer)

    static func name(_ page: UInt32) -> String {
        switch page {
        case genericDesktop: return "generic desktop"
        case simulation:     return "simulation"
        case button:         return "button"
        case consumer:       return "consumer"
        default:             return String(format: "page 0x%02X", page)
        }
    }
}

/// HID axis usages, named for readability in configs and logs.
///
/// X…Rz are Generic Desktop usages (sticks, and triggers on wired Xbox pads).
/// Brake and Accelerator are Simulation-page usages, which is where Bluetooth
/// Xbox Series pads report LT and RT.
enum HIDAxis {
    static let x: UInt32  = 0x30
    static let y: UInt32  = 0x31
    static let z: UInt32  = 0x32
    static let rx: UInt32 = 0x33
    static let ry: UInt32 = 0x34
    static let rz: UInt32 = 0x35
    static let accelerator: UInt32 = 0xC4   // Simulation page — RT on Xbox Series
    static let brake: UInt32       = 0xC5   // Simulation page — LT on Xbox Series

    static func name(_ usage: UInt32) -> String {
        switch usage {
        case x: return "X"
        case y: return "Y"
        case z: return "Z"
        case rx: return "Rx"
        case ry: return "Ry"
        case rz: return "Rz"
        case accelerator: return "Accelerator"
        case brake: return "Brake"
        default: return String(format: "0x%02X", usage)
        }
    }
    static func fromName(_ s: String) -> UInt32? {
        switch s.lowercased() {
        case "x": return x
        case "y": return y
        case "z": return z
        case "rx": return rx
        case "ry": return ry
        case "rz": return rz
        case "accelerator": return accelerator
        case "brake": return brake
        default: return nil
        }
    }
}

/// One controller's translation table: raw HID → standard mapping.
///
/// This is the only part that differs per device, which is why `setup` writes
/// it and presets never mention it.
///
/// The tables are keyed by usage alone, not by (page, usage). Button and
/// Consumer share `buttons`; Generic Desktop and Simulation share `axes` and
/// `triggers`. The usage numbers of each pair do not overlap on any pad we
/// know of (Button is 1…N, Consumer's Record is 0xB2; sticks are 0x30…0x35,
/// Brake/Accelerator are 0xC4/0xC5), and keeping one flat table per kind is
/// what lets `[profile.buttons]` stay a plain `usage = "name"` list.
///
/// The D-pad needs no entry: a hat switch is decoded into dpad_* by the
/// reader itself. Pads that report the D-pad as four plain buttons (wired
/// Xbox 360) map those in `buttons` as before.
struct Profile {
    var vendorID: Int?
    var productID: Int?
    /// HID button usage → standard button index.
    var buttons: [UInt32: Int] = [:]
    /// HID axis usage → standard axis index (sticks).
    var axes: [UInt32: Int] = [:]
    /// HID axis usage → standard button index (analog triggers, i.e. 6 and 7).
    var triggers: [UInt32: Int] = [:]

    /// Layout shared by Xbox 360 / Xbox One pads under Apple's own
    /// `XboxGamepad` driver. Measured, not guessed — but D-pad direction
    /// order still varies between units, so `setup` should always win.
    static var xbox360: Profile {
        var p = Profile(vendorID: 0x045E, productID: 0x028E)
        p.buttons = [
            1: 0, 2: 1, 3: 2, 4: 3,       // A B X Y
            5: 4, 6: 5,                   // LB RB
            7: 10, 8: 11,                 // L3 R3 (absent on many clone pads)
            9: 9, 10: 8,                  // Start, Back — note HID has these reversed
            11: 16,                       // Guide
            12: 12, 13: 13, 14: 14, 15: 15,  // D-pad
        ]
        p.axes = [HIDAxis.x: 0, HIDAxis.y: 1, HIDAxis.rx: 2, HIDAxis.ry: 3]
        p.triggers = [HIDAxis.z: 6, HIDAxis.rz: 7]
        return p
    }
}

/// The D-pad as most pads report it over HID: one hat-switch element whose
/// value is a clockwise direction index, with an out-of-range value (0 on
/// Xbox Series, 8 or 15 on others) meaning centred.
///
/// Decoded into the four standard D-pad buttons, so the rest of the daemon
/// never learns the difference between a hat and four switches. A diagonal
/// presses two buttons, the way a browser's Gamepad API reports it.
struct Hat: Equatable {
    var up = false
    var down = false
    var left = false
    var right = false

    static func decode(raw: Int, min lo: Int, max hi: Int) -> Hat {
        guard raw >= lo, raw <= hi else { return Hat() }   // null state = centred
        let i = raw - lo
        switch hi - lo + 1 {
        case 8:   // N NE E SE S SW W NW
            return Hat(up:    i == 7 || i == 0 || i == 1,
                       down:  (3...5).contains(i),
                       left:  (5...7).contains(i),
                       right: (1...3).contains(i))
        case 4:   // N E S W
            return Hat(up: i == 0, down: i == 2, left: i == 3, right: i == 1)
        default:
            return Hat()
        }
    }

    /// Standard button index → pressed, in a fixed order.
    var buttons: [(index: Int, pressed: Bool)] {
        [(12, up), (13, down), (14, left), (15, right)]
    }

    /// `up`, `up+right`, … or `centre`, for learn mode.
    var label: String {
        let parts = [up ? "up" : nil, down ? "down" : nil,
                     left ? "left" : nil, right ? "right" : nil].compactMap { $0 }
        return parts.isEmpty ? "centre" : parts.joined(separator: "+")
    }
}

/// Events after translation. `raw*` cases carry untranslated HID values and
/// exist for learn/setup mode, where the whole point is seeing what the
/// hardware actually sends.
enum GamepadEvent {
    case button(index: Int, pressed: Bool)
    case trigger(index: Int, value: Double)   // 0.0 … 1.0
    case axis(index: Int, value: Double)      // −1.0 … 1.0
    case rawButton(usage: UInt32, page: UInt32, pressed: Bool)
    case rawAxis(usage: UInt32, page: UInt32, value: Int, min: Int, max: Int)
    case rawHat(value: Int, min: Int, max: Int)
}

final class GamepadReader {

    private let manager: IOHIDManager
    private var profile: Profile
    private let emitRaw: Bool
    private var handler: ((GamepadEvent) -> Void)?
    /// Last emitted value per axis, so we only report meaningful movement.
    private var lastAxis: [UInt32: Double] = [:]
    /// Last decoded hat state, so each D-pad direction fires once per press.
    private var hat = Hat()

    init(profile: Profile, emitRaw: Bool = false) {
        self.profile = profile
        self.emitRaw = emitRaw
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // No vendor/product in the profile means "any gamepad", which is what
        // setup wants on a machine whose controller is still unknown.
        var match: [String: Any] = [:]
        if let v = profile.vendorID { match[kIOHIDVendorIDKey] = v }
        if let p = profile.productID { match[kIOHIDProductIDKey] = p }
        if match.isEmpty {
            match[kIOHIDDeviceUsagePageKey] = kHIDPage_GenericDesktop
            match[kIOHIDDeviceUsageKey] = kHIDUsage_GD_GamePad
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    }

    /// Names of currently matching devices, for `status` and error messages.
    func connectedDevices() -> [String] {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devs.map { dev in
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let v = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let p = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
            return String(format: "%@ (%04X:%04X)", name, v, p)
        }
    }

    func start(_ handler: @escaping (GamepadEvent) -> Void) -> Bool {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<GamepadReader>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func handle(_ value: IOHIDValue) {
        guard let handler else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)

        switch page {
        case HIDPage.button, HIDPage.consumer:
            let pressed = raw != 0
            if emitRaw { handler(.rawButton(usage: usage, page: page, pressed: pressed)) }
            if let index = profile.buttons[usage] {
                handler(.button(index: index, pressed: pressed))
            }

        case HIDPage.genericDesktop, HIDPage.simulation:
            // Ignore the collection-level Game Pad / Joystick usages.
            if page == HIDPage.genericDesktop,
               usage == UInt32(kHIDUsage_GD_GamePad) || usage == UInt32(kHIDUsage_GD_Joystick) {
                return
            }

            let lo = IOHIDElementGetLogicalMin(element)
            let hi = IOHIDElementGetLogicalMax(element)
            guard hi > lo else { return }

            if page == HIDPage.genericDesktop, usage == UInt32(kHIDUsage_GD_Hatswitch) {
                handleHat(raw: raw, min: lo, max: hi)
                return
            }

            if emitRaw { handler(.rawAxis(usage: usage, page: page, value: raw, min: lo, max: hi)) }

            if let triggerIndex = profile.triggers[usage] {
                let v = Double(raw - lo) / Double(hi - lo)          // 0 … 1
                if changedEnough(usage, v, threshold: 0.02) {
                    handler(.trigger(index: triggerIndex, value: v))
                }
            } else if let axisIndex = profile.axes[usage] {
                let v = (Double(raw - lo) / Double(hi - lo)) * 2 - 1  // −1 … 1
                if changedEnough(usage, v, threshold: 0.01) {
                    handler(.axis(index: axisIndex, value: v))
                }
            }

        default:
            return
        }
    }

    /// Turns one hat-switch report into zero or more D-pad button events —
    /// exactly the presses and releases that changed since the last report.
    private func handleHat(raw: Int, min lo: Int, max hi: Int) {
        guard let handler else { return }
        if emitRaw { handler(.rawHat(value: raw, min: lo, max: hi)) }
        let now = Hat.decode(raw: raw, min: lo, max: hi)
        guard now != hat else { return }
        let before = hat
        hat = now
        for (was, is_) in zip(before.buttons, now.buttons) where was.pressed != is_.pressed {
            handler(.button(index: is_.index, pressed: is_.pressed))
        }
    }

    /// Analog inputs jitter constantly; without this the daemon would spend
    /// its life reacting to noise a user never produced.
    private func changedEnough(_ usage: UInt32, _ value: Double, threshold: Double) -> Bool {
        let previous = lastAxis[usage]
        if let previous, abs(previous - value) < threshold { return false }
        lastAxis[usage] = value
        return true
    }
}
