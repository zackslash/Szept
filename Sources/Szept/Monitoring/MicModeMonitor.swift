import Foundation
import AVFoundation

@Observable
final class MicModeMonitor {
    var isVoiceIsolationActive: Bool = false

    private var activeModeObserver: NSObject?

    init() {
        startObserving()
    }

    deinit {
        if let observer = activeModeObserver {
            AVCaptureDevice.self.removeObserver(observer, forKeyPath: #keyPath(AVCaptureDevice.activeMicrophoneMode))
        }
    }

    private func startObserving() {
        let observer = MicModeObserver { [weak self] in
            self?.updateState()
        }
        AVCaptureDevice.self.addObserver(
            observer,
            forKeyPath: #keyPath(AVCaptureDevice.activeMicrophoneMode),
            options: [.initial, .new],
            context: nil
        )
        activeModeObserver = observer
    }

    private func updateState() {
        let active = AVCaptureDevice.activeMicrophoneMode == .voiceIsolation
        DispatchQueue.main.async { [weak self] in
            self?.isVoiceIsolationActive = active
        }
    }

    func openMicModePicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}

private final class MicModeObserver: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        onChange()
    }
}
