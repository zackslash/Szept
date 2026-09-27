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

    private var registrations: [AppAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    // MARK: - Bindings

    struct Binding: Equatable {
        var keyCode: UInt32
        var modifierMask: UInt32   // Carbon masks: cmdKey/shiftKey/optionKey/controlKey
    }

    static func prefKey(for action: AppAction) -> String {
        switch action {
        case .toggleEngine:  return "hotkey.toggle"
        case .cycleClarity:  return "hotkey.clarity"
        case .strengthUp:    return "hotkey.strengthUp"
        case .strengthDown:  return "hotkey.strengthDown"
        }
    }

    static func defaultBinding(for action: AppAction) -> Binding {
        switch action {
        case .toggleEngine:  return Binding(keyCode: UInt32(kVK_ANSI_N), modifierMask: UInt32(controlKey | optionKey))
        case .cycleClarity:  return Binding(keyCode: UInt32(kVK_ANSI_C), modifierMask: UInt32(controlKey | optionKey))
        case .strengthUp:    return Binding(keyCode: UInt32(kVK_ANSI_RightBracket), modifierMask: UInt32(controlKey | optionKey))
        case .strengthDown:  return Binding(keyCode: UInt32(kVK_ANSI_LeftBracket), modifierMask: UInt32(controlKey | optionKey))
        }
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

    private var bindings: [AppAction: Binding] = [:]

    /// Deterministic EventHotKeyID.id per action: its position in
    /// `AppAction.allCases` plus 1 (never 0). NOT a hash: hashValue is
    /// randomized per process and would make the fired ID unmatchable.
    private func hotKeyNumericID(for action: AppAction) -> UInt32 {
        UInt32(AppAction.allCases.firstIndex(of: action)! + 1)
    }

    private func action(forNumericID id: UInt32) -> AppAction? {
        let idx = Int(id) - 1
        guard idx >= 0, idx < AppAction.allCases.count else { return nil }
        return AppAction.allCases[idx]
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

    // MARK: - Public API

    /// Update the binding for one action: unregisters the old combo, persists
    /// the new one, and re-registers. Returns true if registration succeeded.
    @discardableResult
    func rebind(action: AppAction, keyCode: UInt32, modifierMask: UInt32) -> Bool {
        let binding = Binding(keyCode: keyCode, modifierMask: modifierMask)
        unregister(action)
        bindings[action] = binding
        UserDefaults.standard.set(Self.encode(binding), forKey: Self.prefKey(for: action))
        return register(action: action, binding: binding)
    }

    // MARK: - Persistence

    private func loadBindings() {
        let defaults = UserDefaults.standard
        for action in AppAction.allCases {
            let key = Self.prefKey(for: action)
            if let raw = defaults.string(forKey: key), let binding = Self.decode(raw) {
                bindings[action] = binding
            } else {
                bindings[action] = Self.defaultBinding(for: action)
            }
        }
    }

    // MARK: - Carbon registration

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Pass self as userData (unretained: the manager is owned by the app
        // and lives for the process lifetime).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, selfPtr, &eventHandler)
    }

    private func registerAll() {
        for (action, binding) in bindings {
            _ = register(action: action, binding: binding)
        }
    }

    @discardableResult
    private func register(action: AppAction, binding: Binding) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.fourCC("Szpt"), id: hotKeyNumericID(for: action))
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(binding.keyCode, binding.modifierMask, hotKeyID,
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref = ref {
            registrations[action] = ref
            return true
        }
        // The expected failure is eventHotKeyExistsErr (-9878): another app
        // already owns this combo. Never crash on a hotkey failure; anything
        // other than a conflict is logged so it isn't invisible.
        if err != OSStatus(eventHotKeyExistsErr) {
            FileLog.log("hotkey: register failed for \(action) with OSStatus \(err)")
        } else {
            FileLog.log("hotkey: \(action) combo already owned by another app")
        }
        return false
    }

    private func unregister(_ action: AppAction) {
        if let ref = registrations.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    // MARK: - Dispatch

    /// Called by the Carbon C shim on the main run loop; routes through
    /// ActionRouter on the main thread.
    fileprivate func handleHotKeyEvent(numericID: UInt32) {
        guard let action = action(forNumericID: numericID) else { return }
        DispatchQueue.main.async { [dispatch] in
            dispatch(action)
        }
    }

    private static func fourCC(_ s: String) -> OSType {
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
    guard GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let numericID = hotkeyID.id

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKeyEvent(numericID: numericID)
    return noErr
}
