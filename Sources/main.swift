import Vapor

var env = try Environment.detect()
let app = Application(env)

defer {
    app.shutdown()
}

// 1. Endpoint Check Status
app.get("ar", "idle-status") { (req: Request) -> String in
    return "{\"status\":\"idle\",\"service\":\"Pair-AI-DigitalTwin-Engine\"}"
}

// 2. Data Models
struct OpenRouterMessage: Content {
    let role: String
    let content: String
}

struct OpenRouterPayload: Content {
    let model: String
    let messages: [OpenRouterMessage]
}

struct PARequest: Content {
    let prompt: String?
    let mode: String? // "companion", "translate_en_vi", "translate_vi_en"
    let user_id: String?
}

struct PAResponse: Content {
    let response_text: String
    let mode: String
    let pa_action: String // "idle", "walk", "speak", "translate"
}

// 3. System Prompt khởi tạo tính cách PA Avatar
let paSystemPrompt = """
Bạn là PA-Avatar, bản sao số (Digital Twin) thông minh của anh Tuyên.
- Tính cách: Am hiểu công nghệ, lịch sự, nhã nhặn, đồng hành 24/7.
- Nhiệm vụ:
  1. Nếu mode là 'companion': Trò chuyện đồng hành, trả lời ngắn gọn, tự nhiên bằng Tiếng Việt.
  2. Nếu mode là 'translate_en_vi': Dịch chính xác câu Tiếng Anh sang Tiếng Việt chuẩn văn phong giao tiếp.
  3. Nếu mode là 'translate_vi_en': Dịch chính xác câu Tiếng Việt sang Tiếng Anh tự nhiên.
"""

func handlePARoute(req: Request) async throws -> Response {
    let body = try? req.content.decode(PARequest.self)
    let userPrompt = body?.prompt ?? "Xin chào PA Avatar"
    let currentMode = body?.mode ?? "companion"

    guard let apiKey = Environment.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
        let errJson = "{\"error\":\"OPENROUTER_API_KEY is missing\"}"
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .internalServerError, headers: headers, body: .init(string: errJson))
    }

    let openRouterURI = URI(string: "https://openrouter.ai/api/v1/chat/completions")
    let payload = OpenRouterPayload(
        model: "google/gemini-3.6-flash",
        messages: [
            OpenRouterMessage(role: "system", content: paSystemPrompt),
            OpenRouterMessage(role: "user", content: "Mode: \(currentMode). Yêu cầu: \(userPrompt)")
        ]
    )

    do {
        let clientResponse = try await req.client.post(openRouterURI) { (clientReq: inout ClientRequest) in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.add(name: "HTTP-Referer", value: "https://pair-ai-service.onrender.com")
            clientReq.headers.add(name: "X-Title", value: "Pair-AI-DigitalTwin")
            try clientReq.content.encode(payload, as: .json)
        }

        let responseBody: Response.Body
        if let buffer = clientResponse.body {
            responseBody = .init(buffer: buffer)
        } else {
            responseBody = .empty
        }

        var resHeaders = clientResponse.headers
        resHeaders.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: clientResponse.status, headers: resHeaders, body: responseBody)
    } catch {
        let errDetail = "{\"error\":\"Failed to reach OpenRouter: \(error.localizedDescription)\"}"
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .internalServerError, headers: headers, body: .init(string: errDetail))
    }
}

app.post("ar", "session", "gemini-route", use: handlePARoute)

try app.run()
