import Foundation
import MemeCamCore
import Observation

/// Window-level UI state shared by the main window, its inspector and the menu commands.
@MainActor @Observable
final class UIState {
    enum InspectorTab: String, CaseIterable, Identifiable {
        case settings, memes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .settings: String(localized: "Settings")
            case .memes: String(localized: "Memes")
            }
        }
        var symbol: String {
            switch self {
            case .settings: "slider.horizontal.3"
            case .memes: "photo.on.rectangle.angled"
            }
        }
    }

    var showInspector: Bool { didSet { defaults.set(showInspector, forKey: "showInspector") } }
    var inspectorTab: InspectorTab { didSet { defaults.set(inspectorTab.rawValue, forKey: "inspectorTabV2") } }
    /// Reaction whose memes are open in the meme editor; nil shows the reaction grid.
    var editingReaction: Reaction?
    /// Set by Help › Show Onboarding… to replay the onboarding after it was completed.
    var onboardingRequested = false

    private let defaults = UserDefaults.standard

    init() {
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
        inspectorTab = defaults.string(forKey: "inspectorTabV2").flatMap(InspectorTab.init) ?? .settings
    }

    /// Opens the meme editor, optionally straight at one reaction.
    func editMemes(for reaction: Reaction? = nil) {
        showInspector = true
        inspectorTab = .memes
        editingReaction = reaction
    }
}
