import ImageIO
import SwiftUI
import AIMeterCore

enum MeterTheme {
    static let panelWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 22
    static let rowHeight: CGFloat = 88
    static let contentPadding: CGFloat = 20
}

extension ProviderID {
    var assetName: String {
        switch self {
        case .openAI: "openai"
        case .claude: "claude"
        case .gemini: "gemini"
        case .cursor: "cursor"
        case .copilot: "copilot"
        }
    }

    var badgeCGImage: CGImage? {
        guard
            let url = Bundle.main.url(forResource: assetName, withExtension: "png")
                ?? Bundle.module.url(
                    forResource: assetName,
                    withExtension: "png"
                ),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var accentColor: Color {
        switch self {
        case .openAI: Color(red: 0.31, green: 0.79, blue: 0.58)
        case .claude: Color(red: 0.96, green: 0.55, blue: 0.27)
        case .gemini: Color(red: 0.36, green: 0.58, blue: 0.98)
        case .cursor: Color(red: 0.62, green: 0.39, blue: 0.92)
        case .copilot: Color(red: 0.54, green: 0.78, blue: 0.36)
        }
    }
}
