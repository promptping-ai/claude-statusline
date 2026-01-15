import ArgumentParser
import Foundation
import PullRequestPing
import Subprocess

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

@main
struct ClaudeStatusline: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-statusline",
    abstract: "Enhanced statusline for Claude Code with multi-platform PR support",
    discussion: """
      Reads JSON from stdin (Claude Code status input) and outputs a multi-line status:
      - Line 1: Project │ Plan │ Model │ Context % │ Account
      - Line 2: PR status with checks and comments (GitHub or Azure)
      - Line 3: Graphite stack visualization

      Supports GitHub, Azure DevOps, and GitLab via pull-request-ping.
      """
  )

  func run() async throws {
    // Read JSON input from stdin
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = try? JSONDecoder().decode(StatusInput.self, from: inputData)
    else {
      print("Error: Invalid JSON input")
      return
    }

    let cwd = input.workspace.currentDir
    let project = URL(fileURLWithPath: cwd).lastPathComponent

    // Get branch name
    let branch = await getBranch(cwd: cwd)

    // Get plan subject from session mapping
    let planName = getPlanSubject(sessionId: input.sessionId)

    // Build Line 1: Main status
    printLine1(
      project: project,
      planName: planName,
      model: input.model.displayName ?? "Claude",
      contextUsage: input.contextWindow,
      account: ProcessInfo.processInfo.environment["CLAUDE_ACCOUNT"]
    )

    // Build Line 2: PR status (if on a branch with PR)
    if let branch = branch, branch != "main" {
      await printLine2(cwd: cwd, branch: branch)
    }

    // Build Line 3: Graphite stack
    if branch != nil {
      await printLine3(cwd: cwd)
    }
  }
}

// MARK: - Input Models

struct StatusInput: Codable {
  let workspace: Workspace
  let model: Model
  let sessionId: String?
  let contextWindow: ContextWindow?

  enum CodingKeys: String, CodingKey {
    case workspace
    case model
    case sessionId = "session_id"
    case contextWindow = "context_window"
  }

  struct Workspace: Codable {
    let currentDir: String

    enum CodingKeys: String, CodingKey {
      case currentDir = "current_dir"
    }
  }

  struct Model: Codable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
    }
  }

  struct ContextWindow: Codable {
    let currentUsage: CurrentUsage?
    let contextWindowSize: Int?

    enum CodingKeys: String, CodingKey {
      case currentUsage = "current_usage"
      case contextWindowSize = "context_window_size"
    }

    struct CurrentUsage: Codable {
      let inputTokens: Int
      let cacheCreationInputTokens: Int
      let cacheReadInputTokens: Int

      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
      }

      var totalTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
      }
    }
  }
}

// MARK: - ANSI Colors

enum ANSIColor {
  static let reset = "\u{001B}[0m"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"
  static let italic = "\u{001B}[3m"
  static let red = "\u{001B}[31m"
  static let green = "\u{001B}[32m"
  static let yellow = "\u{001B}[33m"
  static let cyan = "\u{001B}[36m"
}

// MARK: - Platform Detection

enum Platform {
  case github
  case azure
  case gitlab
  case unknown

  static func detect(from remoteURL: String) -> Platform {
    if remoteURL.contains("github.com") {
      return .github
    } else if remoteURL.contains("dev.azure.com") || remoteURL.contains("visualstudio.com") {
      return .azure
    } else if remoteURL.contains("gitlab") {
      return .gitlab
    }
    return .unknown
  }
}

// MARK: - Shell Helper

func runCommand(_ executable: String, arguments: [String], cwd: String? = nil) async -> String? {
  do {
    var args = arguments
    if executable == "git", let cwd = cwd {
      args = ["-C", cwd] + args
    }

    let result = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(args),
      output: .bytes(limit: 1024 * 1024),
      error: .discarded
    )
    guard result.terminationStatus.isSuccess else { return nil }
    return String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  } catch {
    return nil
  }
}

func runCommandInDir(_ executable: String, arguments: [String], cwd: String) async -> String? {
  do {
    let result = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      workingDirectory: FilePath(cwd),
      output: .bytes(limit: 1024 * 1024),
      error: .discarded
    )
    guard result.terminationStatus.isSuccess else { return nil }
    return String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  } catch {
    return nil
  }
}

