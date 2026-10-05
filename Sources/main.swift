import Vapor

var env = try Environment.detect()
let app = Application(env)

defer {
    app.shutdown()
}

// 1. Health check
app.get("ar", "idle-status") { (req: Request) -> String in
    return "{\"status\":\"idle\",\"service\":\"Pair-AI-Vertex\"}"
}

// Structs cho Vertex AI Payload
struct VertexPart: Content {
    let text: String
}

struct VertexContent: Content {
    let role: String
    let parts: [VertexPart]
}

struct VertexPayload: Content {
    let contents: [VertexContent]
}

struct GeminiRequest: Content {
    let prompt: String?
}

struct TokenResult: Content {
    let access_token: String
}

// 2. Handler riêng biệt cho Vertex AI Route
func handleGeminiRoute(req: Request) async throws -> Response {
    let body = try? req.content.decode(GeminiRequest.self)
    let userPrompt = body?.prompt ?? "Analyse AR Camera Frame"

    // Lấy Access Token từ Metadata Server của Cloud Run (IAM Auth)
    let tokenURI = URI(string: "http://metadata.google.internal/computeMetadata/v1/instance/service-account/default/token")
    let tokenResponse = try await req.client.get(tokenURI) { (tokenReq: inout ClientRequest) in
        tokenReq.headers.add(name: "Metadata-Flavor", value: "Google")
    }
    
    guard let tokenData = try? tokenResponse.content.decode(TokenResult.self) else {
        return Response(status: .internalServerError, body: .init(string: "{\"error\":\"Failed to fetch IAM Access Token from Cloud Run Metadata\"}"))
    }

    // Endpoint Vertex AI trên project gemini-pair-ai
    let projectID = "gemini-pair-ai"
    let location = "asia-east1"
    let model = "gemini-1.5-flash"
    let vertexURI = URI(string: "https://\(location)-aiplatform.googleapis.com/v1/projects/\(projectID)/locations/\(location)/publishers/google/models/\(model):generateContent")

    let payload = VertexPayload(contents: [
        VertexContent(role: "user", parts: [VertexPart(text: userPrompt)])
    ])

    let clientResponse = try await req.client.post(vertexURI) { (clientReq: inout ClientRequest) in
        clientReq.headers.bearerAuthorization = BearerAuthorization(token: tokenData.access_token)
        try clientReq.content.encode(payload, as: .json)
    }

    let responseBody: Response.Body
    if let buffer = clientResponse.body {
        responseBody = .init(buffer: buffer)
    } else {
        responseBody = .empty
    }

    return Response(status: clientResponse.status, headers: clientResponse.headers, body: responseBody)
}

// Đăng ký route
app.post("ar", "session", "gemini-route", use: handleGeminiRoute)

try app.run()
