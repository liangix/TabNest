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
                    Text(L10n.text(.presetsEmpty))
                        .foregroundColor(.secondary)
                    Button(L10n.text(.windowAddSite), action: onAdd)
                        .tabNestPrimaryAction()
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
                            Button(L10n.text(.commonOpen)) { store.openPreset(preset.id) }
                        } else {
                            Button(L10n.text(.commonClose)) { store.close(preset.id) }
                        }
                        Button(L10n.text(.commonEdit)) { onEdit(preset) }
                        Button(role: .destructive) {
                            store.deletePreset(preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text(.presetsDeleteHelp))
                        .accessibilityLabel(L10n.text(.presetsDeleteHelp))
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(L10n.text(.presetsCloseKeepsPreset))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(L10n.text(.presetsAddSiteEllipsis), action: onAdd)
                    .tabNestPrimaryAction()
            }
            .padding(12)
            .tabNestToolbarSurface()
        }
        .frame(width: 560, height: 400)
    }
}
