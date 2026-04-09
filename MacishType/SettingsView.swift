import SwiftUI

struct SettingsView: View {
    @AppStorage("CandidateWindowDirection") private var direction = "horizontal"
    @AppStorage("FontSize") private var fontSize = 16

    var body: some View {
        Form {
            Section("Candidate window") {
                Picker("Orientation:", selection: $direction) {
                    Text("Horizontal").tag("horizontal")
                    Text("Vertical").tag("vertical")
                }
                Picker("Font size:", selection: $fontSize) {
                    ForEach([14, 16, 18, 24, 36], id: \.self) { size in
                        Text(verbatim: "\(size)").tag(size)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

#Preview {
    SettingsView()
}
