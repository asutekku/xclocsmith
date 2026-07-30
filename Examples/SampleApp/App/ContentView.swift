import SwiftUI

/// Every localization shape xclocSmith understands, in one file.
struct ContentView: View {
    let isOn: Bool
    let name: String?
    let count: Int

    var body: some View {
        VStack {
            Text("Welcome")
            Button("Save") { }
            Label("Photos", systemImage: "photo")
            Text(isOn ? "Enabled" : "Disabled")
            Text(name ?? "Anonymous")
            Text("You have \(count) messages")
            Text("Disk is full", tableName: "Errors")
            StatRow(label: "Total time")
        }
        .navigationTitle("Home")
        .accessibilityLabel("Main screen")
    }
}

/// A custom view that localizes the String it is given, so its call sites count.
struct StatRow: View {
    let label: String
    var body: some View { Text(LocalizedStringKey(label)) }
}

func messages() -> String {
    String(localized: "Loaded")
}

#Preview {
    ContentView(isOn: true, name: "Sample data, not shipped", count: 3)
}
