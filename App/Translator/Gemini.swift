import Foundation

// Gemini 호출. translator.html 의 streamGemini · askGemini · askPriority · withGeminiRetry 를 옮겼다.

struct GeminiError: LocalizedError {
    let message: String
    var retryable = false
    var priorityRejected = false
    var errorDescription: String? { message }
}

enum Gemini {
    static let retryStatus: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// 구글이 돌려주는 영어 오류를 그대로 띄우면 뭘 해야 할지 모른다. 자주 나오는 것만 우리말로.
    static func errMessage(status: Int, raw: String?) -> String {
        let m = raw ?? ""
        let ci: NSRegularExpression.Options = .caseInsensitive
        if m.rxTest("api[_ ]?key not valid|API_KEY_INVALID|invalid api key", ci) { return "API 키가 올바르지 않아요. 설정에서 다시 넣어주세요." }
        if m.rxTest("permission|PERMISSION_DENIED|not authorized", ci) { return "API 키에 권한이 없어요. 키를 다시 발급해보세요." }
        if status == 429 || m.rxTest("quota|RESOURCE_EXHAUSTED|rate limit", ci) { return "요청이 너무 잦아요. 잠시 뒤에 다시 해주세요." }
        if status == 503 || m.rxTest("overloaded|UNAVAILABLE", ci) { return "구글 서버가 지금 붐벼요. 잠시 뒤에 다시 해주세요." }
        if m.rxTest("is not found|not supported for generateContent|models/", ci) { return "이 모델을 못 찾았어요. 설정에서 모델 이름을 확인해주세요." }
        if m.rxTest("safety|blocked|prohibited", ci) { return "안전 설정에 걸려서 응답이 막혔어요." }
        if m.rxTest("deadline|timeout|timed out", ci) { return "응답이 너무 늦어요. 다시 해주세요." }
        if status == 400 { return "요청이 거부됐어요. 입력이 너무 길거나 모델이 받지 않는 형식일 수 있어요. (400)" }
        if status >= 500 { return "구글 쪽 오류예요. 잠시 뒤에 다시 해주세요. (\(status))" }
        return status > 0 ? "번역에 실패했어요. (\(status))" : "번역에 실패했어요."
    }

    private static func apiError(status: Int, data: Data) -> GeminiError {
        var raw: String?
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = j["error"] as? [String: Any] { raw = e["message"] as? String }
        return GeminiError(message: errMessage(status: status, raw: raw), retryable: retryStatus.contains(status))
    }

    /// 취소는 다시 걸지 않는다. 그 밖의 연결 끊김은 다시 걸어 본다.
    private static func wrap(_ e: Error) -> Error {
        if e is CancellationError { return e }
        if let u = e as? URLError {
            if u.code == .cancelled { return CancellationError() }
            if u.code == .timedOut { return GeminiError(message: "응답이 너무 늦어요. 다시 해주세요.") }
            return GeminiError(message: "연결이 끊겼어요. 다시 해주세요.", retryable: true)
        }
        return e
    }

    /// 붐비는 시간엔 429·503 을 그냥 던진다. 조용히 두 번까지 더 걸어 본다.
    static func withRetry<T>(_ f: () async throws -> T) async throws -> T {
        var i = 0
        while true {
            do { return try await f() }
            catch {
                guard i < 2, let g = error as? GeminiError, g.retryable else { throw error }
                let ms = (i == 0 ? 900 : 2400) + Int.random(in: 0..<500)
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                i += 1
            }
        }
    }

