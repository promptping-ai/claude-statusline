import ArgumentParser
import Foundation
import PullRequestPing
import Subprocess

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// Global debug mode flag (set from command line)
/// Using nonisolated(unsafe) as this is a single-threaded CLI tool
nonisolated(unsafe) var debugMode = false

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

      Use --test to run without stdin (uses current directory):
        cd /path/to/project && claude-statusline --test --debug
      """
  )

  @Flag(name: .long, help: "Output diagnostic information to stderr")
  var debug = false

  @Flag(name: .long, help: "Test mode: use current directory instead of stdin input")
  var test = false

  func run() async throws {
    // Set global debug mode
    debugMode = debug

    if debug {
      debugLog("=== Claude Statusline Starting ===")
      debugLog("Debug mode: enabled")
      debugLog("Test mode: \(test)")
    }

    let cwd: String
    let project: String
    var input: StatusInput?

    if test {
      // Test mode: use current working directory
      cwd = FileManager.default.currentDirectoryPath
      project = URL(fileURLWithPath: cwd).lastPathComponent
      input = nil
      if debug {
        debugLog("Using current directory (test mode)")
      }
    } else {
      // Normal mode: read JSON from stdin
      if debug {
        debugLog("Reading JSON from stdin...")
      }
      let inputData = FileHandle.standardInput.readDataToEndOfFile()
      guard let parsedInput = try? JSONDecoder().decode(StatusInput.self, from: inputData)
      else {
        print("Error: Invalid JSON input")
        return
      }
      input = parsedInput
      cwd = parsedInput.workspace.currentDir
      project = URL(fileURLWithPath: cwd).lastPathComponent
    }

    // Get branch name
    let branch = await getBranch(cwd: cwd)

    // Get remote URL for platform detection
    let remoteURL = await getRemoteURL(cwd: cwd)
    let platform = remoteURL.map { Platform.detect(from: $0) } ?? .unknown

    // Debug output
    if debugMode {
      debugLog("=== Claude Statusline Debug ===")
      debugLog("CWD: \(cwd)")
      debugLog("Project: \(project)")
      debugLog("Branch: \(branch ?? "none")")
      debugLog("Remote URL: \(remoteURL ?? "none")")
      debugLog("Platform: \(platform)")
      if platform == .azure, let url = remoteURL {
        if let azureContext = parseAzureContext(from: url) {
          debugLog("Azure Org: \(azureContext.organization)")
          debugLog("Azure Project: \(azureContext.project)")
          debugLog("Azure Repo: \(azureContext.repository)")
        } else {
          debugLog("Azure Context: FAILED TO PARSE")
        }
      }
      debugLog("================================")
    }

    // Get plan subject from session mapping
    let planName = getPlanSubject(sessionId: input?.sessionId)

    // Build Line 1: Main status
    printLine1(
      project: project,
      planName: planName,
      model: input?.model.displayName ?? (test ? "Test" : "Claude"),
      contextUsage: input?.contextWindow,
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

/// Log debug message to stderr
func debugLog(_ message: String) {
  FileHandle.standardError.write(Data("[DEBUG] \(message)\n".utf8))
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

// MARK: - Azure DevOps Context

/// Holds parsed Azure DevOps organization, project, and repository info
struct AzureContext {
  let organization: String
  let project: String
  let repository: String

  /// Full organization URL for az CLI commands
  var organizationURL: String {
    "https://dev.azure.com/\(organization)"
  }
}

/// Parse Azure DevOps context from git remote URL
/// Supports patterns:
/// - https://username@dev.azure.com/org/project/_git/repo
/// - https://dev.azure.com/org/project/_git/repo
/// - git@ssh.dev.azure.com:v3/org/project/repo
func parseAzureContext(from remoteURL: String) -> AzureContext? {
  // Pattern 1: HTTPS with optional username
  // https://grouperossel@dev.azure.com/grouperossel/Le%20Soir/_git/iOS_Le_Soir
  // https://dev.azure.com/org/project/_git/repo
  if remoteURL.contains("dev.azure.com") && remoteURL.contains("/_git/") {
    // Remove https:// and optional username@
    var url = remoteURL
    if url.hasPrefix("https://") {
      url = String(url.dropFirst(8))
    }
    // Remove username@ if present
    if let atIndex = url.firstIndex(of: "@") {
      url = String(url[url.index(after: atIndex)...])
    }
    // Now: dev.azure.com/org/project/_git/repo
    let parts = url.split(separator: "/")
    // parts: ["dev.azure.com", "org", "project", "_git", "repo"]
    guard parts.count >= 5,
      parts[0] == "dev.azure.com",
      parts[3] == "_git"
    else { return nil }

    let org = String(parts[1])
    let project = String(parts[2]).removingPercentEncoding ?? String(parts[2])
    let repo = String(parts[4])
    return AzureContext(organization: org, project: project, repository: repo)
  }

  // Pattern 2: SSH
  // git@ssh.dev.azure.com:v3/org/project/repo
  if remoteURL.hasPrefix("git@ssh.dev.azure.com:v3/") {
    let path = String(remoteURL.dropFirst("git@ssh.dev.azure.com:v3/".count))
    let parts = path.split(separator: "/")
    // parts: ["org", "project", "repo"]
    guard parts.count >= 3 else { return nil }

    let org = String(parts[0])
    let project = String(parts[1])
    let repo = String(parts[2])
    return AzureContext(organization: org, project: project, repository: repo)
  }

  // Pattern 3: visualstudio.com (legacy)
  // https://org.visualstudio.com/project/_git/repo
  if remoteURL.contains(".visualstudio.com") && remoteURL.contains("/_git/") {
    var url = remoteURL
    if url.hasPrefix("https://") {
      url = String(url.dropFirst(8))
    }
    // org.visualstudio.com/project/_git/repo
    let parts = url.split(separator: "/")
    guard parts.count >= 4,
      parts[0].hasSuffix(".visualstudio.com"),
      parts[2] == "_git"
    else { return nil }

    // Extract org from subdomain
    let domain = String(parts[0])
    let org = String(domain.dropLast(".visualstudio.com".count))
    let project = String(parts[1])
    let repo = String(parts[3])
    return AzureContext(organization: org, project: project, repository: repo)
  }

  return nil
}

// MARK: - Comment Cache

/// Cached comment count for a PR to avoid slow API calls
struct CommentCache: Codable {
  let prNumber: Int
  let unresolvedCount: Int
  let criticalCount: Int
  let timestamp: Date

  /// Check if cache is still valid (5 minute TTL)
  var isValid: Bool {
    Date().timeIntervalSince(timestamp) < 300
  }
}

/// Get cache directory, creating if needed
private func getCacheDirectory() -> URL {
  let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/claude-statusline")
  try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
  return cacheDir
}

/// Generate cache key from platform, cwd, and PR number
private func cacheKey(platform: Platform, cwd: String, prNumber: Int) -> String {
  // Use a hash of cwd to keep filenames reasonable
  let cwdHash = cwd.hashValue
  return "\(platform)-\(cwdHash)-\(prNumber)"
}

/// Read cached comment count if valid
func getCachedComments(platform: Platform, cwd: String, prNumber: Int) -> CommentCache? {
  let key = cacheKey(platform: platform, cwd: cwd, prNumber: prNumber)
  let cacheFile = getCacheDirectory().appendingPathComponent("\(key).json")

  guard let data = try? Data(contentsOf: cacheFile),
        let cache = try? JSONDecoder().decode(CommentCache.self, from: data),
        cache.isValid
  else { return nil }

  return cache
}

/// Write comment count to cache (runs in background)
func cacheComments(platform: Platform, cwd: String, prNumber: Int, unresolvedCount: Int, criticalCount: Int) {
  Task.detached(priority: .utility) {
    let key = cacheKey(platform: platform, cwd: cwd, prNumber: prNumber)
    let cacheFile = getCacheDirectory().appendingPathComponent("\(key).json")
    let cache = CommentCache(
      prNumber: prNumber,
      unresolvedCount: unresolvedCount,
      criticalCount: criticalCount,
      timestamp: Date()
    )
    if let data = try? JSONEncoder().encode(cache) {
      try? data.write(to: cacheFile)
    }
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
    await printAzurePRStatus(cwd: cwd, branch: branch, remoteURL: remoteURL)
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

func printAzurePRStatus(cwd: String, branch: String, remoteURL: String) async {
  // Parse Azure context from remote URL
  guard let azureContext = parseAzureContext(from: remoteURL) else {
    FileHandle.standardError.write(
      Data("⚠️ Could not parse Azure context from: \(remoteURL)\n".utf8)
    )
    return
  }

  // Get PR info via az CLI with explicit org/project
  guard
    let output = await runCommandInDir(
      "az",
      arguments: [
        "repos", "pr", "list",
        "--source-branch", branch,
        "--status", "active",
        "--organization", azureContext.organizationURL,
        "--project", azureContext.project,
        "-o", "json",
      ],
      cwd: cwd
    )
  else {
    FileHandle.standardError.write(
      Data("⚠️ az repos pr list failed for \(azureContext.project)\n".utf8)
    )
    return
  }

  guard let prs = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
    let pr = prs.first,
    let prId = pr["pullRequestId"] as? Int,
    let prStatus = pr["status"] as? String
  else { return }

  // Get Azure Pipeline build status
  let pipelineInfo = await getAzurePipelineStatus(
    cwd: cwd,
    branch: branch,
    azureContext: azureContext
  )

  // Get comment counts
  let commentInfo = await getCommentInfo(prNumber: prId, cwd: cwd, platform: .azure)

  if !pipelineInfo.isEmpty {
    print("  PR #\(prId) (\(prStatus)) │ \(pipelineInfo)\(commentInfo)")
  } else {
    print("  PR #\(prId) (\(prStatus))\(commentInfo)")
  }
}

/// Fetch Azure Pipelines build status for current branch
func getAzurePipelineStatus(cwd: String, branch: String, azureContext: AzureContext) async
  -> String
{
  // Get recent pipeline runs for this branch
  guard
    let output = await runCommandInDir(
      "az",
      arguments: [
        "pipelines", "runs", "list",
        "--branch", branch,
        "--top", "5",
        "--organization", azureContext.organizationURL,
        "--project", azureContext.project,
        "-o", "json",
      ],
      cwd: cwd
    )
  else { return "" }

  guard let runs = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
  else { return "" }

  // Count results
  var success = 0
  var failure = 0
  var pending = 0

  for run in runs {
    let status = run["status"] as? String ?? ""
    let result = run["result"] as? String ?? ""

    if status == "completed" {
      switch result {
      case "succeeded":
        success += 1
      case "failed":
        failure += 1
      case "canceled", "partiallySucceeded":
        pending += 1
      default:
        pending += 1
      }
    } else if status == "inProgress" || status == "notStarted" {
      pending += 1
    }
  }

  guard success + failure + pending > 0 else { return "" }

  // Determine overall status
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

  return "Builds: \(statusColor)\(statusText)\(ANSIColor.reset) [✓\(success) ✗\(failure) ⧗\(pending)]"
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
  // Check cache first (instant, avoids slow API calls)
  if let cached = getCachedComments(platform: platform, cwd: cwd, prNumber: prNumber) {
    return formatCommentInfo(unresolvedCount: cached.unresolvedCount, criticalCount: cached.criticalCount)
  }

  // For Azure, return placeholder and fetch in background (Azure API is slow ~1.7s)
  if platform == .azure {
    // Trigger background fetch to populate cache for next call
    Task.detached(priority: .utility) {
      await fetchAndCacheComments(prNumber: prNumber, cwd: cwd, platform: platform)
    }
    return " │ 💬 ..."  // Placeholder while cache is being populated
  }

  // For GitHub/GitLab, fetch synchronously (fast enough)
  return await fetchAndCacheComments(prNumber: prNumber, cwd: cwd, platform: platform)
}

/// Fetch comments from API and cache the result
private func fetchAndCacheComments(prNumber: Int, cwd: String, platform: Platform) async -> String {
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

    // Cache the result for future calls
    cacheComments(
      platform: platform,
      cwd: cwd,
      prNumber: prNumber,
      unresolvedCount: unresolvedCount,
      criticalCount: criticalCount
    )

    return formatCommentInfo(unresolvedCount: unresolvedCount, criticalCount: criticalCount)
  } catch {
    // Log error to stderr for debugging (comment info is optional enhancement)
    FileHandle.standardError.write(
      Data("⚠️ Comment fetch failed for \(platform) PR #\(prNumber): \(error)\n".utf8)
    )
  }

  return ""
}

/// Format comment info string
private func formatCommentInfo(unresolvedCount: Int, criticalCount: Int) -> String {
  if criticalCount > 0 {
    return " │ 🚨 \(criticalCount) critical │ 💬 \(unresolvedCount) unresolved"
  } else if unresolvedCount > 0 {
    return " │ 💬 \(unresolvedCount) unresolved"
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
