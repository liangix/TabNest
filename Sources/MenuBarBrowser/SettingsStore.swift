import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
        }
    }

    init() {
        settings = AppSettings.load()
    }
}
