import Vapor

var env = try Environment.detect()
let app = Application(env)

defer {
    app.shutdown()
}

// Health check endpoint
app.get("ar", "idle-status") { (req: Request) -> String in
    return "{\"status\":\"idle\",\"service\":\"Pair-AI-OpenRouter\"}"
}

struct OpenRouterMessage: Content {
    let role: String
    let content: String
}

struct OpenRouterPayload: Content {
    let model: String
    let messages: [OpenRouterMessage]
}

struct GeminiRequest: Content {
    let prompt: String?
}

// Main handler for Gemini via OpenRouter
func handleGeminiRoute(req: Request) async throws -> Response {
    let body = try? req.content.decode(GeminiRequest.self)
    let userPrompt = body?.prompt ?? "Analyse AR Camera Frame"

    guard let apiKey = Environment.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
        let errJson = "{\"error\":\"OPENROUTER_API_KEY environment variable is missing\"}"
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .internalServerError, headers: headers, body: .init(string: errJson))
    }

    let openRouterURI = URI(string: "https://openrouter.ai/api/v1/chat/completions")
    let payload = OpenRouterPayload(
        model: "google/gemini-2.0-flash-001",
        messages: [OpenRouterMessage(role: "user", content: userPrompt)]
    )

    do {
        let clientResponse = try await req.client.post(openRouterURI) { (clientReq: inout ClientRequest) in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.add(name: "HTTP-Referer", value: "https://pair-ai-service.onrender.com")
            clientReq.headers.add(name: "X-Title", value: "Pair-AI")
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

app.post("ar", "session", "gemini-route", use: handleGeminiRoute)

try app.run()