// MARK: - Helper Functions

func getBranch(cwd: String) async -> String? {
  await runCommand("git", arguments: ["branch", "--show-current"], cwd: cwd)
}

func getRemoteURL(cwd: String) async -> String? {
  await runCommand("git", arguments: ["remote", "get-url", "origin"], cwd: cwd)
}

func getPlanSubject(sessionId: String?) -> String? {
  guard let sessionId = sessionId else { return nil }
  let sessionPlansPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/.session-plans.json")

  guard let data = try? Data(contentsOf: sessionPlansPath),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
  else {
    return nil
  }
  return json[sessionId]
}

// MARK: - Line 1: Main Status

func printLine1(
  project: String,
  planName: String?,
  model: String,
  contextUsage: StatusInput.ContextWindow?,
  account: String?
) {
  var parts: [String] = ["\(ANSIColor.bold)\(project)\(ANSIColor.reset)"]

  if let planName = planName {
    parts.append("\(ANSIColor.cyan)📋 \(planName)\(ANSIColor.reset)")
  }

  parts.append(model)

  // Context percentage
  if let usage = contextUsage?.currentUsage,
    let size = contextUsage?.contextWindowSize,
    size > 0
  {
    let pct = (usage.totalTokens * 100) / size
    parts.append("\(pct)% ctx")
  }

  // Account
  if let account = account, !account.isEmpty {
    parts.append("\(ANSIColor.dim)\(ANSIColor.italic)\(account)\(ANSIColor.reset)")
  }

  print(parts.joined(separator: " │ "))
}

// MARK: - Line 2: PR Status

func printLine2(cwd: String, branch: String) async {
  guard let remoteURL = await getRemoteURL(cwd: cwd) else { return }
  let platform = Platform.detect(from: remoteURL)

  switch platform {
  case .github:
    await printGitHubPRStatus(cwd: cwd, branch: branch)
  case .azure:
    await printAzurePRStatus(cwd: cwd, branch: branch)
  case .gitlab:
    await printGitLabPRStatus(cwd: cwd, branch: branch)
  case .unknown:
    break
  }
}

func printGitHubPRStatus(cwd: String, branch: String) async {
  // Get PR info via gh CLI
  guard
    let output = await runCommandInDir(
      "gh",
      arguments: ["pr", "view", "--json", "number,state,statusCheckRollup,reviewDecision"],
      cwd: cwd
    )
  else { return }

  guard let prData = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
    let prNumber = prData["number"] as? Int,
    let prState = prData["state"] as? String
  else { return }

  // Get comment counts
  let commentInfo = await getCommentInfo(prNumber: prNumber, cwd: cwd, platform: .github)

  // Parse checks
  let checks = prData["statusCheckRollup"] as? [[String: Any]] ?? []
  let (statusText, statusColor, success, failure, pending) = parseChecks(checks)

  // Check for CHANGES_REQUESTED
  let reviewDecision = prData["reviewDecision"] as? String
  var extraInfo = ""
  if reviewDecision == "CHANGES_REQUESTED" {
    extraInfo = " │ 🚨 changes requested"
  }

  if !checks.isEmpty {
    print(
      "  PR #\(prNumber) (\(prState)) │ Checks: \(statusColor)\(statusText)\(ANSIColor.reset) [✓\(success) ✗\(failure) ⧗\(pending)]\(extraInfo)\(commentInfo)"
    )
  } else {
    print("  PR #\(prNumber) (\(prState)) │ No checks\(extraInfo)\(commentInfo)")
  }
}

func printAzurePRStatus(cwd: String, branch: String) async {
  // Get PR info via az CLI
  guard
    let output = await runCommandInDir(
      "az",
      arguments: ["repos", "pr", "list", "--source-branch", branch, "--status", "active", "-o", "json"],
      cwd: cwd
    )
  else { return }

  guard let prs = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
    let pr = prs.first,
    let prId = pr["pullRequestId"] as? Int,
    let prStatus = pr["status"] as? String
  else { return }

  // Get comment counts
  let commentInfo = await getCommentInfo(prNumber: prId, cwd: cwd, platform: .azure)

  // Azure doesn't have built-in CI checks like GitHub, skip check status
  print("  PR #\(prId) (\(prStatus))\(commentInfo)")
}

