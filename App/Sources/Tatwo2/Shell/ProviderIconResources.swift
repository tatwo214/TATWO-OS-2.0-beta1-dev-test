import Foundation

/// Shares the packaged-resource resolver; never invokes SwiftPM's trapping accessor.
enum ProviderIconResources {
    static func url(for fileName: String) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg")
            ?? TatwoResources.url(forResource: fileName, withExtension: "svg", subdirectory: "ProviderIcons")
    }

    /// W181：點陣圖示（例如私訊框的 TATWO 助理頭像，使用者的 logo）。
    static func pngURL(for fileName: String) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "png")
            ?? TatwoResources.url(forResource: fileName, withExtension: "png", subdirectory: "ProviderIcons")
    }

    static func url(for fileName: String, roots: [URL]) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg", roots: roots)
            ?? TatwoResources.url(forResource: fileName, withExtension: "svg", subdirectory: "ProviderIcons", roots: roots)
    }
}
