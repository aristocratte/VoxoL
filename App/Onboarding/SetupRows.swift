import SwiftUI

struct PermissionSetupRow: View {
    @Environment(VoxoLTheme.self) private var theme

    let permission: VoxoLPermission
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let coordinator: PermissionCoordinator

    var body: some View {
        VoxoLCard {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(theme.ink)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
                action
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch coordinator.status(for: permission) {
        case .granted:
            StatusPill(title: "Allowed", symbol: "checkmark", tone: theme.success)
        case .requesting:
            if permission == .microphone {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 74)
            } else {
                Button("Open Settings") {
                    coordinator.openSystemSettings(for: permission)
                }
                .buttonStyle(VoxoLSecondaryButtonStyle())
            }
        case .notRequested:
            Button("Allow") {
                Task {
                    await coordinator.request(permission)
                }
            }
            .buttonStyle(VoxoLSecondaryButtonStyle())
        case .denied:
            Button("Open Settings") {
                coordinator.openSystemSettings(for: permission)
            }
            .buttonStyle(VoxoLSecondaryButtonStyle())
        case .restricted:
            StatusPill(title: "Unavailable", symbol: "exclamationmark.triangle")
        }
    }
}

struct ModelInstallationRow: View {
    @Environment(VoxoLTheme.self) private var theme

    let item: ModelInstallationItem
    let store: ModelInstallationStore

    var body: some View {
        VoxoLCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: item.model.role == .asr ? "waveform" : "text.alignleft")
                        .font(.title3)
                        .foregroundStyle(theme.ink)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(modelName)
                            .font(.headline)
                        Text(roleName)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryInk)
                    }

                    Spacer(minLength: 12)
                    phaseAction
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Official source")
                        Text("·")
                        Link(destination: sourceURL) {
                            Text(item.model.repository)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("·")
                        Text(String(item.model.revision.prefix(8)))
                            .font(.caption.monospaced())
                    }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)

                    if let provider = item.model.artifact.provider,
                        let providerURL = URL(string: provider.sourceURL)
                    {
                        HStack(spacing: 8) {
                            Text("Artifact")
                            Text("·")
                            Link(destination: providerURL) {
                                Text(provider.repository)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("·")
                            Text(String(provider.revision.prefix(8)))
                                .font(.caption.monospaced())
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                    }
                }

                phaseDetail
            }
        }
    }

    @ViewBuilder
    private var phaseAction: some View {
        switch item.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .awaitingVerifiedArtifact:
            Button("Download") {}
                .buttonStyle(VoxoLSecondaryButtonStyle())
                .disabled(true)
        case .readyToDownload:
            Button("Download") {
                store.install(item.id)
            }
            .buttonStyle(VoxoLPrimaryButtonStyle())
        case .downloading:
            Button("Pause") {
                store.pause(item.id)
            }
            .buttonStyle(VoxoLSecondaryButtonStyle())
        case .paused:
            Button("Resume") {
                store.install(item.id)
            }
            .buttonStyle(VoxoLPrimaryButtonStyle())
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case .installed:
            StatusPill(title: "Installed", symbol: "checkmark", tone: theme.success)
        case .failed:
            Button("Retry") {
                store.install(item.id)
            }
            .buttonStyle(VoxoLSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var phaseDetail: some View {
        switch item.phase {
        case .awaitingVerifiedArtifact:
            Label(
                "Verified runtime build not published yet",
                systemImage: "shippingbox.and.arrow.backward"
            )
            .font(.caption)
            .foregroundStyle(theme.warning)
        case .downloading:
            downloadProgress
        case .paused:
            VStack(alignment: .leading, spacing: 7) {
                downloadProgress
                Label("Paused · progress saved locally", systemImage: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Verifying SHA-256…")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
        case .failed:
            Label("Download or verification failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(theme.recording)
        case .readyToDownload:
            HStack(spacing: 5) {
                Text(verbatim: totalSize)
                Text("·")
                Text(verbatim: item.model.license)
                Text(verbatim: "· Hugging Face")
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
        case .installed:
            Text("Checksum and local artifact validation passed")
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
        case .loading:
            EmptyView()
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
            HStack {
                Text(byteProgress)
                Spacer()
                Text("\(Int(item.progress * 100))%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
        }
    }

    private var modelName: String {
        item.model.role == .asr ? "Parakeet TDT 0.6B v3" : "Qwen3.5-0.8B"
    }

    private var roleName: LocalizedStringKey {
        item.model.role == .asr ? "Speech recognition" : "Faithful cleanup"
    }

    private var sourceURL: URL {
        URL(string: item.model.sourceURL) ?? URL(fileURLWithPath: "/")
    }

    private var byteProgress: String {
        "\(formatted(item.downloadedBytes)) of \(formatted(item.totalBytes))"
    }

    private var totalSize: String {
        item.totalBytes > 0 ? formatted(item.totalBytes) : "Size published with verified artifact"
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Setup rows") {
    VStack(spacing: 14) {
        PermissionSetupRow(
            permission: .microphone,
            symbol: "mic",
            title: "Microphone",
            detail: "Hear the words you choose to dictate",
            coordinator: PermissionCoordinator()
        )
    }
    .padding(30)
    .frame(width: 620)
    .environment(VoxoLTheme())
}
