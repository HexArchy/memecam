import SwiftUI

/// Trailing inspector: Settings and the meme editor.
struct InspectorView: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            Picker("Inspector section", selection: $ui.inspectorTab) {
                ForEach(UIState.InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            switch ui.inspectorTab {
            case .settings: SettingsForm()
            case .memes: MemeLibraryView()
            }
        }
    }
}
