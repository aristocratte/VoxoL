import Foundation

/// Why a model could not be installed, phrased so the person can act on it.
///
/// A failed download used to surface as the system's description of a private error type, or as
/// nothing at all beside a retry button. Each case here names a cause the user can do something
/// about.
public enum ModelInstallationFailure: Equatable, Sendable {
    case offline
    case insufficientDiskSpace(requiredBytes: Int64)
    case serverRefused(statusCode: Int)
    case damagedDownload
    case unavailable

    /// Separates "there is no network" from every other transport failure.
    public init(networkError: URLError) {
        switch networkError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        default:
            self = .unavailable
        }
    }

    /// The sentence shown beside the retry button.
    public func message(french: Bool) -> String {
        switch self {
        case .offline:
            french
                ? "Pas de connexion Internet. Vérifie le réseau, puis réessaie : le téléchargement reprend où il s’est arrêté."
                : "No internet connection. Check the network, then retry: the download resumes where it stopped."
        case .insufficientDiskSpace(let requiredBytes):
            french
                ? "Espace disque insuffisant. Libère au moins \(Self.amount(requiredBytes)), puis réessaie."
                : "Not enough disk space. Free at least \(Self.amount(requiredBytes)), then retry."
        case .serverRefused(let statusCode):
            french
                ? "Le serveur des modèles a refusé la demande (erreur \(statusCode)). Réessaie dans quelques minutes."
                : "The model server refused the request (error \(statusCode)). Retry in a few minutes."
        case .damagedDownload:
            french
                ? "Le fichier reçu est incomplet ou altéré. Réessaie : il sera téléchargé à nouveau."
                : "The downloaded file is incomplete or damaged. Retry: it will be downloaded again."
        case .unavailable:
            french
                ? "L’installation a échoué. Réessaie ; si cela se répète, signale-le depuis Réglages › À propos."
                : "Installation failed. Retry; if it keeps happening, report it from Settings › About."
        }
    }

    private static func amount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