func printGitLabPRStatus(cwd: String, branch: String) async {
  // Get MR info via glab CLI
  guard
    let output = await runCommandInDir(
      "glab",
      arguments: ["mr", "view", "--json", "iid,state"],
      cwd: cwd
    )
  else { return }

  guard let mrData = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
    let mrNumber = mrData["iid"] as? Int,
    let mrState = mrData["state"] as? String
  else { return }

  // Get comment counts
  let commentInfo = await getCommentInfo(prNumber: mrNumber, cwd: cwd, platform: .gitlab)

  print("  MR !\(mrNumber) (\(mrState))\(commentInfo)")
}

func getCommentInfo(prNumber: Int, cwd: String, platform: Platform) async -> String {
  // Use pull-request-ping library to get comment counts
  let factory = ProviderFactory()

  let providerType: ProviderType
  switch platform {
  case .github: providerType = .github
  case .azure: providerType = .azure
  case .gitlab: providerType = .gitlab
  case .unknown: return ""
  }

  do {
    let provider = try await factory.createProvider(manualType: providerType)
    let pr = try await provider.fetchPR(identifier: String(prNumber), repo: nil)

    // Count unresolved comments
    let unresolvedReviews = pr.reviews.filter { review in
      if let comments = review.comments {
        return comments.contains { $0.isResolved == false }
      }
      return false
    }

    let unresolvedCount = unresolvedReviews.flatMap { $0.comments ?? [] }
      .filter { $0.isResolved == false }.count

    // Check for critical keywords
    let allCommentBodies = pr.comments.map(\.body) + pr.reviews.compactMap(\.body)
    let criticalKeywords = ["BLOCKING", "CRITICAL", "REQUIRED", "🚨"]
    let criticalCount = allCommentBodies.filter { body in
      criticalKeywords.contains { body.uppercased().contains($0.uppercased()) }
    }.count

    if criticalCount > 0 {
      return " │ 🚨 \(criticalCount) critical │ 💬 \(unresolvedCount) unresolved"
    } else if unresolvedCount > 0 {
      return " │ 💬 \(unresolvedCount) unresolved"
    }
  } catch {
    // Fall back silently - comment info is optional enhancement
  }

  return ""
}

func parseChecks(_ checks: [[String: Any]]) -> (String, String, Int, Int, Int) {
  var success = 0
  var failure = 0
  var pending = 0

  for check in checks {
    let conclusion = check["conclusion"] as? String ?? ""
    let status = check["status"] as? String ?? ""

    if conclusion == "SUCCESS" {
      success += 1
    } else if conclusion == "FAILURE" {
      failure += 1
    } else if conclusion.isEmpty || status != "COMPLETED" {
      pending += 1
    }
  }

  let statusText: String
  let statusColor: String

  if failure > 0 {
    statusText = "FAILING"
    statusColor = ANSIColor.red
  } else if pending > 0 {
    statusText = "PENDING"
    statusColor = ANSIColor.yellow
  } else {
    statusText = "PASSING"
    statusColor = ANSIColor.green
  }

  return (statusText, statusColor, success, failure, pending)
}

// MARK: - Line 3: Graphite Stack

func printLine3(cwd: String) async {
  // Get Graphite stack via gt ls -s
  guard let output = await runCommandInDir("gt", arguments: ["ls", "-s"], cwd: cwd)
  else { return }

  let lines = output.split(separator: "\n")
  var stackParts: [String] = []

  for line in lines {
    let lineStr = String(line)

    if lineStr.hasPrefix("◉") {
      let branch = String(lineStr.dropFirst(1)).trimmingCharacters(in: CharacterSet.whitespaces)
      stackParts.append("◉ \(branch)")
    } else if lineStr.hasPrefix("◯") {
      let branch = String(lineStr.dropFirst(1)).trimmingCharacters(in: CharacterSet.whitespaces)
      stackParts.append("○ \(branch)")
    }
  }

  if stackParts.count > 1 {
    let stackDisplay = stackParts.joined(separator: " → ")
    print("  \(ANSIColor.dim)\(stackDisplay)\(ANSIColor.reset)")
  }
}
