import Foundation
import Carbon.HIToolbox

/// Registers and manages system-wide Carbon hotkeys. Must be created and
/// retained for the lifetime of the app (created in applicationDidFinishLaunching).
///
/// Why Carbon `RegisterEventHotKey` and not `NSEvent.addGlobalMonitorForEvents`:
/// Carbon hotkeys work under the hardened runtime with no extra permissions,
/// while global NSEvent monitors require an Accessibility prompt.
final class HotkeyManager {

    private let dispatch: (AppAction) -> Void

    private var registrations: [Slot: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    // MARK: - Hotkey slots

    /// One registration per physical key combo. All slots are pressed-only
    /// except `bypassMomentary`, the only slot with a release semantic: it
    /// fires `.bypassOn` while held and `.bypassOff` on release.
    enum Slot: CaseIterable {
        case toggleEngine
        case cycleClarity
        case strengthUp
        case strengthDown
        case bypassMomentary
        case shareAudio
        case voiceMute

        /// Action fired when the combo is released. nil (every slot except
        /// the momentary bypass) = release ignored.
        var releaseAction: AppAction? {
            self == .bypassMomentary ? .bypassOff : nil
        }

        /// Action fired when the combo is pressed. nil = press ignored.
        var pressAction: AppAction? {
            HotkeyManager.config(for: self).pressAction
        }
    }

    // MARK: - Bindings

    struct Binding: Equatable {
        var keyCode: UInt32
        var modifierMask: UInt32   // Carbon masks: cmdKey/shiftKey/optionKey/controlKey
    }

    /// Everything that varies per slot, in one exhaustive switch.
    private struct Config {
        let pressAction: AppAction?
        let prefKey: String
        let defaultBinding: Binding
        let label: String
    }

    private static func config(for slot: Slot) -> Config {
        switch slot {
        case .toggleEngine:
            return Config(pressAction: .toggleEngine, prefKey: "hotkey.toggle",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_N), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Start/stop processing")
        case .cycleClarity:
            return Config(pressAction: .cycleClarity, prefKey: "hotkey.clarity",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_C), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Cycle clarity")
        case .strengthUp:
            return Config(pressAction: .strengthUp, prefKey: "hotkey.strengthUp",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_RightBracket), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Isolation strength up")
        case .strengthDown:
            return Config(pressAction: .strengthDown, prefKey: "hotkey.strengthDown",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_LeftBracket), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Isolation strength down")
        case .bypassMomentary:
            return Config(pressAction: .bypassOn, prefKey: "hotkey.bypass",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_B), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Bypass A/B (hold)")
        case .shareAudio:
            return Config(pressAction: .shareToggle, prefKey: "hotkey.shareAudio",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_S), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Share system audio")
        case .voiceMute:
            return Config(pressAction: .voiceMuteToggle, prefKey: "hotkey.voiceMute",
                          defaultBinding: Binding(keyCode: UInt32(kVK_ANSI_M), modifierMask: UInt32(controlKey | optionKey)),
                          label: "Mute mic")
        }
    }

    static func prefKey(for slot: Slot) -> String {
        config(for: slot).prefKey
    }

    static func defaultBinding(for slot: Slot) -> Binding {
        config(for: slot).defaultBinding
    }

    static func label(for slot: Slot) -> String {
        config(for: slot).label
    }

    /// Persistence format: "keyCode:modifierMask".
    static func encode(_ binding: Binding) -> String {
        "\(binding.keyCode):\(binding.modifierMask)"
    }

    static func decode(_ raw: String) -> Binding? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let code = UInt32(parts[0]),
              let mask = UInt32(parts[1]) else { return nil }
        return Binding(keyCode: code, modifierMask: mask)
    }

