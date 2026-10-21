import Foundation
import Cocoa
import PinShotCore

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let userDefaultsKey = "com.fable.PinShot.settings"

    @Published var settings: PinShotSettings {
        didSet {
            saveSettings()
            onSettingsChanged?()
        }
    }

    var onSettingsChanged: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(PinShotSettings.self, from: data) {
            self.settings = Self.applyOneTimeMigrations(decoded)
            // ⚠️ `settings` 的 didSet 在 init 里不会触发，迁移结果必须手动落盘，
            // 否则只改了内存：本次运行看着是新模型，下次启动又变回旧的。
            saveSettings()
        } else {
            self.settings = PinShotSettings()
        }
    }

    /// 一次性迁移（只跑一次，之后不再干预用户的改动）。
    ///
    /// 目前只有一条：智谱的 `glm-4-flash` 是**浮动别名**，服务端切到哪个版本不可控；
    /// 实测同一份 11 行文案，别名 4.3~6.3s，而带日期的快照版 `glm-4-flash-250414`
    /// 只要 1.7~2.4s（免费额度相同）。所以帮老用户切过去，用户仍可手动改回。
    private static func applyOneTimeMigrations(_ input: PinShotSettings) -> PinShotSettings {
        let flag = "com.fable.PinShot.migrated.glmModelSnapshot"
        guard !UserDefaults.standard.bool(forKey: flag) else { return input }
        UserDefaults.standard.set(true, forKey: flag)

        var s = input
        if s.translation.baseURL.contains("bigmodel.cn"),
           s.translation.modelName == "glm-4-flash" {
            s.translation.modelName = "glm-4-flash-250414"
            SnipLog.write("Settings: 迁移模型 glm-4-flash → glm-4-flash-250414（快照版，实测快 2~3 倍）")
        }
        return s
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    func resetToDefaults() {
        settings = PinShotSettings()
    }
}
