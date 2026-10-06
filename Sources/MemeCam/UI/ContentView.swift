import SwiftUI

// Placeholder — replaced by the UI agent.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    var body: some View { Text(model.status.reaction.title) }
}
