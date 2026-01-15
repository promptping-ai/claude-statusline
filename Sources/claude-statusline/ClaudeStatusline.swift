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

    // Build Line 1: Main status (always fast, no caching needed)
    printLine1(
      project: project,
      planName: planName,
      model: input?.model.displayName ?? (test ? "Test" : "Claude"),
      contextUsage: input?.contextWindow,
      account: ProcessInfo.processInfo.environment["CLAUDE_ACCOUNT"]
    )

    // Cache-first strategy for Line 2 & 3
    guard let branch = branch else { return }

    // Load cache and check for hit
    await PRCache.shared.load()
    let cached = await PRCache.shared.get(for: cwd, branch: branch)

    if let cached = cached {
      // Cache hit: print from cache immediately
      if debugMode {
        debugLog("Cache hit for \(cwd):\(branch)")
        if let age = await PRCache.shared.age(for: cwd, branch: branch) {
          debugLog("Cache age: \(Int(age))s")
        }
      }
      printFromCache(cached)

      // Background refresh for next time (fire-and-forget after printing cached data)
      Task {
        let freshData = await fetchFreshPRData(
          cwd: cwd,
          branch: branch,
          platform: platform,
          remoteURL: remoteURL
        )
        await PRCache.shared.set(freshData, for: cwd)
        await PRCache.shared.save()
      }
    } else {
      // Cache miss: fetch with timeout to ensure Lines 2 & 3 are printed
      if debugMode {
        debugLog("Cache miss for \(cwd):\(branch)")
      }

      do {
        let freshData = try await withTimeout(seconds: 4.0) {
          await fetchFreshPRData(
            cwd: cwd,
            branch: branch,
            platform: platform,
            remoteURL: remoteURL
          )
        }

        // Cache the result for future runs
        await PRCache.shared.set(freshData, for: cwd)
        await PRCache.shared.save()

        // Print immediately
        printFromCache(freshData)
      } catch is TimeoutError {
        if debugMode {
          debugLog("Fetch timed out after 3 seconds")
        }
        // Timeout: show nothing for Lines 2 & 3 (graceful degradation)
      } catch {
        if debugMode {
          debugLog("Fetch failed: \(error)")
        }
        // Other error: show nothing for Lines 2 & 3
      }
    }
  }
}

// MARK: - Timeout Utilities

/// Error thrown when an operation exceeds the timeout duration
struct TimeoutError: Error {}

/// Execute an async operation with a maximum timeout duration
///
/// If the operation completes within the timeout, returns its result.
/// If the timeout is exceeded, throws TimeoutError and cancels the operation.
func withTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: Optional<T>.self) { group in
    // Add the main operation
    group.addTask {
      try await operation()
    }

    // Add timeout task
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw TimeoutError()
    }

    // Return first result (whichever completes first)
    if let result = try await group.next() {
      group.cancelAll()
      return result!
    }

    group.cancelAll()
    throw TimeoutError()
  }
}

// MARK: - Cache Output

/// Print Line 2 & 3 from cached data
func printFromCache(_ data: CachedPRData) {
  // Line 2: PR status
  if let prNumber = data.prNumber, let prState = data.prState {
    var line2Parts = ["  PR #\(prNumber) (\(prState))"]

    if let checksStatus = data.checksStatus, let checksDetail = data.checksDetail {
      let color =
        checksStatus == "PASSING"
        ? ANSIColor.green
        : (checksStatus == "FAILING" ? ANSIColor.red : ANSIColor.yellow)
      line2Parts.append("Checks: \(color)\(checksStatus)\(ANSIColor.reset) \(checksDetail)")
    }

    if let commentInfo = data.commentInfo, !commentInfo.isEmpty {
      line2Parts.append(commentInfo)
    }

    print(line2Parts.joined(separator: " │ "))
  }

  // Line 3: Graphite stack
  if let stack = data.graphiteStack, !stack.isEmpty {
    print("  \(ANSIColor.dim)\(stack)\(ANSIColor.reset)")
  }
}

// MARK: - Fresh Data Fetching