    /// Human-readable name for a key code, for the read-only hotkey list.
    static func keyName(keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "FwdDel"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        default: return "Key \(keyCode)"
        }
    }

    private var bindings: [Slot: Binding] = [:]

    /// Deterministic EventHotKeyID.id per slot: its position in
    /// `Slot.allCases` plus 1 (never 0). NOT a hash: hashValue is randomized
    /// per process and would make the fired ID unmatchable.
    private func hotKeyNumericID(for slot: Slot) -> UInt32 {
        UInt32(Slot.allCases.firstIndex(of: slot)! + 1)
    }

    private func slot(forNumericID id: UInt32) -> Slot? {
        let idx = Int(id) - 1
        guard idx >= 0, idx < Slot.allCases.count else { return nil }
        return Slot.allCases[idx]
    }

    // MARK: - Lifecycle

    init(onDispatch: @escaping (AppAction) -> Void) {
        self.dispatch = onDispatch
        loadBindings()
        installEventHandler()
        registerAll()
    }

    deinit {
        // deinit is nonisolated; UnregisterEventHotKey/RemoveEventHandler are
        // thread-safe C calls.
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    // MARK: - Persistence

    private func loadBindings() {
        let defaults = UserDefaults.standard
        for slot in Slot.allCases {
            let key = Self.prefKey(for: slot)
            if let raw = defaults.string(forKey: key), let binding = Self.decode(raw) {
                bindings[slot] = binding
            } else {
                bindings[slot] = Self.defaultBinding(for: slot)
            }
        }
    }

    // MARK: - Carbon registration

    private func installEventHandler() {
        // Both pressed AND released: the momentary bypass needs the release.
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Pass self as userData (unretained: the manager is owned by the app
        // and lives for the process lifetime).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 2, &spec, selfPtr, &eventHandler)
    }

    private func registerAll() {
        for (slot, binding) in bindings {
            _ = register(slot: slot, binding: binding)
        }
    }

    @discardableResult
    private func register(slot: Slot, binding: Binding) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.fourCC("Szpt"), id: hotKeyNumericID(for: slot))
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(binding.keyCode, binding.modifierMask, hotKeyID,
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref = ref {
            registrations[slot] = ref
            return true
        }
        // The expected failure is eventHotKeyExistsErr (-9878): another app
        // already owns this combo. Never crash on a hotkey failure; anything
        // other than a conflict is logged so it isn't invisible.
        if err != OSStatus(eventHotKeyExistsErr) {
            FileLog.log("hotkey: register failed for \(slot) with OSStatus \(err)")
        } else {
            FileLog.log("hotkey: \(slot) combo already owned by another app")
        }
        return false
    }

    // MARK: - Dispatch

    /// Called by the Carbon C shim; maps the event to the slot's action and
    /// hands it to the dispatch closure on the main thread.
    fileprivate func handleHotKeyEvent(numericID: UInt32, pressed: Bool) {
        guard let slot = slot(forNumericID: numericID) else { return }
        let action = pressed ? slot.pressAction : slot.releaseAction
        guard let action else { return }
        DispatchQueue.main.async { [dispatch] in
            dispatch(action)
        }
    }

    fileprivate static func fourCC(_ s: String) -> OSType {
        let bytes = Array(s.utf8)
        guard bytes.count >= 4 else { return 0 }
        return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16 | OSType(bytes[2]) << 8 | OSType(bytes[3])
    }
}

// MARK: - Carbon event handler (C-compatible function)

/// Top-level callback required by InstallEventHandler. Carbon delivers hotkey
/// events on the main run loop in a menu-bar app.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
        return OSStatus(eventNotHandledErr)
    }
    let pressed = kind == UInt32(kEventHotKeyPressed)

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    // Ignore events whose signature is not ours (defensive: Carbon delivers
    // hotkey events by target, but never trust a foreign signature).
    guard hotkeyID.signature == HotkeyManager.fourCC("Szpt") else { return OSStatus(eventNotHandledErr) }
    let numericID = hotkeyID.id

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKeyEvent(numericID: numericID, pressed: pressed)
    return noErr
}
