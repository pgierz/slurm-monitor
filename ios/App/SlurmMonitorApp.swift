import SlurmKit
import SwiftUI

/// The app: a sidebar of sections on iPad, a list that pushes each section on
/// iPhone. Nothing is fetched at launch; each section loads when it is shown.
@main
struct SlurmMonitorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Palette.blue)
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationSplitView {
            SectionList()
        } detail: {
            SectionDetail(section: model.selection)
        }
        .onAppear {
            // On a wide screen the detail column would otherwise start empty.
            if horizontalSizeClass == .regular && model.selection == nil {
                model.selection = model.settings.isConfigured ? .queue : .settings
            }
        }
    }
}

private struct SectionList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section {
                ForEach(AppSection.families) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.symbolName)
                    }
                }
            }
            Section {
                NavigationLink(value: AppSection.settings) {
                    Label(AppSection.settings.title, systemImage: AppSection.settings.symbolName)
                }
            } footer: {
                if !model.settings.isConfigured {
                    Text("Set the server address in Settings to begin.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Slurm Monitor")
    }
}

private struct SectionDetail: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection?

    var body: some View {
        switch section {
        case .some(.queue):
            QueueScreen(initialPartition: model.settings.defaultPartition)
        case .some(.nodes):
            NodesScreen(initialPartition: model.settings.defaultPartition)
        case .some(.qos):
            QosScreen()
        case .some(.gpu):
            GpuScreen()
        case .some(.runners):
            RunnersScreen()
        case .some(.settings):
            SettingsScreen()
        case .none:
            NoSectionView()
        }
    }
}

private struct NoSectionView: View {
    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            Text("Choose a section.")
                .font(.body)
                .foregroundStyle(Palette.secondary)
        }
    }
}
