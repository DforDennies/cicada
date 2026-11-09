import Foundation

// MARK: - Copilot Bridge
// Connects Cicada's ListenEngine to the Copilot engine.
// Modes: .meeting (original Cicada), .interview (job interview), .research (user research/訪談).
// Teleprompter only: suggestions display on screen, user speaks via right-⌥ talk key.

@MainActor
final class CopilotBridge: ObservableObject {
    enum Mode: String { case meeting, interview, research }

    struct StoryBank: Identifiable {
        let id: String
        let name: String
        let stories: String
        let knowledgeProfile: String
        let jobDescription: String
        let path: URL

        static func load(from directory: URL, name: String? = nil) -> StoryBank? {
            let stories = (try? String(contentsOf: directory.appendingPathComponent("stories-full.txt"), encoding: .utf8)) ?? ""
            guard !stories.isEmpty else { return nil }
            let knowledge = (try? String(contentsOf: directory.appendingPathComponent("knowledge-profile.txt"), encoding: .utf8)) ?? ""
            let jd = (try? String(contentsOf: directory.appendingPathComponent("default-jd.txt"), encoding: .utf8)) ?? ""
            let bankName = name ?? directory.lastPathComponent
            return StoryBank(id: bankName, name: bankName, stories: stories, knowledgeProfile: knowledge, jobDescription: jd, path: directory)
        }
    }

    @Published private(set) var mode: Mode = .meeting
    private(set) var copilot: CopilotEngine?

    @Published var autoSpeak = false

    @Published var lastQuestionOriginal = ""
    @Published var lastQuestionTranslated = ""

    @Published var suggestion = ""
    @Published var suggestionTranslated = ""
    @Published var questionType = ""
    @Published var status = "待命"
    @Published var streamingText = ""

    private(set) var storyBanks: [StoryBank] = []
    @Published var selectedBankId: String?
    @Published var storyBankEnabled = true

    @Published var suggestionLang = "zh"
    @Published var outputLang = "en"

    var displayLangs: (primary: String, secondary: String) {
        (suggestionLang, outputLang)
    }

    var selectedBank: StoryBank? {
        guard storyBankEnabled else { return nil }
        guard let id = selectedBankId else { return storyBanks.first }
        return storyBanks.first { $0.id == id } ?? storyBanks.first
    }

    // speakText removed: user speaks via right-⌥ talk key, not AI TTS

    private var silenceTimer: Timer?
    private let silenceDelay: TimeInterval = 0.8
    private var pendingQuestion = ""

    var isCopilotActive: Bool { mode == .interview || mode == .research }

    var modeLabel: String {
        switch mode {
        case .meeting: return L("会议")
        case .interview: return L("面试")
        case .research: return L("访谈")
        }
    }

    init() {
        loadDefaultStoryBanks()
    }

    // MARK: - Story Bank Management

    private static let defaultDataPaths: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appendingPathComponent("interview-copilot/data"),
        ]
        // Also search repo-bundled data next to the executable
        if let execURL = Bundle.main.executableURL {
            let repoData = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("data/copilot")
            paths.append(repoData)
        }
        return paths
    }()

    func loadDefaultStoryBanks() {
        var banks: [StoryBank] = []
        for dir in Self.defaultDataPaths {
            if let bank = StoryBank.load(from: dir, name: "default") {
                banks.append(bank)
                debugLog("copilot: loaded story bank '\(bank.name)' from \(dir.path) (stories=\(bank.stories.count)ch, knowledge=\(bank.knowledgeProfile.count)ch, jd=\(bank.jobDescription.count)ch)")
            }
        }
        storyBanks = banks
        if selectedBankId == nil, let first = banks.first {
            selectedBankId = first.id
        }
    }

    func addStoryBank(from directory: URL, name: String? = nil) -> Bool {
        guard let bank = StoryBank.load(from: directory, name: name) else { return false }
        storyBanks.removeAll { $0.id == bank.id }
        storyBanks.append(bank)
        debugLog("copilot: added story bank '\(bank.name)'")
        return true
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        if mode == .meeting {
            copilot?.stop()
            copilot = nil
            suggestion = ""
            status = L("会议模式")
        }
    }

    func startCopilot(
        mode: Mode,
        resume: String = "",
        jobDescription: String = "",
        stories: String = "",
        knowledgeProfile: String = "",
        researchGoal: String = "",
        bankId: String? = nil
    ) {
        self.mode = mode

        var effectiveStories = stories
        var effectiveKnowledge = knowledgeProfile
        var effectiveJD = jobDescription

        if mode == .interview, effectiveStories.isEmpty {
            if let id = bankId { selectedBankId = id }
            if let bank = selectedBank {
                effectiveStories = bank.stories
                if effectiveKnowledge.isEmpty { effectiveKnowledge = bank.knowledgeProfile }
                if effectiveJD.isEmpty { effectiveJD = bank.jobDescription }
                debugLog("copilot: using story bank '\(bank.name)' (\(bank.stories.count)ch stories)")
            }
        }

        let engine = CopilotEngine(
            mode: mode == .research ? .research : .interview,
            resume: resume,
            jobDescription: effectiveJD,
            stories: effectiveStories,
            knowledgeProfile: effectiveKnowledge,
            researchGoal: researchGoal,
            suggestionLang: suggestionLang
        )
        engine.onSuggestion = { [weak self] text, type in
            guard let self else { return }
            self.suggestion = text
            self.suggestionTranslated = ""
            self.questionType = type
            self.status = L("待命")
            if !text.isEmpty && !text.hasPrefix("⚠️") {
                let needsTranslate = self.suggestionLang != self.outputLang
                if needsTranslate {
                    Task {
                        let translated = (try? await GoogleTranslator.translate(text, source: self.suggestionLang, target: self.outputLang)) ?? text
                        self.suggestionTranslated = translated
                        debugLog("copilot: translated \(self.suggestionLang)→\(self.outputLang) (\(translated.count)ch)")
                    }
                }
            }
        }
        engine.onStreaming = { [weak self] chunk in
            self?.streamingText += chunk
        }
        engine.onStatus = { [weak self] s in
            self?.status = s
        }
        engine.start()
        copilot = engine
        status = mode == .research ? L("访谈模式 · 待命") : L("面试模式 · 待命")
    }

    func stopCopilot() {
        copilot?.stop()
        copilot = nil
        mode = .meeting
        suggestion = ""
        streamingText = ""
        status = L("已停止")
        silenceTimer?.invalidate()
    }

    // MARK: - ListenEngine hooks

    func heardFinal(_ segment: Segment) {
        guard isCopilotActive, let copilot else { return }

        let text = segment.translation ?? segment.text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        lastQuestionOriginal = (lastQuestionOriginal.isEmpty ? "" : lastQuestionOriginal + " ") + segment.text
        if let t = segment.translation {
            lastQuestionTranslated = (lastQuestionTranslated.isEmpty ? "" : lastQuestionTranslated + " ") + t
        }

        debugLog("copilot: heardFinal \(text.prefix(60))")
        pendingQuestion += (pendingQuestion.isEmpty ? "" : " ") + text
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let copilot = self.copilot else { return }
                let question = self.pendingQuestion
                self.pendingQuestion = ""
                self.streamingText = ""
                self.suggestion = ""
                self.suggestionTranslated = ""
                debugLog("copilot: silence debounce fired, sending to engine: \(question.prefix(80))")
                copilot.onInterviewerDone(question)
            }
        }
    }

    func heardMyVoice(_ text: String) {
        guard isCopilotActive, let copilot else { return }
        copilot.addTranscript(speaker: "me", text: text)
    }
}
