#if DEBUG
import BreeFoundation
import SwiftUI

enum SpinnerEnergy: String {
    case low = "Low"
    case mediumHigh = "Medium-High"
    case high = "High"

    var color: Color {
        switch self {
        case .low: return BreeChromePalette.currentSnapshot.signalSuccess
        case .mediumHigh: return BreeChromePalette.currentSnapshot.signalAttention
        case .high: return BreeChromePalette.currentSnapshot.signalError
        }
    }
}
#endif
