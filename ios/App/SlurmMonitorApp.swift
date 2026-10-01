import SlurmKit
import SwiftUI

// Minimal shell so the project compiles. To be replaced by the real app.
@main
struct SlurmMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Slurm Monitor")
                    .font(.title2.weight(.semibold))
                Text("Add a widget to your Home Screen to see the cluster status.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
