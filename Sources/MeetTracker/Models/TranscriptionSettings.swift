import Foundation

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case localWhisper
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localWhisper: "Whisper local"
        case .appleSpeech: "Apple Speech"
        }
    }
}

enum WhisperModelOption: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small
    case medium
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: "Tiny · más rápido"
        case .base: "Base"
        case .small: "Small · recomendado"
        case .medium: "Medium · más preciso"
        case .largeV3: "Large v3 · máxima precisión"
        }
    }

    var approximateSize: String {
        switch self {
        case .tiny: "~75 MB"
        case .base: "~145 MB"
        case .small: "~465 MB"
        case .medium: "~1,5 GB"
        case .largeV3: "~3 GB"
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case spanish = "es"
    case english = "en"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Detectar automáticamente"
        case .spanish: "Español"
        case .english: "Inglés"
        case .portuguese: "Portugués"
        case .french: "Francés"
        case .german: "Alemán"
        case .italian: "Italiano"
        }
    }

    var whisperCode: String? {
        self == .automatic ? nil : rawValue
    }

    var appleLocale: Locale {
        switch self {
        case .automatic, .spanish: Locale(identifier: "es-CL")
        case .english: Locale(identifier: "en-US")
        case .portuguese: Locale(identifier: "pt-BR")
        case .french: Locale(identifier: "fr-FR")
        case .german: Locale(identifier: "de-DE")
        case .italian: Locale(identifier: "it-IT")
        }
    }
}

enum WhisperTaskMode: String, CaseIterable, Identifiable {
    case transcribe
    case translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcribe: "Transcribir en el idioma original"
        case .translate: "Traducir al inglés"
        }
    }
}
