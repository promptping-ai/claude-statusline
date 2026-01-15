import Foundation
import Testing

@testable import claude_statusline

@Suite("StatusInput Parsing")
struct StatusInputTests {
  @Test("Parse minimal input")
  func testMinimalInput() throws {
    let json = """
      {
        "workspace": {"current_dir": "/Users/test/project"},
        "model": {"display_name": "Claude"}
      }
      """
    let data = json.data(using: .utf8)!
    let input = try JSONDecoder().decode(StatusInput.self, from: data)

    #expect(input.workspace.currentDir == "/Users/test/project")
    #expect(input.model.displayName == "Claude")
    #expect(input.sessionId == nil)
    #expect(input.contextWindow == nil)
  }

  @Test("Parse full input with context window")
  func testFullInput() throws {
    let json = """
      {
        "workspace": {"current_dir": "/Users/test/myproject"},
        "model": {"display_name": "Opus"},
        "session_id": "abc123",
        "context_window": {
          "current_usage": {
            "input_tokens": 1000,
            "cache_creation_input_tokens": 500,
            "cache_read_input_tokens": 200
          },
          "context_window_size": 200000
        }
      }
      """
    let data = json.data(using: .utf8)!
    let input = try JSONDecoder().decode(StatusInput.self, from: data)

    #expect(input.workspace.currentDir == "/Users/test/myproject")
    #expect(input.model.displayName == "Opus")
    #expect(input.sessionId == "abc123")
    #expect(input.contextWindow?.currentUsage?.totalTokens == 1700)
    #expect(input.contextWindow?.contextWindowSize == 200000)
  }
}

@Suite("Platform Detection")
struct PlatformDetectionTests {
  @Test("Detect GitHub from URL")
  func testGitHub() {
    let url = "git@github.com:promptping-ai/claude-statusline.git"
    #expect(Platform.detect(from: url) == .github)

    let httpsUrl = "https://github.com/promptping-ai/claude-statusline.git"
    #expect(Platform.detect(from: httpsUrl) == .github)
  }

  @Test("Detect Azure DevOps from URL")
  func testAzure() {
    let url = "https://grouperossel@dev.azure.com/grouperossel/project/_git/repo"
    #expect(Platform.detect(from: url) == .azure)

    let vsUrl = "https://grouperossel.visualstudio.com/project/_git/repo"
    #expect(Platform.detect(from: vsUrl) == .azure)
  }

  @Test("Detect GitLab from URL")
  func testGitLab() {
    let url = "git@gitlab.com:group/project.git"
    #expect(Platform.detect(from: url) == .gitlab)

    let selfHosted = "https://gitlab.company.com/group/project.git"
    #expect(Platform.detect(from: selfHosted) == .gitlab)
  }

  @Test("Unknown platform")
  func testUnknown() {
    let url = "https://bitbucket.org/team/repo.git"
    #expect(Platform.detect(from: url) == .unknown)
  }
}

@Suite("ANSI Colors")
struct ANSIColorTests {
  @Test("Color codes are valid escape sequences")
  func testColorCodes() {
    #expect(ANSIColor.reset.contains("\u{001B}["))
    #expect(ANSIColor.red.contains("31"))
    #expect(ANSIColor.green.contains("32"))
    #expect(ANSIColor.yellow.contains("33"))
  }
}

@Suite("Azure Context Parsing")
struct AzureContextTests {
  @Test("Parse HTTPS URL with username")
  func testHTTPSWithUsername() {
    let url = "https://grouperossel@dev.azure.com/grouperossel/Le%20Soir/_git/iOS_Le_Soir"
    let context = parseAzureContext(from: url)

    #expect(context != nil)
    #expect(context?.organization == "grouperossel")
    #expect(context?.project == "Le Soir")
    #expect(context?.repository == "iOS_Le_Soir")
    #expect(context?.organizationURL == "https://dev.azure.com/grouperossel")
  }

  @Test("Parse HTTPS URL without username")
  func testHTTPSWithoutUsername() {
    let url = "https://dev.azure.com/myorg/myproject/_git/myrepo"
    let context = parseAzureContext(from: url)

    #expect(context != nil)
    #expect(context?.organization == "myorg")
    #expect(context?.project == "myproject")
    #expect(context?.repository == "myrepo")
  }

  @Test("Parse SSH URL")
  func testSSH() {
    let url = "git@ssh.dev.azure.com:v3/grouperossel/Le%20Soir/iOS_Le_Soir"
    let context = parseAzureContext(from: url)

    #expect(context != nil)
    #expect(context?.organization == "grouperossel")
    #expect(context?.project == "Le%20Soir")  // SSH doesn't URL-decode
    #expect(context?.repository == "iOS_Le_Soir")
  }

  @Test("Parse legacy visualstudio.com URL")
  func testVisualStudio() {
    let url = "https://myorg.visualstudio.com/myproject/_git/myrepo"
    let context = parseAzureContext(from: url)

    #expect(context != nil)
    #expect(context?.organization == "myorg")
    #expect(context?.project == "myproject")
    #expect(context?.repository == "myrepo")
  }

  @Test("Return nil for GitHub URL")
  func testGitHubReturnsNil() {
    let url = "https://github.com/owner/repo.git"
    let context = parseAzureContext(from: url)
    #expect(context == nil)
  }

  @Test("Return nil for invalid Azure URL")
  func testInvalidReturnsNil() {
    let url = "https://dev.azure.com/incomplete"
    let context = parseAzureContext(from: url)
    #expect(context == nil)
  }
}
