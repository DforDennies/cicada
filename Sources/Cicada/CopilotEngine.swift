import Foundation

// MARK: - Copilot Engine
// Gemini-powered copilot that plugs into Cicada's ListenEngine.
// Two engine modes: .interview (job interview) and .research (user research/訪談).

@MainActor
final class CopilotEngine {
    enum EngineMode { case interview, research }

    var onSuggestion: ((_ text: String, _ questionType: String) -> Void)?
    var onStreaming: ((_ chunk: String) -> Void)?
    var onStatus: ((_ status: String) -> Void)?

    private(set) var isActive = false
    let engineMode: EngineMode
    private var transcript: [(speaker: String, text: String, at: Date)] = []
    private var currentTask: Task<Void, Never>?

    private let stories: String
    private let resume: String
    private let jobDescription: String
    private let knowledgeProfile: String
    private let researchGoal: String
    let suggestionLang: String
    var autoSpeak = false

    static let maxTranscriptTurns = 20

    init(
        mode: EngineMode = .interview,
        resume: String,
        jobDescription: String,
        stories: String,
        knowledgeProfile: String,
        researchGoal: String = "",
        suggestionLang: String = "zh"
    ) {
        self.engineMode = mode
        self.resume = resume
        self.jobDescription = jobDescription
        self.stories = stories
        self.knowledgeProfile = knowledgeProfile
        self.researchGoal = researchGoal
        self.suggestionLang = suggestionLang
    }

    func start() {
        isActive = true
        transcript = []
        onStatus?("待命")
    }

    func stop() {
        isActive = false
        currentTask?.cancel()
        currentTask = nil
        onStatus?("已停止")
    }

    func addTranscript(speaker: String, text: String) {
        transcript.append((speaker: speaker, text: text, at: Date()))
    }

    func onInterviewerDone(_ question: String, original: String? = nil) {
        guard isActive, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addTranscript(speaker: "interviewer", text: question)
        debugLog("copilot: onInterviewerDone, question=\(question.prefix(80))")

        currentTask?.cancel()
        currentTask = Task {
            await generateSuggestion(for: question, original: original)
        }
    }

    // MARK: - Question Classification (25 types)