    private static func request(_ url: String, key: String?, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        guard let u = URL(string: url) else { throw GeminiError(message: "주소가 잘못됐어요.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { r.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private static func base(_ model: String) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model)"
    }

    /// streamGenerateContent + alt=sse. onText 에는 지금까지 받은 전체가 넘어간다.
    static func streamOnce(model: String, key: String, body: [String: Any], timeout: TimeInterval,
                           onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let req = try request(base(model) + ":streamGenerateContent?alt=sse", key: key, body: body, timeout: timeout)
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) } catch { throw wrap(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            do { for try await b in bytes { data.append(b) } } catch {}
            throw apiError(status: status, data: data)
        }
        var full = ""
        do {
            for try await raw in bytes.lines {
                let line = raw.trimmed
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmed
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                let t = texts(obj)
                if !t.isEmpty {
                    full += t
                    let snap = full
                    await onText(snap)
                }
            }
        } catch { throw wrap(error) }
        return full
    }

    /// 한 번에 받는 호출 (독음·사전·공부 등)
    static func ask(model: String, key: String, prompt: String, maxTokens: Int = 1024, temperature: Double = 0.4,
                    thinking: Bool = false) async throws -> String {
        try await withRetry {
            var gen: [String: Any] = ["temperature": temperature, "maxOutputTokens": maxTokens]
            if !thinking { gen["thinkingConfig"] = ["thinkingBudget": 0] }
            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": gen
            ]
            let req = try request(base(model) + ":generateContent", key: key, body: body, timeout: thinking ? 90 : 30)
            let data: Data, resp: URLResponse
            do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw wrap(error) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { throw apiError(status: status, data: data) }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let out = texts(obj).trimmed
            if out.isEmpty { throw GeminiError(message: "결과를 가져오지 못했어요.") }
            return out
        }
    }

    /// 한 번에 받고 응답 JSON 을 통째로 돌려준다 (TTS·이미지처럼 글이 아닌 것을 받을 때)
    static func generate(model: String, key: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await withRetry {
            let req = try request(base(model) + ":generateContent", key: key, body: body, timeout: timeout)
            let data: Data, resp: URLResponse
            do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw wrap(error) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { throw apiError(status: status, data: data) }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    static func parts(_ obj: [String: Any]) -> [[String: Any]] {
        guard let c = (obj["candidates"] as? [[String: Any]])?.first,
              let content = c["content"] as? [String: Any] else { return [] }
        return content["parts"] as? [[String: Any]] ?? []
    }

    /// inlineData(오디오·이미지) 하나를 꺼낸다
    static func inlineData(_ obj: [String: Any]) -> (mime: String, data: Data)? {
        for p in parts(obj) {
            guard let d = (p["inlineData"] ?? p["inline_data"]) as? [String: Any],
                  let b64 = d["data"] as? String, let data = Data(base64Encoded: b64) else { continue }
            return ((d["mimeType"] ?? d["mime_type"]) as? String ?? "", data)
        }
        return nil
    }

    /// 우선 처리 — Interactions API 에서만 받는다. 스트리밍 형식이 문서에 없어 한 번에 받는다.
    /// store:false 로 주고받은 글을 구글 쪽에 남기지 않는다.
    static func askPriority(model: String, key: String, text: String, thinking: Bool) async throws -> String {
        var gen: [String: Any] = ["max_output_tokens": 2048]
        if !thinking { gen["thinking_level"] = "minimal" }
        let body: [String: Any] = ["model": model, "input": text, "service_tier": "priority",
                                   "store": false, "generation_config": gen]
        let req = try request("https://generativelanguage.googleapis.com/v1beta/interactions", key: key, body: body, timeout: 60)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw wrap(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var e = apiError(status: status, data: data)
            e.priorityRejected = [400, 403, 404].contains(status)
            e.retryable = !e.priorityRejected && retryStatus.contains(status)
            throw e
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let steps = obj["steps"] as? [[String: Any]] ?? []
        let out = steps.filter { $0["type"] as? String == "model_output" }
            .map { (($0["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined() }
            .joined().trimmed
        if out.isEmpty { throw GeminiError(message: "결과를 가져오지 못했어요.") }
        return out
    }

    /// 설정 → 연결 "키 확인": 모델 목록을 한 번 불러 본다 (돈이 안 드는 호출)
    static func checkKey(_ key: String) async -> (ok: Bool, message: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return (false, "키를 먼저 넣어 주세요.") }
        guard let u = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1") else { return (false, "") }
        var r = URLRequest(url: u, timeoutInterval: 15)
        r.setValue(k, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return (true, "사용할 수 있는 키예요.") }
            return (false, apiError(status: status, data: data).message)
        } catch {
            return (false, "연결이 안 돼요. 인터넷을 확인해 주세요.")
        }
    }

    static func texts(_ obj: [String: Any]) -> String {
        guard let c = (obj["candidates"] as? [[String: Any]])?.first,
              let content = c["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }
}
