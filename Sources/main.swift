import Vapor

var env = try Environment.detect()
let app = Application(env)

defer {
    app.shutdown()
}

// ==========================================
// 1. DATA MODELS & MOCK DATABASE
// ==========================================

struct UserWallet {
    var email: String
    var phone: String
    var balanceVND: Double
    var tokens: Int
}

var mockWallets: [String: UserWallet] = [
    "0900000000": UserWallet(email: "admin@aladin.vn", phone: "0900000000", balanceVND: 100000.0, tokens: 1000000)
]

struct TopupRequest: Content {
    let phone: String
    let amountVND: Double
    let paymentMethod: String? // "momo_qr" hoặc "visa_mastercard"
}

struct MoMoIPNPayload: Content {
    let partnerCode: String?
    let orderId: String?
    let amount: Double?
    let resultCode: Int? // 0 = Thành công
    let extraData: String? // Chứa SĐT của khách hàng (e.g. "0900000000")
}

struct PARequest: Content {
    let prompt: String?
    let mode: String?           // "companion", "translate_en_vi", "translate_vi_en"
    let selected_model: String? // "google/gemini-3.6-flash", "openai/gpt-4o", v.v.
    let user_id: String?
}

struct OpenRouterMessage: Content {
    let role: String
    let content: String
}

struct OpenRouterPayload: Content {
    let model: String
    let messages: [OpenRouterMessage]
}

// ==========================================
// 2. ENDPOINTS CHO VÍ PA & MOMO MERCHANT
// ==========================================

app.get("ar", "idle-status") { (req: Request) -> String in
    return "{\"status\":\"idle\",\"service\":\"Aladin-PA-Engine-v3-MoMoMerchant\"}"
}

// 2.1 Lấy số dư Ví PA
app.get("api", "wallet", "balance") { (req: Request) async throws -> Response in
    let phone = req.query[String.self, at: "phone"] ?? "0900000000"
    let wallet = mockWallets[phone] ?? UserWallet(email: "guest@aladin.vn", phone: phone, balanceVND: 0.0, tokens: 0)
    
    let jsonRes = """
    {
        "phone": "\(wallet.phone)",
        "email": "\(wallet.email)",
        "balance_vnd": \(wallet.balanceVND),
        "pa_tokens": \(wallet.tokens)
    }
    """
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(string: jsonRes))
}

// 2.2 Khởi tạo thanh toán MoMo Merchant (Cho cả QR & Thẻ Visa)
app.post("api", "wallet", "topup-momo") { (req: Request) async throws -> Response in
    let body = try req.content.decode(TopupRequest.self)
    let method = body.paymentMethod ?? "momo_qr"
    
    let jsonRes = """
    {
        "status": "success",
        "phone": "\(body.phone)",
        "amount": \(body.amountVND),
        "payment_method": "\(method)",
        "checkout_url": "https://test-payment.momo.vn/v2/gateway/pay?s=mock_token",
        "note": "Hỗ trợ MoMo QR, VietQR và Thẻ Visa/Mastercard Quốc Tế. Tiền tự động về ACB của anh Tuyên."
    }
    """
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .ok, headers: headers, body: .init(string: jsonRes))
}

// 2.3 Webhook (IPN) Tự động nhận tiền từ MoMo Merchant để cộng Token
app.post("api", "wallet", "momo-ipn") { (req: Request) async throws -> Response in
    let ipn = try? req.content.decode(MoMoIPNPayload.self)
    
    if let ipn = ipn, ipn.resultCode == 0, let amount = ipn.amount, let phone = ipn.extraData {
        let addedTokens = Int(amount * 10) // 100.000 VNĐ = 1.000.000 Tokens
        if var wallet = mockWallets[phone] {
            wallet.balanceVND += amount
            wallet.tokens += addedTokens
            mockWallets[phone] = wallet
        } else {
            mockWallets[phone] = UserWallet(email: "\(phone)@aladin.vn", phone: phone, balanceVND: amount, tokens: addedTokens)
        }
    }
    
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    return Response(status: .noContent, headers: headers, body: .empty)
}

// ==========================================
// 3. CORE AI ROUTE (OPENROUTER + VÍ PA DEDUCTION)
// ==========================================

let paSystemPrompt = """
Bạn là PA-Avatar, bản sao số (Digital Twin) thông minh của anh Nguyễn Anh Tuyên trên hệ thống aladin.vn.
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
    let chosenModel = body?.selected_model ?? "google/gemini-3.6-flash"
    let phone = body?.user_id ?? "0900000000"

    guard let apiKey = Environment.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
        let errJson = "{\"error\":\"OPENROUTER_API_KEY is missing\"}"
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .internalServerError, headers: headers, body: .init(string: errJson))
    }

    let openRouterURI = URI(string: "https://openrouter.ai/api/v1/chat/completions")
    let payload = OpenRouterPayload(
        model: chosenModel,
        messages: [
            OpenRouterMessage(role: "system", content: paSystemPrompt),
            OpenRouterMessage(role: "user", content: "Mode: \(currentMode). Yêu cầu: \(userPrompt)")
        ]
    )

    do {
        let clientResponse = try await req.client.post(openRouterURI) { (clientReq: inout ClientRequest) in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            clientReq.headers.add(name: "HTTP-Referer", value: "https://aladin.vn")
            clientReq.headers.add(name: "X-Title", value: "Aladin-PA-DigitalTwin")
            try clientReq.content.encode(payload, as: .json)
        }

        // Tự động gạch nợ 10 Tokens trong Ví PA của khách hàng
        if var wallet = mockWallets[phone], wallet.tokens >= 10 {
            wallet.tokens -= 10
            mockWallets[phone] = wallet
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
