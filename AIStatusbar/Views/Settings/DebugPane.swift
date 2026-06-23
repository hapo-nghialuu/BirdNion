import SwiftUI
import AppKit

/// Debug pane. Kept intentionally small — the real diagnostic tools live in
/// CodexBar's full DebugPane (probe logs, fetch strategy, error simulation,
/// caches). This implementation gives BOSS a couple of useful shortcuts:
/// open the Application Support directory and view the providers config path.
struct DebugPane: View {
    @State private var supportDir: URL? = {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false)
            .appendingPathComponent("AIStatusbar", isDirectory: true)
    }()

    var body: some View {
        SettingsPage {
            SettingsCard(
                header: "Tệp",
                footer: "Để xem log probe / fetch strategy thật, mở Console.app và filter theo bundle ID."
            ) {
                SettingsLabeledRow(
                    title: "Thư mục Application Support",
                    subtitle: supportDir?.path ?? "—"
                ) {
                    Button("Mở Finder") {
                        if let url = supportDir {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsLabeledRow(
                    title: "providers.json",
                    subtitle: "providers.json lưu trạng thái bật/tắt và account label."
                ) {
                    Button("Mở") {
                        if let url = try? ProvidersStore.defaultURL() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
