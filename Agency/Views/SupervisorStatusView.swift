import SwiftUI

/// Displays the current supervisor status with controls for start/stop/pause.
struct SupervisorStatusView: View {
    let supervisor: AgentSupervisor
    let projectRoot: URL?

    @State private var isLoading = false

    private var coordinator: SupervisorCoordinator {
        supervisor.coordinator
    }

    private var status: SupervisorStatus {
        coordinator.status
    }

    private var snapshot: SupervisorStatusSnapshot {
        coordinator.getStatusSnapshot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            statusHeader

            if status != .stopped {
                statusDetails
            }

            controlButtons
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            statusIndicator

            VStack(alignment: .leading, spacing: 2) {
                Text("Background Processing")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                Text(statusLabel)
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(statusColor)
            }

            Spacer()
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay {
                if status == .running {
                    Circle()
                        .stroke(statusColor.opacity(0.4), lineWidth: 2)
                        .scaleEffect(1.5)
                }
            }
    }

    private var statusLabel: String {
        switch status {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        }
    }

    private var statusColor: Color {
        switch status {
        case .stopped:
            return DesignTokens.Colors.textMuted
        case .starting:
            return .orange
        case .running:
            return .green
        case .paused:
            return .yellow
        }
    }

    // MARK: - Status Details

    private var statusDetails: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            detailPill(
                icon: "bolt.fill",
                value: "\(snapshot.activeRunCount)",
                label: "Active"
            )

            detailPill(
                icon: "tray.full.fill",
                value: "\(snapshot.queuedCardCount)",
                label: "Queued"
            )
        }
        .padding(.leading, 18) // Align with status text
    }

    private func detailPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(DesignTokens.Typography.caption.bold())
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignTokens.Colors.surface))
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            switch status {
            case .stopped:
                startButton

            case .starting:
                ProgressView()
                    .scaleEffect(0.7)

            case .running:
                pauseButton
                stopButton

            case .paused:
                resumeButton
                stopButton
            }
        }
        .padding(.leading, 18) // Align with status text
    }

    private var startButton: some View {
        Button {
            guard let projectRoot else { return }
            isLoading = true
            Task {
                await supervisor.startCoordinator(projectRoot: projectRoot)
                await MainActor.run {
                    isLoading = false
                }
            }
        } label: {
            Label("Start", systemImage: "play.fill")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(projectRoot == nil || isLoading)
    }

    private var pauseButton: some View {
        Button {
            supervisor.pauseCoordinator()
        } label: {
            Label("Pause", systemImage: "pause.fill")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var resumeButton: some View {
        Button {
            Task {
                await supervisor.resumeCoordinator()
            }
        } label: {
            Label("Resume", systemImage: "play.fill")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var stopButton: some View {
        Button {
            isLoading = true
            Task {
                await supervisor.stopCoordinator()
                await MainActor.run {
                    isLoading = false
                }
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isLoading)
    }
}

// MARK: - Compact Variant

/// A compact status indicator for use in toolbars or headers.
struct SupervisorStatusIndicator: View {
    let supervisor: AgentSupervisor

    private var status: SupervisorStatus {
        supervisor.coordinator.status
    }

    private var snapshot: SupervisorStatusSnapshot {
        supervisor.coordinator.getStatusSnapshot()
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            if status == .running {
                if snapshot.activeRunCount > 0 {
                    Text("\(snapshot.activeRunCount) running")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                } else if snapshot.queuedCardCount > 0 {
                    Text("\(snapshot.queuedCardCount) queued")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                } else {
                    Text("Idle")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            } else {
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignTokens.Colors.surface.opacity(0.8)))
    }

    private var statusLabel: String {
        switch status {
        case .stopped: return "Off"
        case .starting: return "Starting"
        case .running: return "On"
        case .paused: return "Paused"
        }
    }

    private var statusColor: Color {
        switch status {
        case .stopped: return DesignTokens.Colors.textMuted
        case .starting: return .orange
        case .running: return .green
        case .paused: return .yellow
        }
    }
}

#Preview("Full View - Stopped") {
    SupervisorStatusView(
        supervisor: .shared,
        projectRoot: URL(fileURLWithPath: "/tmp/test")
    )
    .padding()
    .frame(width: 280)
}

#Preview("Full View - Running") {
    SupervisorStatusView(
        supervisor: .shared,
        projectRoot: URL(fileURLWithPath: "/tmp/test")
    )
    .padding()
    .frame(width: 280)
}

#Preview("Compact Indicator") {
    SupervisorStatusIndicator(supervisor: .shared)
        .padding()
}
