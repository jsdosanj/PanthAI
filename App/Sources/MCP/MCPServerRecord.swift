import Foundation
import SwiftData

struct MCPPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let note: String

    static let all: [MCPPreset] = [
        .init(id: "github", name: "GitHub", url: "https://api.githubcopilot.com/mcp/", note: "Repos, issues, pull requests. Use a GitHub token, or sign in."),
        .init(id: "cloudflare", name: "Cloudflare", url: "https://mcp.cloudflare.com/mcp", note: "Workers, KV, R2, D1 and DNS."),
        .init(id: "stripe", name: "Stripe", url: "https://mcp.stripe.com", note: "Can move money. Read-only is on by default."),
        .init(id: "clerk", name: "Clerk", url: "https://mcp.clerk.com/mcp", note: "Users and organizations."),
        .init(id: "resend", name: "Resend", url: "https://mcp.resend.com/mcp", note: "Email sending and audiences."),
        .init(id: "huggingface", name: "Hugging Face", url: "https://huggingface.co/mcp", note: "Search models, datasets and Spaces."),
        .init(id: "canva", name: "Canva", url: "https://mcp.canva.com/mcp", note: "Designs and brand templates."),
        .init(id: "openrouter", name: "OpenRouter", url: "https://mcp.openrouter.ai/mcp", note: "Models, credits and usage."),
        .init(id: "pcloud", name: "pCloud", url: "https://mcp.pcloud.com/mcp", note: "Browse and manage cloud files."),
        .init(id: "render", name: "Render", url: "https://mcp.render.com/mcp", note: "Services, deploys and logs."),
        .init(id: "expo", name: "Expo", url: "https://mcp.expo.dev/mcp", note: "Builds, updates and workflows."),
        .init(id: "custom", name: "Custom server", url: "https://", note: "Any remote MCP server over HTTPS."),
    ]
}

/// A remote MCP server the user connected. Tokens live in the Keychain.
@Model
final class MCPServerRecord {
    var id: UUID = UUID()
    var name: String = ""
    var url: String = ""
    /// When on, only tools the server marks read-only are offered to the model.
    var readOnly: Bool = true
    var createdAt: Date = Date.now

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    var tokenAccount: String { "mcp.\(id.uuidString).token" }
    var oauthAccount: String { "mcp.\(id.uuidString).oauth" }
    var hasCredentials: Bool { Keychain.get(tokenAccount) != nil || Keychain.get(oauthAccount) != nil }
}
