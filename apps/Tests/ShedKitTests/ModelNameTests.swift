import XCTest
@testable import ShedKit

final class ModelNameTests: XCTestCase {
    private func model(_ id: String, name: String? = nil, provider: String = "opencodex") -> ModelInfo {
        ModelInfo(provider: provider, id: id, name: name ?? id, contextWindow: nil, reasoning: true)
    }

    /// An id becomes a name short enough for a chip: no provider, no build date, the version in one piece.
    func testIdsReadAsNames() {
        let names = [
            "mistral/deepseek-v4-1-flash-1017": "DeepSeek V4.1 Flash",
            "openai-apikey/gpt-6.1-terra": "GPT-6.1 Terra",
            "gpt-6.1-terra": "GPT-6.1 Terra",
            "claude-haiku-5-5": "Claude Haiku 5.5",
            "anthropic-apikey/claude-fable-5-1-20261017": "Claude Fable 5.1",
            "claude-3-5-sonnet-2024-10-22": "Claude 3.5 Sonnet",
            "glm-5-3-flash": "GLM-5.3 Flash",
            "mistral/mistral-large-4": "Mistral Large 4",
            "mistral/mistral-large-latest": "Mistral Large",
            "google/gemini-3-5-pro-preview": "Gemini 3.5 Pro Preview",
            "openrouter/meta-llama/llama-4-maverick:free": "Llama 4 Maverick Free",
            "groq/gpt-oss-120b": "GPT OSS 120B",
            "xiaomi-mimo/mimo-v2-pro": "MiMo V2 Pro",
            "gpt-4o-mini": "GPT-4o Mini",
            "o3-mini": "o3 Mini",
            "fireworks/qwen3-coder-480b": "Qwen3 Coder 480B",
            "xai/grok-5-fast": "Grok 5 Fast",
        ]
        for (id, name) in names { XCTAssertEqual(model(id).compactName, name, id) }
    }

    /// The names the agents ship with stay as they are.
    func testDisplayNamesStay() {
        XCTAssertEqual(model("gpt-6.1-terra", name: "GPT-6.1 Terra", provider: "openai").compactName, "GPT-6.1 Terra")
        XCTAssertEqual(model("claude-haiku-5-5", name: "Claude Haiku 5.5", provider: "anthropic").compactName, "Claude Haiku 5.5")
    }

    func testEssentialNameKeepsTheFirstWords() {
        XCTAssertEqual(model("openrouter/meta-llama/llama-4-maverick-17b-128e-instruct").essentialName, "Llama 4 Maverick")
        XCTAssertEqual(model("gpt-6.1-terra").essentialName, "GPT-6.1 Terra")
    }

    /// Two models that go by the same name say where they come from.
    func testTwinsNameTheirSource() {
        let mine = model("openai-apikey/gpt-6.1-terra")
        let twin = model("gpt-6.1-terra")
        let other = model("mistral/mistral-large-4")
        XCTAssertEqual(mine.chipName(among: [mine, other]), "GPT-6.1 Terra")
        XCTAssertEqual(mine.chipName(among: [mine, twin, other]), "API · GPT-6.1 Terra")
        XCTAssertEqual(twin.chipName(among: [mine, twin, other]), "ChatGPT · GPT-6.1 Terra")
    }

    func testEffortNames() {
        XCTAssertEqual(ModelInfo.effortName("high"), "High")
        XCTAssertEqual(ModelInfo.effortName(nil), "Default")
        XCTAssertEqual(ModelInfo.effortName("xhigh", among: ["low", "high", "xhigh"]), "Max")
        XCTAssertEqual(ModelInfo.effortName("xhigh", among: ["high", "xhigh", "max"]), "XHigh")
    }
}
