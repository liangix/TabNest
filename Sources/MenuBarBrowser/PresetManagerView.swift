import SwiftUI

struct PresetManagerView: View {
    @ObservedObject var store: PinStore
    let onAdd: () -> Void
    let onEdit: (Pin) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.presets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("还没有预设站点")
                        .foregroundColor(.secondary)
                    Button("添加站点", action: onAdd)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.presets) { preset in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.body.weight(.medium))
                            Text(preset.urlString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if store.pin(with: preset.id) == nil {
                            Button("打开") { store.openPreset(preset.id) }
                        } else {
                            Button("关闭") { store.close(preset.id) }
                        }
                        Button("编辑") { onEdit(preset) }
                        Button(role: .destructive) {
                            store.deletePreset(preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除预设")
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
            HStack {
                Text("关闭 Tab 不会删除预设")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("添加站点…", action: onAdd)
            }
            .padding(12)
        }
        .frame(width: 560, height: 400)
    }
}
