import SwiftUI

/// Settings view for configuring background supervisor behavior.
struct SupervisorSettingsView: View {
    @State private var settings = SupervisorSettings.shared

    var body: some View {
        Form {
            Section {
                autoStartToggle
            } header: {
                Text("Startup")
            } footer: {
                Text("When enabled, the supervisor starts automatically when you open a project.")
            }

            Section {
                concurrencyPicker
            } header: {
                Text("Concurrency")
            } footer: {
                Text("Higher concurrency processes more cards in parallel but uses more system resources.")
            }

            Section {
                pipelinePicker
            } header: {
                Text("Default Pipeline")
            } footer: {
                Text("The pipeline determines which agent flows run for each card.")
            }

            Section {
                autoMoveToggle
            } header: {
                Text("Automation")
            } footer: {
                Text("Automatically move cards to Done when their pipeline completes successfully.")
            }

            Section {
                resetButton
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Startup

    @ViewBuilder
    private var autoStartToggle: some View {
        Toggle(isOn: $settings.autoStart) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-start supervisor")
                    .font(.body)
                Text("Start background processing when a project opens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - Concurrency

    @ViewBuilder
    private var concurrencyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Max concurrent runs")
                Spacer()
                Text("\(settings.maxConcurrent)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(settings.maxConcurrent) },
                    set: { settings.maxConcurrent = Int($0) }
                ),
                in: 1...4,
                step: 1
            ) {
                Text("Max concurrent runs")
            } minimumValueLabel: {
                Text("1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("4")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                concurrencyOption(1, label: "Conservative")
                concurrencyOption(2, label: "Balanced")
                concurrencyOption(3, label: "Parallel")
                concurrencyOption(4, label: "Maximum")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func concurrencyOption(_ value: Int, label: String) -> some View {
        Button {
            settings.maxConcurrent = value
        } label: {
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.headline)
                    .foregroundStyle(settings.maxConcurrent == value ? .primary : .secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(settings.maxConcurrent == value ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(settings.maxConcurrent == value ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pipeline

    @ViewBuilder
    private var pipelinePicker: some View {
        Picker("Default pipeline", selection: $settings.defaultPipeline) {
            ForEach(FlowPipeline.allCases, id: \.self) { pipeline in
                VStack(alignment: .leading) {
                    Text(pipeline.displayName)
                    Text(pipelineDescription(pipeline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(pipeline)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private func pipelineDescription(_ pipeline: FlowPipeline) -> String {
        switch pipeline {
        case .implementOnly:
            return "Run implement flow only"
        case .implementThenReview:
            return "Implement, then review changes"
        case .researchThenImplement:
            return "Research context, then implement"
        case .fullPipeline:
            return "Research, plan, implement, then review"
        }
    }

    // MARK: - Automation

    @ViewBuilder
    private var autoMoveToggle: some View {
        Toggle(isOn: $settings.autoMoveToStatus) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-move completed cards")
                    .font(.body)
                Text("Move cards to Done when pipeline succeeds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - Reset

    @ViewBuilder
    private var resetButton: some View {
        Button("Reset to Defaults") {
            settings.resetToDefaults()
        }
        .foregroundStyle(.secondary)
    }
}

#Preview {
    SupervisorSettingsView()
        .frame(width: 500, height: 600)
}