    static func classifyQuestion(_ question: String) -> String {
        let q = question.lowercased()
        let charCount = question.trimmingCharacters(in: .whitespaces).count

        let reactPattern = "^(ok|好|嗯|了解|不錯|有意思|interesting|i see|right|sure|got it|好的|對|cool|nice|hmm|讓我想想|wait|稍等|good|great|wow|了解了解|好的好的)$"
        if charCount < 15, q.trimmingCharacters(in: .whitespaces).range(of: reactPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return "REACT"
        }

        if q.matches("卡住|frozen|lag|斷線|disconnect|reconnect|麥克風|microphone|cut out|audio.*cut|sorry.*connection|抱歉.*網路") { return "TECH_ISSUE" }

        if q.matchesPrefix("好[，,]?那|ok so|alright|接下來|let'?s move|換個話題|換個方向|next[, ]|那我們來|moving on|好接下來|哈哈.*[那好開]"),
           charCount < 50, !q.matches("自我介紹|介紹|tell me|背景|background") { return "TRANSITION" }

        if q.matches("^(hi|hello|hey|嗨|你好|哈囉)|ready|準備好|can you hear|聽得到|nice to meet|開始吧|we can start|shall we|thanks for (coming|joining)|謝謝你來|先閒聊|welcome|祝你.*順利|good luck|it was nice|很高興認識") { return "GREETING" }

        if q.matches("再說一次|say.*again|elaborate|展開|具體.*一點|more detail|多說.*一點|什麼意思|what do you mean|can you clarify|沒聽太清|repeat|多解釋|rephrase") { return "CLARIFY" }

        if q.matches("married|結婚|小孩|kids|children|懷孕|pregnant|年齡|how old|幾歲|宗教|religion|政治|政黨|性別|gender|sexual|殘障|disability") { return "PERSONAL" }

        if q.matches("hobby|興趣|平常.*做什麼|weekend|假日|天氣|weather|coffee|咖啡|lunch|吃飯|從哪裡來|哪裡人|where.*from|\\bpets?\\b|寵物|\\btravel\\b|旅行|fun fact|休息.*喝|喝.*水|怎麼接觸|背景.*故事|純好奇") { return "CASUAL" }

        if q.matches("tell me about yourself|自我介紹|介紹一下|walk.*through.*background|your background") { return "INTRO" }

        if q.matches("sell me|賣給我|賣.*筆|如果你是.*動物|animal.*would|superpower|超能力|one word.*describe|三個字形容|desert island|荒島|teach me") { return "CURVEBALL" }

        if q.matches("不太同意|i disagree|doesn'?t sound right|不太對|not (convinced|sure)|沒有說服我|那如果.*失敗|devil'?s advocate|push back|but what if.*wrong|聽起來.*理想化|too optimistic|真的嗎") { return "PUSHBACK" }

        if q.matches("how many|多少個|estimate|估算|市場.*大小|market size|how would you size|你猜|量化.*規模") { return "ESTIMATION" }

        if q.matches("如果你是.*(ceo|cto|cpo)|if you (were|had|could)|假設|imagine|unlimited|無限|what would.*change|你會怎麼重新|if.*from scratch|從頭來過|重新來過") { return "HYPOTHETICAL" }

        if q.matches("when.*start|何時.*到職|到職日|notice period|離職|other offer|其他.*offer|面試.*進度|timeline|availability|available|幾時.*上班") { return "TIMELINE" }

        if q.matches("最後.*補充|anything.*add|final thought|還有什麼.*說|wrap up|總結一下|closing|last thing") { return "CLOSING" }

        if q.matches("why.*(company|role|this|leave)|為什麼.*(公司|職位|想來|離開)") { return "MOTIVATION" }

        if q.matches("how.*handle|conflict|challenge|difficult|tell me.*time|describe.*(time|situation|experience)|give.*(me )?an example|walk me through|請.*舉例|遇到.*怎麼|衝突|挑戰|trade-off|從零|0.?to.?1|出問題|出包|biggest (failure|mistake)|最大.*失敗|搞砸|學到.*重要|最重要.*一件事|違反直覺|convince|persuade|disagree") { return "BEHAVIORAL" }

        if q.matches("stakeholder|加 ai|priorit|cpo|resource|data scientist|資源.*排|排.*優先|product.*you admire|career coach|tutor.*功能|rule engine|需不需要.*ai|用戶.*覺得|how would you (improve|prioritize|launch)|product.*strategy|user.*research|feature.*roadmap|go.?to.?market") { return "PRODUCT_SENSE" }

        if q.matches("fairness|bias|privacy|ethics|負責任|族群.*表現") { return "RESPONSIBLE_AI" }

        if q.matches("metric|north.?star|衡量|指標|engagement.*上升|engagement.*下降|measure.*rag|rag.*work") { return "METRICS" }

        if q.matches("system.*design|design.*(system|架構|guardrail)|architect|implement|設計.*系統|實作|怎麼做|hallucination|亂講|亂回|rag|fine.?tun|eval.*harness|guardrail|prd|unit economics|inference|cost per|架構.*設計|trained model|how would you (build|approach|implement|scale)|technical.*decision|algorithm|data.*pipeline|api.*design|microservice") { return "TECHNICAL" }

        if q.matches("salary|compensation|期望薪資|薪水") { return "NEGOTIATION" }
        if q.matches("weakness|strength|優點|缺點") { return "SELF_ASSESS" }
        if q.matches("question.*for (us|me)|你有.*問題|想問|any question|最後.*問") { return "REVERSE" }
        if q.matches("design|build|設計|怎麼決定|怎麼寫") { return "TECHNICAL" }

        return "GENERAL"
    }

    // MARK: - Trackers

