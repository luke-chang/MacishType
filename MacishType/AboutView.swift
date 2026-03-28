import SwiftUI

struct AboutView: View {
    @State private var showBuildNumber = false

    private let version: String
    private let gitHash: String
    private let buildNumber: String

    init() {
        let info = Bundle.main.infoDictionary
        version = info?["CFBundleShortVersionString"] as? String ?? "?"
        gitHash = info?["GitCommitHash"] as? String ?? "?"
        buildNumber = info?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("MacishType")
                .font(.title)
                .bold()

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Version")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text("\(version) (\(showBuildNumber ? buildNumber : gitHash))")
                        .onTapGesture { showBuildNumber.toggle() }
                }
                GridRow {
                    Text("Author")
                        .foregroundStyle(.secondary)
                    Text("Luke Chang")
                }
            }

            Text("Copyright © 2026 Luke Chang")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 0, leading: 24, bottom: 24, trailing: 24))
        .frame(width: 300)
    }
}

#Preview {
    AboutView()
}
