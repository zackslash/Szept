import Foundation
import SwiftUI

final class Preferences {
    @AppStorage("makeupGainDB") var makeupGainDB: Double = 6.0
    @AppStorage("autoAdjust") var autoAdjust: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("isProcessingEnabled") var isProcessingEnabled: Bool = true
    @AppStorage("qualityPreset") var qualityPreset: String = "aggressive"
    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""
    @AppStorage("outputDeviceUID") var outputDeviceUID: String = ""
}
