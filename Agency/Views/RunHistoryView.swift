import SwiftUI

/// Displays run history with filtering and aggregate metrics.
struct RunHistoryView: View {
    @State private var records: [CompletedRunRecord] = []
    @State private var metrics: RunHistoryMetrics = .empty
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Filters
    @State private var selectedStatus: WorkerRunResult.Status?
    @State private var selectedFlow: String?
    @State private var searchText = ""
    @State private var dateRange: DateRange = .allTime

    enum DateRange: String, CaseIterable {
        case today = "Today"
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case allTime = "All Time"

        var startDate: Date? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .today:
                return calendar.startOfDay(for: now)
            case .week:
                return calendar.date(byAdding: .day, value: -7, to: now)
            case .month:
                return calendar.date(byAdding: .day, value: -30, to: now)
            case .allTime:
                return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            metricsHeader

            Divider()

            filterBar

            Divider()

            if isLoading {
                ProgressView("Loading history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Error Loading History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if records.isEmpty {
                ContentUnavailableView {
                    Label("No Run History", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Completed agent runs will appear here.")
                }
            } else {
                recordsList
            }
        }
        .task {
            await loadData()
        }
        .onChange(of: selectedStatus) { _, _ in Task { await loadData() } }
        .onChange(of: selectedFlow) { _, _ in Task { await loadData() } }
        .onChange(of: searchText) { _, _ in Task { await loadData() } }
        .onChange(of: dateRange) { _, _ in Task { await loadData() } }
    }

    // MARK: - Metrics Header

    private var metricsHeader: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            metricCard(
                title: "Total Runs",
                value: "\(metrics.totalRuns)",
                icon: "number",
                color: .blue
            )

            metricCard(
                title: "Success Rate",
                value: String(format: "%.0f%%", metrics.successRate * 100),
                icon: "checkmark.circle",
                color: .green
            )

            metricCard(
                title: "Avg Duration",
                value: formatDuration(metrics.averageDuration),
                icon: "clock",
                color: .orange
            )

            metricCard(
                title: "Data Processed",
                value: formatBytes(metrics.totalBytesRead + metrics.totalBytesWritten),
                icon: "arrow.left.arrow.right",
                color: .purple
            )
        }
        .padding()
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: DesignTokens.Spacing.xSmall) {
            HStack(spacing: DesignTokens.Spacing.xSmall) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Text(value)
                .font(DesignTokens.Typography.title.monospacedDigit())
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium).fill(DesignTokens.Colors.surface))
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignTokens.Colors.textMuted)
                TextField("Search cards...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, DesignTokens.Spacing.small)
            .padding(.vertical, DesignTokens.Spacing.xSmall)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).fill(DesignTokens.Colors.surface))
            .frame(maxWidth: 200)

            // Date Range
            Picker("Date", selection: $dateRange) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)

            // Status Filter
            Picker("Status", selection: $selectedStatus) {
                Text("All Statuses").tag(nil as WorkerRunResult.Status?)
                Divider()
                Text("Succeeded").tag(WorkerRunResult.Status.succeeded as WorkerRunResult.Status?)
                Text("Failed").tag(WorkerRunResult.Status.failed as WorkerRunResult.Status?)
                Text("Canceled").tag(WorkerRunResult.Status.canceled as WorkerRunResult.Status?)
            }
            .pickerStyle(.menu)

            // Flow Filter
            Picker("Flow", selection: $selectedFlow) {
                Text("All Flows").tag(nil as String?)
                Divider()
                ForEach(AgentFlow.allCases) { flow in
                    Text(flow.label).tag(flow.rawValue as String?)
                }
            }
            .pickerStyle(.menu)

            Spacer()

            Button {
                Task { await loadData() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Records List

    private var recordsList: some View {
        List(records) { record in
            RunRecordRow(record: record)
        }
        .listStyle(.plain)
    }

    // MARK: - Helpers

    private func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            let filter = RunHistoryFilter(
                startDate: dateRange.startDate,
                flow: selectedFlow,
                status: selectedStatus,
                cardPathContains: searchText.isEmpty ? nil : searchText
            )

            records = try RunHistoryStore.shared.records(filter: filter)
            metrics = try RunHistoryStore.shared.metrics(filter: filter)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Run Record Row

private struct RunRecordRow: View {
    let record: CompletedRunRecord

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            statusIndicator

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                HStack {
                    Text(cardName)
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    if let pipeline = record.pipeline {
                        Text(pipeline)
                            .font(DesignTokens.Typography.caption)
                            .padding(.horizontal, DesignTokens.Spacing.xSmall)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignTokens.Colors.surface))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }

                HStack(spacing: DesignTokens.Spacing.small) {
                    Label(record.flow.capitalized, systemImage: "bolt.horizontal")
                    Label(formatDuration(record.duration), systemImage: "clock")
                    Label(formatBytes(record.bytesRead), systemImage: "arrow.down.doc")
                    Label(formatBytes(record.bytesWritten), systemImage: "arrow.up.doc")
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xSmall) {
                Text(record.completedAt, style: .relative)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textMuted)

                Text("Exit \(record.exitCode)")
                    .font(DesignTokens.Typography.caption.monospacedDigit())
                    .foregroundStyle(record.exitCode == 0 ? DesignTokens.Colors.textMuted : .red)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xSmall)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch record.status {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .orange
        }
    }

    private var cardName: String {
        if let title = record.cardTitle, !title.isEmpty {
            return title
        }
        // Extract filename from path
        return URL(fileURLWithPath: record.cardPath).deletingPathExtension().lastPathComponent
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    RunHistoryView()
        .frame(width: 800, height: 600)
}
