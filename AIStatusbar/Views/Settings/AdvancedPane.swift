import SwiftUI

/// Advanced settings: privacy + a debug toggle. The debug toggle gates the
/// Debug tab in the tab bar.
struct AdvancedPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(header: "Riêng tư") {
                SettingsLabeledRow(
                    title: "Ẩn thông tin cá nhân",
                    subtitle: "Che email tài khoản trên chip và popover."
                ) {
                    Toggle("", isOn: $settings.hidePersonalInfo).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(
                header: "Nhà phát triển",
                footer: "Khởi động lại app để áp dụng một số thay đổi (ví dụ ngôn ngữ)."
            ) {
                SettingsLabeledRow(
                    title: "Hiện mục Debug",
                    subtitle: "Thêm tab Debug để xem log và cache."
                ) {
                    Toggle("", isOn: $settings.debugMenuEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