/// Fetch fresh PR data for caching
func fetchFreshPRData(
  cwd: String,
  branch: String,
  platform: Platform,
  remoteURL: String?
) async -> CachedPRData {
  var prNumber: Int?
  var prState: String?
  var checksStatus: String?
  var checksDetail: String?
  var commentInfo: String?
  var criticalCount = 0
  var graphiteStack: String?

  // Fetch PR data based on platform (only if not on main)
  if branch != "main" {
    switch platform {
    case .github:
      let prData = await fetchGitHubPRData(cwd: cwd, branch: branch)
      prNumber = prData.prNumber
      prState = prData.prState
      checksStatus = prData.checksStatus
      checksDetail = prData.checksDetail
      commentInfo = prData.commentInfo
      criticalCount = prData.criticalCount

    case .azure:
      if let url = remoteURL {
        let prData = await fetchAzurePRData(cwd: cwd, branch: branch, remoteURL: url)
        prNumber = prData.prNumber
        prState = prData.prState
        checksStatus = prData.checksStatus
        checksDetail = prData.checksDetail
        commentInfo = prData.commentInfo
        criticalCount = prData.criticalCount
      }

    case .gitlab:
      let prData = await fetchGitLabPRData(cwd: cwd, branch: branch)
      prNumber = prData.prNumber
      prState = prData.prState
      commentInfo = prData.commentInfo
      criticalCount = prData.criticalCount

    case .unknown:
      break
    }
  }

  // Fetch Graphite stack
  graphiteStack = await fetchGraphiteStack(cwd: cwd)

  return CachedPRData(
    branch: branch,
    prNumber: prNumber,
    prState: prState,
    checksStatus: checksStatus,
    checksDetail: checksDetail,
    commentInfo: commentInfo,
    criticalCount: criticalCount,
    graphiteStack: graphiteStack
  )
}

// MARK: - Platform-specific PR Data Fetching

struct PRFetchResult {
  var prNumber: Int?
  var prState: String?
  var checksStatus: String?
  var checksDetail: String?
  var commentInfo: String?
  var criticalCount: Int = 0
}

func fetchGitHubPRData(cwd: String, branch: String) async -> PRFetchResult {
  var result = PRFetchResult()

  guard
    let output = await runCommandInDir(
      "gh",
      arguments: ["pr", "view", "--json", "number,state,statusCheckRollup,reviewDecision"],
      cwd: cwd
    )
  else { return result }

  guard let prData = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
    let prNumber = prData["number"] as? Int,
    let prState = prData["state"] as? String
  else { return result }

  result.prNumber = prNumber
  result.prState = prState

  // Parse checks
  let checks = prData["statusCheckRollup"] as? [[String: Any]] ?? []
  if !checks.isEmpty {
    let (statusText, _, success, failure, pending) = parseChecks(checks)
    result.checksStatus = statusText
    result.checksDetail = "[✓\(success) ✗\(failure) ⧗\(pending)]"
  }

  // Get comment info
  result.commentInfo = await getCommentInfo(prNumber: prNumber, cwd: cwd, platform: .github)

  return result
}

func fetchAzurePRData(cwd: String, branch: String, remoteURL: String) async -> PRFetchResult {
  var result = PRFetchResult()

  guard let azureContext = parseAzureContext(from: remoteURL) else { return result }

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
  else { return result }

  guard let prs = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
    let pr = prs.first,
    let prId = pr["pullRequestId"] as? Int,
    let prStatus = pr["status"] as? String
  else { return result }

  result.prNumber = prId
  result.prState = prStatus

  // Get pipeline status
  let pipelineInfo = await getAzurePipelineStatus(
    cwd: cwd,
    branch: branch,
    azureContext: azureContext
  )
  if !pipelineInfo.isEmpty {
    // Parse pipeline info for status/detail
    if pipelineInfo.contains("PASSING") {
      result.checksStatus = "PASSING"
    } else if pipelineInfo.contains("FAILING") {
      result.checksStatus = "FAILING"
    } else if pipelineInfo.contains("PENDING") {
      result.checksStatus = "PENDING"
    }
    // Extract detail portion
    if let bracketStart = pipelineInfo.firstIndex(of: "["),
      let bracketEnd = pipelineInfo.lastIndex(of: "]")
    {
      result.checksDetail = String(pipelineInfo[bracketStart...bracketEnd])
    }
  }

  // Get comment info
  result.commentInfo = await getCommentInfo(prNumber: prId, cwd: cwd, platform: .azure)

  return result
}

