import SwiftUI

// MARK: - Copilot teleprompter view (embedded in NotesWindow)

struct CopilotView: View {
    @ObservedObject var bridge: CopilotBridge

    private static let langOptions = [("zh", "中文"), ("en", "English")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(bridge.modeLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(bridge.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !bridge.questionType.isEmpty {
                    Text(bridge.questionType)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                Spacer()

                if bridge.isCopilotActive {
                    langPickers
                }

                if bridge.isCopilotActive, !bridge.storyBanks.isEmpty {
                    bankIndicator
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !bridge.lastQuestionOriginal.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bridge.lastQuestionOriginal)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                if !bridge.lastQuestionTranslated.isEmpty,
                                   bridge.lastQuestionTranslated != bridge.lastQuestionOriginal {
                                    Text(bridge.lastQuestionTranslated)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
                        }

                        Text(displayText)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !bridge.suggestionTranslated.isEmpty {
                            Divider()
                            Text(bridge.suggestionTranslated)
                                .font(.system(size: 14, weight: .regular))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .id("bottom")
                }
                .onChange(of: bridge.streamingText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: bridge.suggestionTranslated) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .padding(20)
    }

    private var displayText: String {
        if !bridge.streamingText.isEmpty { return bridge.streamingText }
        if !bridge.suggestion.isEmpty { return bridge.suggestion }
        return L("等待提问…")
    }

    private var langPickers: some View {
        HStack(spacing: 2) {
            Picker("", selection: $bridge.suggestionLang) {
                ForEach(Self.langOptions, id: \.0) { code, label in
                    Text(label).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)

            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

            Picker("", selection: $bridge.outputLang) {
                ForEach(Self.langOptions, id: \.0) { code, label in
                    Text(label).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var bankIndicator: some View {
        HStack(spacing: 4) {
            if bridge.storyBanks.count > 1 {
                Picker("", selection: $bridge.selectedBankId) {
                    ForEach(bridge.storyBanks) { bank in
                        Text(bank.name).tag(Optional(bank.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Toggle(isOn: $bridge.storyBankEnabled) {
                HStack(spacing: 3) {
                    Image(systemName: bridge.storyBankEnabled ? "book.fill" : "book.closed")
                        .font(.system(size: 10))
                    Text(bridge.storyBankEnabled ? L("故事库") : L("无故事库"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(bridge.storyBankEnabled ? .orange : .secondary)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch bridge.mode {
        case .interview, .research:
            if !bridge.streamingText.isEmpty { return .orange }
            if !bridge.suggestion.isEmpty { return .green }
            return .blue
        case .meeting:
            return .gray
        }
    }
}
