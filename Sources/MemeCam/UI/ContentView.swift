import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    private var showOnboarding: Bool { !onboardingCompleted || ui.onboardingRequested }

    var body: some View {
        ZStack {
            mainContent
                .disabled(showOnboarding)
                .environment(\.isPreviewSuspended, showOnboarding)
            if showOnboarding {
                OnboardingView {
                    onboardingCompleted = true
                    ui.onboardingRequested = false
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.45), value: showOnboarding)
        .toolbar { MainToolbar() }
        .toolbar(showOnboarding ? .hidden : .visible, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.thinMaterial, for: .window)
        .tint(Design.accent)
        .frame(minWidth: 760, minHeight: 600)
    }

    private var mainContent: some View {
        @Bindable var ui = ui
        return VStack(spacing: Design.sectionSpacing) {
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
        .alert("Couldn't Update Memes", isPresented: libraryErrorShown, presenting: model.libraryError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onAppear { model.refreshCameras() }
    }

    private var libraryErrorShown: Binding<Bool> {
        Binding(get: { model.libraryError != nil }, set: { if !$0 { model.libraryError = nil } })
    }
}
