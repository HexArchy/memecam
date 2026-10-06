import SwiftUI

struct ContentView: View {
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        PreviewStage()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showInspector.toggle() } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide the inspector (\u{2318}I)")
                }
            }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .frame(minWidth: 900, minHeight: 560)
    }
}
