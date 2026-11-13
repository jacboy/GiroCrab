import SwiftUI

/// Persisted view-layout switches shared by the View menu, the toolbar and
/// the settings (GitHub #233, #234).
enum ViewLayout {
    /// Charts and analysis cards above the booking list.
    static let statisticsKey = "showStatistics"
    /// Right-hand inspector column.
    static let inspectorKey = "showInspector"
}
