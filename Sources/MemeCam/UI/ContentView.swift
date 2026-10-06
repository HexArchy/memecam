import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: Design.sectionSpacing) {
            PreviewStage()
            ControlBar()
            ReactionStrip()
        }
        .padding(.horizontal, Design.stagePadding)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowBackdrop() }
        .inspector(isPresented: $ui.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar { MainToolbar() }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.thinMaterial, for: .window)
        .tint(Design.brand)
        .alert("Couldn't Update Memes", isPresented: libraryErrorShown, presenting: model.libraryError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onAppear { model.refreshCameras() }
        .frame(minWidth: 760, minHeight: 600)
    }

    private var libraryErrorShown: Binding<Bool> {
        Binding(get: { model.libraryError != nil }, set: { if !$0 { model.libraryError = nil } })
    }
}