    private var usedOpenings: [String] {
        var openings: [String] = []
        for t in transcript where t.speaker == "me" && t.text.count >= 5 {
            let first = t.text.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: CharacterSet(charactersIn: "，,。.\n")).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if first.count >= 2 && first.count <= 15 { openings.append(first) }
        }
        return Array(Set(openings))
    }

    private static let trackableConcepts = [
        "LLM-as-a-Judge", "LLM as a Judge", "Fallback", "LangFuse", "Langfuse",
        "MCP", "Mem0", "A/B", "NLPFactory", "Experiment Manager",
        "Supervisor", "Multi-Agent", "多智能體", "品質閘門", "蒸餾",
        "Confidence Score", "STAR",
    ]

    private var overusedConcepts: [String] {
        let fullText = transcript.filter { $0.speaker == "me" }.map(\.text).joined(separator: " ")
        var result: [String] = []
        for concept in Self.trackableConcepts {
            let escaped = NSRegularExpression.escapedPattern(for: concept)
            let regex = try? NSRegularExpression(pattern: escaped, options: .caseInsensitive)
            let count = regex?.numberOfMatches(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) ?? 0
            if count >= 2 { result.append("\(concept)(\(count)次)") }
        }
        return result
    }

    private static let storyMarkers = [
        "KOL Palette", "雷達之星", "MCN", "TextLangID", "TextSponsor", "TextAction",
        "General Tag", "Hermes", "Similar KOL", "NLPFactory", "Sales Pipeline",
        "Amplitude Dashboard", "數據湖", "Trino", "Iceberg", "StarRocks",
        "Weekly Sync", "壽險", "產險", "ChatGPT Enterprise", "AI 治理",
        "客戶零流失", "裁員", "62 起", "生產事故", "SaaS 定價",
        "五大模組", "客戶流失預警", "八層數據",
    ]

    private var activeStory: String? {
        for t in transcript.reversed() {
            guard t.speaker == "me" else { continue }
            for marker in Self.storyMarkers {
                if t.text.contains(marker) { return marker }
            }
            break
        }
        return nil
    }

    // MARK: - Prompt Building

    private func typeInstruction(for type: String) -> String {
        switch type {
        case "REACT": return "面試官只是在回應或評論，不是在問問題。不需要回應，輸出空字串或最多一個「嗯」就好。不要主動延伸。"
        case "GREETING": return "面試官在打招呼或寒暄。回一句自然的招呼就好，像「嗨你好，可以聽到，準備好了」。不要超過 30 字。不要直接跳到自我介紹，等面試官開題。"
        case "CASUAL": return "這是閒聊或生活話題，不是正式面試問題。輕鬆自然地回答，像朋友聊天。不要超過 50 字。可以帶點幽默。不要硬扯回專業經歷。"
        case "CLARIFY": return "面試官要你補充細節或重新解釋。用不同角度或更具體的例子重新說一次你上一輪的重點。不要重複一樣的話。"
        case "TRANSITION": return "面試官在轉場，還沒問出問題。簡短回應「好的」「沒問題」就好，等他問完再回答。不要超過 15 字。"
        case "INTRO": return "自我介紹。定位→一個亮點成就→連結這個職位。40秒內。"
        case "BEHAVIORAL": return "行為題。從故事庫挑一個最匹配的故事，講：發生什麼事→你做了什麼→結果怎樣。只講行動和結果，不要講「我學到…」。"
        case "TECHNICAL": return "技術題。從知識深度區塊找素材。講你做過的技術選擇，為什麼選 A 不選 B，實際遇到什麼 trade-off。"
        case "PRODUCT_SENSE": return "產品思維題。先釐清問題本質，再用一個你做過的真實案例說明你的判斷。"
        case "METRICS": return "指標分析題。拆解指標之間的關係，提假設，說你會怎麼驗證。用真實專案數字。"
        case "MOTIVATION": return "動機題。你的經歷中哪一段跟這間公司最有共鳴，為什麼。要具體。"
        case "SELF_ASSESS": return "優缺點。缺點選真實但已改善的，附一句你怎麼改的。優點用一個故事帶。"
        case "NEGOTIATION": return "薪資題。先反問預算，給區間，強調你帶來的價值。"
        case "REVERSE": return "反問環節。寫 2 個有深度的問題直接唸出來。問團隊目前最大挑戰、成功怎麼衡量、或產品接下來的方向。不要問 JD 上已經寫的。"
        case "RESPONSIBLE_AI": return "AI 倫理題。承認問題的複雜性，講你實際碰過的案例和做法。"
        case "PUSHBACK": return "面試官在挑戰你的回答。不要防禦或道歉。先認同他觀點裡合理的部分，再用一個具體數據或案例補強你的立場。保持自信但不固執。"
        case "ESTIMATION": return "估算題。先拆解：定範圍→選切入角度→逐步算。每步假設要說出來讓面試官能挑戰。不用算到精確，重點是思路清晰。最後給一個量級。"
        case "HYPOTHETICAL": return "假設情境題。不要回「這要看情況」。直接選一個立場，用你真實經驗中最接近的案例來支撐。講完再提一個你會注意的風險。"
        case "PERSONAL": return "這可能是不適當的私人問題。禮貌但堅定地轉向：「這個我比較私人，不過我可以說的是我對這個角色很有熱情，因為…」導回專業話題。不要真的回答私人細節。不超過 40 字。"
        case "TECH_ISSUE": return "技術問題（網路、音訊、畫面）。簡短確認狀態就好：「嗨，我這邊聽得到/看得到了，沒問題」。不要超過 20 字。不要道歉太多。"
        case "TIMELINE": return "時程/到職相關問題。直接給一個合理的時間（通常 2-4 週 notice period）。如果問其他 offer，可以說「有在看幾個機會，但這邊是我的優先選擇」。不超過 50 字。"
        case "CLOSING": return "面試官在結尾。如果問「還有什麼補充」，挑一個你面試中沒機會講的亮點，用 2 句話帶過。如果只是道別，簡單感謝就好。不超過 60 字。"
        case "CURVEBALL": return "創意/奇怪的問題。展現幽默和思考彈性。先想 2 秒，然後給一個有趣但有邏輯的答案。不要太認真分析。不超過 60 字。"
        default: return "根據問題性質回答。"
        }
    }

    private func buildSystemPrompt(questionType: String) -> String {
        let openings = usedOpenings
        let concepts = overusedConcepts
        let story = activeStory

        // Sliding window: only recent turns go to the model
        let total = transcript.count
        let recentEntries = Array(transcript.suffix(Self.maxTranscriptTurns))
        var transcriptPrefix = ""
        if total > Self.maxTranscriptTurns {
            let older = Array(transcript.prefix(total - Self.maxTranscriptTurns))
            let topics = older.filter { $0.speaker == "interviewer" }
                .map { String($0.text.prefix(30)) }
                .joined(separator: "、")
            transcriptPrefix = "[前面已聊過 \(older.count) 輪，話題包含：\(topics)]\n"
        }
        let transcriptText = transcriptPrefix + recentEntries
            .map { "[\($0.speaker == "interviewer" ? "面試官" : "我")] \($0.text)" }
            .joined(separator: "\n")

        var contextHints = ""
        if !openings.isEmpty {
            contextHints += "\n⛔ 已用過的開頭（禁止再用）：\(openings.joined(separator: "、"))"
        }
        if !concepts.isEmpty {
            contextHints += "\n⛔ 提太多次的詞（換別的說）：\(concepts.joined(separator: "、"))"
        }
        if let story {
            contextHints += "\n🔒 你上一輪在講「\(story)」的故事。如果這題是追問，必須繼續講這個故事的細節，不准跳到別的。"
        }

        let storySection = stories.isEmpty ? "" : """

        ## 故事匹配策略
        你有一個故事庫。回答任何問題時：
        1. 先從故事庫中找標籤或內容最匹配的 1-2 個故事
        2. 用那個故事的具體數據和細節來建構回答
        3. 如果找不到完全匹配的故事，選最接近的，並從簡歷補充
        4. 追問時（follow-up）持續用同一個故事深入，不要跳到別的

        ## 故事庫
        \(stories)
        """

        let knowledgeSection = knowledgeProfile.isEmpty ? "" : "\n## 技術知識深度\n\(knowledgeProfile)"

        let langRule: String
        let wordCap = autoSpeak ? (suggestionLang == "en" ? "Max 25 words" : "最多 35 字") : (suggestionLang == "en" ? "Max 120 words" : "最多 200 字")
        switch suggestionLang {
        case "en":
            langRule = "⚠️ You MUST reply in English only. \(wordCap). Max 15 words per sentence."
        default:
            langRule = "⚠️ 你必須用中文回答。\(wordCap)。每句話不超過 20 個字。"
        }

        let autoSpeakRule = autoSpeak ? """

        ⚠️⚠️ AUTO-SPEAK 模式 — 你的回答會直接用語音合成唸出來，必須極短。
        - \(suggestionLang == "en" ? "HARD LIMIT: 25 words max. 1-2 sentences ONLY." : "硬限制：最多 35 字。只寫 1-2 句話。")
        - 只給核心論點，一句結論。不要鋪陳、不要解釋、不要收尾。
        - 故事只講一個動作和一個結果，不要過程。
        """ : ""

        return """
        你是面試提詞器。你輸出的每個字我會直接唸出來。
        \(autoSpeakRule)
        ## 硬限制
        \(langRule)
        - 絕對禁止列舉：「第一/第二/第三」「首先/其次/最後」「First/Second/Third」「One.../Two...」「第一層/第二層」
        - 絕對禁止學術詞：「結構」「框架」「維度」「層面」「framework」「dimension」
        - 數字只能用故事庫裡有的。沒有原文的數字不准用
        - 不要加任何格式符號\(contextHints)

        ## 口語風格
        - 像資深 PM 在咖啡聊天，不是在做簡報
        - 每次回答的開頭詞都要不同。禁止連續用同一個開頭
        - 中文可選：「對」「嗯」「說到這個」「其實」「像是」「我舉個例子」「這個嘛」「坦白說」「有一次」「剛好」
        - 英文可選：「So」「Right, so」「Actually」「What happened was」「The thing is」「Honestly」「Good question」「Yeah」
        - 句子之間用口語過渡，不要用「另外」「此外」「同時」

        ## 回答策略
        - 一題只用一個故事，不要混用多個案例
        - 追問就繼續挖同一個故事的細節，不准跳到別的故事
        - 只有面試官明確換了新題目，才能換故事
        - 回答到重點就停，不要收尾總結。留空間讓面試官追問
        - 不要說「我從中學到…」「總的來說…」「這讓我體會到…」

        ## 題型：\(typeInstruction(for: questionType))\(autoSpeak ? "\n⚠️ 以上題型策略只是方向。你的輸出必須在 \(suggestionLang == "en" ? "25 words" : "35 字") 以內。如果策略需要多步驟，只做第一步。面試官會追問細節。" : "")

        ## 我的背景
        \(resume)
        \(storySection)
        \(knowledgeSection)
        ## 目標職位
        \(jobDescription)
        \(transcript.isEmpty ? "" : "\n## 對話紀錄\n\(transcriptText)")
        """
    }

    private func buildUserPrompt(question: String) -> String {
        let lastAnswer = transcript.last(where: { $0.speaker == "me" })?.text
        var prompt = "面試官：\(question)"
        if let lastAnswer { prompt += "\n（我上一輪說了：\(lastAnswer)）" }
        return prompt
    }

    // MARK: - Research / 訪談 prompts

    private func buildResearchPrompt() -> String {
        let recentEntries = Array(transcript.suffix(Self.maxTranscriptTurns))
        let transcriptText = recentEntries
            .map { "[\($0.speaker == "me" ? "我" : "受訪者")] \($0.text)" }
            .joined(separator: "\n")

        return """
        你是使用者訪談的即時提詞助手。你輸出的內容我會直接唸出來或作為下一步提問參考。

        ## 硬限制
        - 中文：最多 150 字。英文：最多 100 words
        - 語氣友善、好奇、非引導性
        - 不要加任何格式符號

        ## 訪談原則
        - 多用開放式問題（為什麼/怎麼/可以多說一點嗎）
        - 受訪者講到有趣的點，建議追問而非跳下一題
        - 避免引導性問題（不要暗示「正確答案」）
        - 適時摘要受訪者的回答以確認理解
        - 情緒共感：受訪者表達困擾時先同理再追問

        ## 口語風格
        - 像朋友聊天，不是問卷調查
        - 可選開頭：「嗯嗯」「有意思」「所以你的意思是…」「可以多說一點嗎」「那後來呢」「原來如此」

        \(researchGoal.isEmpty ? "" : "## 訪談目標\n\(researchGoal)\n")
        \(resume.isEmpty ? "" : "## 我的背景\n\(resume)\n")
        \(transcript.isEmpty ? "" : "## 對話紀錄\n\(transcriptText)")
        """
    }

    private func buildResearchUserPrompt(heard: String) -> String {
        let lastSaid = transcript.last(where: { $0.speaker == "me" })?.text
        var prompt = "受訪者：\(heard)"
        if let lastSaid { prompt += "\n（我上一輪問了：\(lastSaid)）" }
        prompt += "\n\n根據以上內容，建議我接下來怎麼回應或追問。"
        return prompt
    }

    // MARK: - Gemini API

    private func generateSuggestion(for question: String, original: String? = nil) async {
        let questionType: String
        let systemPrompt: String
        let userPrompt: String

        switch engineMode {
        case .interview:
            let byTranslation = Self.classifyQuestion(question)
            let byOriginal = original.map(Self.classifyQuestion) ?? "GENERAL"
            questionType = byOriginal != "GENERAL" ? byOriginal : byTranslation
            if questionType == "REACT" {
                onSuggestion?("", questionType)
                return
            }
            systemPrompt = buildSystemPrompt(questionType: questionType)
            userPrompt = buildUserPrompt(question: question)
        case .research:
            questionType = "RESEARCH"
            systemPrompt = buildResearchPrompt()
            userPrompt = buildResearchUserPrompt(heard: question)
        }

        onStatus?("建議中...")

        guard let apiKey = AIKey.read("gemini") else {
            debugLog("copilot: no gemini key found")
            onSuggestion?("⚠️ 請設定 Gemini API Key", questionType)
            return
        }
        debugLog("copilot: calling gemini (type=\(questionType), key=\(apiKey.prefix(8))...)")

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:streamGenerateContent?alt=sse&key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": [["text": userPrompt]]]],
            "generationConfig": [
                "maxOutputTokens": 400,
                "temperature": 0.6,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                debugLog("copilot: gemini API error \(code)")
                onSuggestion?("⚠️ API error \(code)", questionType)
                onStatus?("待命")
                return
            }

            debugLog("copilot: gemini connected, status=\(http.statusCode)")
            var fullText = ""
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst(6))
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = obj["candidates"] as? [[String: Any]],
                      let parts = candidates.first?["content"] as? [String: Any],
                      let partsList = parts["parts"] as? [[String: Any]],
                      let text = partsList.first?["text"] as? String else { continue }
                fullText += text
                onStreaming?(text)
            }

            if !Task.isCancelled {
                var output = fullText
                if autoSpeak && output.count > 45 {
                    let sentences: [Character] = ["。", "！", "？", ".", "!", "?"]
                    let clauses: [Character] = ["，", "、", ",", ";", "；"]
                    let scan = output.prefix(45)
                    if let idx = scan.lastIndex(where: { sentences.contains($0) }) {
                        output = String(output[...idx])
                    } else if let idx = scan.lastIndex(where: { clauses.contains($0) }) {
                        output = String(output[..<idx])
                    } else {
                        output = String(output.prefix(45))
                    }
                    debugLog("copilot: autoSpeak truncated \(fullText.count)→\(output.count) chars")
                }
                debugLog("copilot: gemini done, \(output.count) chars")
                onSuggestion?(output, questionType)
                addTranscript(speaker: "me", text: output)
            }
        } catch {
            debugLog("copilot: gemini error: \(error.localizedDescription)")
            if !Task.isCancelled {
                onSuggestion?("⚠️ \(error.localizedDescription)", questionType)
            }
        }

        onStatus?("待命")
    }
}

// MARK: - String regex helper

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func matchesPrefix(_ pattern: String) -> Bool {
        range(of: "^(\(pattern))", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
