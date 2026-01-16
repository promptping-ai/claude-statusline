import Foundation

// MARK: - Cached Data Model

/// Cached PR and status data for a repository
public struct CachedPRData: Codable, Sendable {
  public let branch: String
  public let prNumber: Int?
  public let prState: String?
  public let checksStatus: String?
  public let checksDetail: String?
  public let commentInfo: String?
  public let criticalCount: Int
  public let graphiteStack: String?
  public let updatedAt: Date

  public init(
    branch: String,
    prNumber: Int? = nil,
    prState: String? = nil,
    checksStatus: String? = nil,
    checksDetail: String? = nil,
    commentInfo: String? = nil,
    criticalCount: Int = 0,
    graphiteStack: String? = nil,
    updatedAt: Date = Date()
  ) {
    self.branch = branch
    self.prNumber = prNumber
    self.prState = prState
    self.checksStatus = checksStatus
    self.checksDetail = checksDetail
    self.commentInfo = commentInfo
    self.criticalCount = criticalCount
    self.graphiteStack = graphiteStack
    self.updatedAt = updatedAt
  }
}

// MARK: - Cache Manager

/// Thread-safe cache manager for PR status data
/// Uses actor isolation to prevent data races
public actor PRCache {
  public static let shared = PRCache()

  private let cacheURL: URL
  private var cache: [String: CachedPRData] = [:]
  private var isLoaded = false

  private init() {
    // Store in ~/.cache/claude-statusline/pr-cache.json
    let cacheDir =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/claude-statusline")
    self.cacheURL = cacheDir.appendingPathComponent("pr-cache.json")
  }

  /// Generate cache key from repo path and branch
  private func cacheKey(path: String, branch: String) -> String {
    "\(path):\(branch)"
  }

  /// Get cached data for a repo/branch combination
  public func get(for path: String, branch: String) -> CachedPRData? {
    let key = cacheKey(path: path, branch: branch)
    return cache[key]
  }

  /// Store data in cache
  public func set(_ data: CachedPRData, for path: String) {
    let key = cacheKey(path: path, branch: data.branch)
    cache[key] = data
  }

  /// Load cache from disk
  public func load() {
    guard !isLoaded else { return }
    isLoaded = true

    guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }

    do {
      let data = try Data(contentsOf: cacheURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      cache = try decoder.decode([String: CachedPRData].self, from: data)
    } catch {
      // Cache is optional - log and continue
      FileHandle.standardError.write(
        Data("[CACHE] Failed to load cache: \(error)\n".utf8)
      )
    }
  }

  /// Save cache to disk
  public func save() {
    do {
      // Create cache directory if needed
      let cacheDir = cacheURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: cacheDir,
        withIntermediateDirectories: true
      )

      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(cache)
      try data.write(to: cacheURL)
    } catch {
      // Cache is optional - log and continue
      FileHandle.standardError.write(
        Data("[CACHE] Failed to save cache: \(error)\n".utf8)
      )
    }
  }

  /// Clear all cached data
  public func clear() {
    cache.removeAll()
  }

  /// Get age of cached data in seconds
  public func age(for path: String, branch: String) -> TimeInterval? {
    guard let data = get(for: path, branch: branch) else { return nil }
    return Date().timeIntervalSince(data.updatedAt)
  }
}