func fetchGitLabPRData(cwd: String, branch: String) async -> PRFetchResult {
  var result = PRFetchResult()

  guard
    let output = await runCommandInDir(
      "glab",
      arguments: ["mr", "view", "--json", "iid,state"],
      cwd: cwd
    )
  else { return result }

  guard let mrData = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
    let mrNumber = mrData["iid"] as? Int,
    let mrState = mrData["state"] as? String
  else { return result }

  result.prNumber = mrNumber
  result.prState = mrState

  // Get comment info
  result.commentInfo = await getCommentInfo(prNumber: mrNumber, cwd: cwd, platform: .gitlab)

  return result
}

func fetchGraphiteStack(cwd: String) async -> String? {
  guard let output = await runCommandInDir("gt", arguments: ["ls", "-s"], cwd: cwd)
  else { return nil }

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

  return stackParts.count > 1 ? stackParts.joined(separator: " → ") : nil
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

/// Extract repository name from Azure DevOps remote URL
/// Supports both SSH and HTTPS formats
func extractAzureRepoName(from url: String) -> String? {
  // SSH format: git@ssh.dev.azure.com:v3/org/project/RepoName
  if url.hasPrefix("git@ssh.dev.azure.com:v3/") {
    let path = String(url.dropFirst("git@ssh.dev.azure.com:v3/".count))
    let components = path.split(separator: "/")
    // components: ["org", "project", "RepoName"]
    if components.count >= 3 {
      return String(components[2])
    }
  }

  // HTTPS format: https://dev.azure.com/org/project/_git/RepoName
  if url.contains("dev.azure.com") && url.contains("/_git/") {
    let components = url.components(separatedBy: "/_git/")
    if components.count >= 2 {
      return components[1]  // Return everything after /_git/
    }
  }

  // Legacy format: https://org.visualstudio.com/project/_git/RepoName
  if url.contains(".visualstudio.com") && url.contains("/_git/") {
    let components = url.components(separatedBy: "/_git/")
    if components.count >= 2 {
      return components[1]  // Return everything after /_git/
    }
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
func cacheComments(
  platform: Platform, cwd: String, prNumber: Int, unresolvedCount: Int, criticalCount: Int
) {
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

// MARK: - Summary Cache (EdgePrompt Results)

/// Cached edgeprompt summary to avoid repeated LLM calls
struct SummaryCache: Codable, Sendable {
  let textHash: String
  let summary: String
  let timestamp: Date

  /// Check if cache is still valid (1 hour TTL)
  var isValid: Bool {
    Date().timeIntervalSince(timestamp) < 3600
  }
}

/// Read cached summary if valid (instant, no LLM cost)
func getCachedSummary(textHash: String) -> String? {
  let cacheFile = getCacheDirectory().appendingPathComponent("summary-\(textHash).json")

  guard let data = try? Data(contentsOf: cacheFile),
    let cache = try? JSONDecoder().decode(SummaryCache.self, from: data),
    cache.isValid
  else { return nil }

  return cache.summary
}

/// Write edgeprompt summary to cache (runs in background)
func cacheSummary(textHash: String, summary: String) {
  Task.detached(priority: .utility) {
    let cacheFile = getCacheDirectory().appendingPathComponent("summary-\(textHash).json")
    let cache = SummaryCache(
      textHash: textHash,
      summary: summary,
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

// MARK: - EdgePrompt Integration

/// Summarize text using edgeprompt CLI (local LLM, 0 tokens) with caching and timeout
/// Returns nil if edgeprompt unavailable or fails (graceful degradation)
func summarizeWithEdgePrompt(_ text: String, maxWords: Int = 10) async -> String? {
  guard !text.isEmpty else { return nil }

  // Use hash of input text as cache key
  let textHash = text.hashValue.description

  // Check cache first (instant, no LLM cost)
  if let cached = getCachedSummary(textHash: textHash) {
    if debugMode {
      debugLog("Summary cache hit for hash: \(textHash)")
    }
    return cached
  }

  do {
    // Wrap in timeout (2 seconds max)
    return try await withTimeout(seconds: 2.0) {
      let result = try await Subprocess.run(
        .name("edgeprompt"),
        arguments: Arguments(["summarize", "--max-length", String(maxWords), "--json"]),
        input: .string(text),
        output: .bytes(limit: 1024 * 1024),
        error: .discarded
      )

      guard result.terminationStatus.isSuccess else { return nil }

      let outputString = String(decoding: result.standardOutput, as: UTF8.self)

      // Parse JSON response for "summary" field
      guard let jsonData = outputString.data(using: String.Encoding.utf8),
        let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
        let summary = json["summary"] as? String
      else { return nil }

      // Clean up the summary (remove trailing markers and newlines for single-line output)
      let cleanSummary =
        summary
        .replacingOccurrences(of: " [Summary generated by local LLM]", with: "")
        .replacingOccurrences(of: "...", with: "")
        .replacingOccurrences(of: "\n", with: " ")  // Newlines break multi-line statusline format
        .replacingOccurrences(of: "  ", with: " ")  // Collapse double spaces from newline removal
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

      if !cleanSummary.isEmpty {
        // Cache the result for next time (background)
        cacheSummary(textHash: textHash, summary: cleanSummary)
        return cleanSummary
      }
      return nil
    }
  } catch is TimeoutError {
    if debugMode {
      debugLog("EdgePrompt timed out after 2 seconds")
    }
    return nil
  } catch {
    if debugMode {
      debugLog("EdgePrompt failed: \(error)")
    }
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

  // Extract repository name from remote URL to filter PRs to current repo only
  let repoName = extractAzureRepoName(from: remoteURL)

  // Build az CLI arguments with optional repository filter
  var arguments = [
    "repos", "pr", "list",
    "--source-branch", branch,
    "--status", "active",
    "--organization", azureContext.organizationURL,
    "--project", azureContext.project,
  ]

  // Add repository filter if we can extract it (prevents wrong PR from different repo in same project)
  if let repo = repoName {
    arguments.append(contentsOf: ["--repository", repo])
  }

  arguments.append(contentsOf: ["-o", "json"])

  // Get PR info via az CLI with explicit org/project and optional repository filter
  guard
    let output = await runCommandInDir(
      "az",
      arguments: arguments,
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

  return
    "Builds: \(statusColor)\(statusText)\(ANSIColor.reset) [✓\(success) ✗\(failure) ⧗\(pending)]"
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
    return formatCommentInfo(
      unresolvedCount: cached.unresolvedCount, criticalCount: cached.criticalCount)
  }

  // Fetch synchronously for all platforms - we have a 3s overall timeout
  // that prevents the statusline from blocking too long
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

    // Count unresolved comments and collect their bodies
    let unresolvedComments = pr.reviews.flatMap { $0.comments ?? [] }
      .filter { $0.isResolved == false }
    let unresolvedCount = unresolvedComments.count
    let unresolvedBodies = unresolvedComments.map(\.body)

    // Filter out notification-type messages (Azure activity, not actual review comments)
    // These include: reviewer additions, approvals, status changes, empty bodies
    let actualReviewComments = unresolvedBodies.filter { body in
      let lowerBody = body.lowercased()
      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

      // Exclude Azure notification patterns
      let isNotification =
        (lowerBody.contains("added") && lowerBody.contains("as a reviewer"))
        || (lowerBody.contains("approved") && lowerBody.contains("pull request"))
        || (lowerBody.contains("requested changes"))
        || (lowerBody.contains("voted") && lowerBody.contains("on the pull request"))
        || (lowerBody.contains("reset") && lowerBody.contains("vote"))
        || trimmedBody.isEmpty

      return !isNotification
    }

    // Check for critical keywords
    let allCommentBodies = pr.comments.map(\.body) + pr.reviews.compactMap(\.body)
    let criticalKeywords = ["BLOCKING", "CRITICAL", "REQUIRED", "🚨"]
    let criticalCount = allCommentBodies.filter { body in
      criticalKeywords.contains { body.uppercased().contains($0.uppercased()) }
    }.count

    // Try EdgePrompt summarization if there are actual review comments (not just notifications)
    if !actualReviewComments.isEmpty {
      let combinedText = actualReviewComments.joined(separator: "\n\n")
      if let summary = await summarizeWithEdgePrompt(combinedText, maxWords: 15) {
        if criticalCount > 0 {
          return " │ 🚨 \(criticalCount) critical │ 💬 \(summary)"
        }
        return " │ 💬 \(summary)"
      }
    }

    // Fallback: count-based display if EdgePrompt unavailable
    if criticalCount > 0 {
      return " │ 🚨 \(criticalCount) critical │ 💬 \(unresolvedCount) unresolved"
    } else if unresolvedCount > 0 {
      return " │ 💬 \(unresolvedCount) unresolved"
    }
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
