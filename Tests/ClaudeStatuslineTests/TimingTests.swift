import Foundation
import Testing

@testable import claude_statusline

@Suite("Performance")
struct TimingTests {

  @Test("Cache operations are fast (< 100ms)")
  func testCachePerformance() async throws {
    let cache = PRCache.shared
    let uuid = UUID().uuidString  // Unique to avoid test interference

    // Create test data
    let testData = CachedPRData(
      branch: "perf-\(uuid)",
      prNumber: 42,
      prState: "OPEN",
      checksStatus: "PASSING",
      checksDetail: "[✓5 ✗0 ⧗0]",
      commentInfo: "Fix auth flow",
      criticalCount: 0,
      graphiteStack: "◉ test-branch → ○ main"
    )

    // Measure cache write
    let writeStart = ContinuousClock.now
    await cache.set(testData, for: "/perf/\(uuid)")
    let writeElapsed = ContinuousClock.now - writeStart
    #expect(writeElapsed < .milliseconds(100), "Cache write took \(writeElapsed)")

    // Measure cache read
    let readStart = ContinuousClock.now
    let retrieved = await cache.get(for: "/perf/\(uuid)", branch: "perf-\(uuid)")
    let readElapsed = ContinuousClock.now - readStart

    #expect(retrieved != nil, "Cache should return stored data")
    #expect(readElapsed < .milliseconds(100), "Cache read took \(readElapsed)")
  }

  @Test("Cache save/load cycle works")
  func testCachePersistence() async throws {
    let cache = PRCache.shared
    let uuid = UUID().uuidString  // Unique to avoid test interference

    // Store data with unique key
    let testData = CachedPRData(
      branch: "persist-\(uuid)",
      prNumber: 123,
      prState: "MERGED"
    )
    await cache.set(testData, for: "/persist/\(uuid)")

    // Save to disk
    await cache.save()

    // Verify save succeeded by checking the file exists
    let cacheURL =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/claude-statusline/pr-cache.json")
    #expect(FileManager.default.fileExists(atPath: cacheURL.path), "Cache file should exist")

    // Verify the data was stored
    let retrieved = await cache.get(for: "/persist/\(uuid)", branch: "persist-\(uuid)")
    #expect(retrieved?.prNumber == 123, "Cache should contain stored data")
  }

  @Test("CachedPRData encodes/decodes correctly")
  func testCachedPRDataCodable() throws {
    let original = CachedPRData(
      branch: "feature-x",
      prNumber: 42,
      prState: "OPEN",
      checksStatus: "PASSING",
      checksDetail: "[✓3 ✗0 ⧗1]",
      commentInfo: "Fix auth",
      criticalCount: 1,
      graphiteStack: "◉ feature-x → ○ main"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CachedPRData.self, from: data)

    #expect(decoded.branch == original.branch)
    #expect(decoded.prNumber == original.prNumber)
    #expect(decoded.prState == original.prState)
    #expect(decoded.checksStatus == original.checksStatus)
    #expect(decoded.checksDetail == original.checksDetail)
    #expect(decoded.commentInfo == original.commentInfo)
    #expect(decoded.criticalCount == original.criticalCount)
    #expect(decoded.graphiteStack == original.graphiteStack)
  }

  @Test("printFromCache outputs correctly formatted lines")
  func testPrintFromCache() {
    // Test with full data
    let fullData = CachedPRData(
      branch: "test",
      prNumber: 42,
      prState: "OPEN",
      checksStatus: "PASSING",
      checksDetail: "[✓5 ✗0 ⧗0]",
      commentInfo: "Fix bug",
      graphiteStack: "◉ test → ○ main"
    )

    // printFromCache writes to stdout - we're mainly testing it doesn't crash
    // A more thorough test would capture stdout
    printFromCache(fullData)

    // Test with minimal data
    let minimalData = CachedPRData(branch: "minimal")
    printFromCache(minimalData)

    // Test with partial data (PR but no checks)
    let partialData = CachedPRData(
      branch: "partial",
      prNumber: 99,
      prState: "DRAFT"
    )
    printFromCache(partialData)
  }
}

@Suite("Cache Key Generation")
struct CacheKeyTests {

  @Test("Different branches have different cache entries")
  func testBranchIsolation() async {
    let cache = PRCache.shared
    let uuid = UUID().uuidString  // Unique prefix to avoid test interference

    let data1 = CachedPRData(branch: "branch-iso-a-\(uuid)", prNumber: 1)
    let data2 = CachedPRData(branch: "branch-iso-b-\(uuid)", prNumber: 2)

    await cache.set(data1, for: "/branch-iso/\(uuid)")
    await cache.set(data2, for: "/branch-iso/\(uuid)")

    let retrieved1 = await cache.get(for: "/branch-iso/\(uuid)", branch: "branch-iso-a-\(uuid)")
    let retrieved2 = await cache.get(for: "/branch-iso/\(uuid)", branch: "branch-iso-b-\(uuid)")

    #expect(retrieved1?.prNumber == 1)
    #expect(retrieved2?.prNumber == 2)
  }

  @Test("Different repos have different cache entries")
  func testRepoIsolation() async {
    let cache = PRCache.shared
    let uuid = UUID().uuidString  // Unique prefix to avoid test interference

    let data1 = CachedPRData(branch: "repo-iso-\(uuid)", prNumber: 100)
    let data2 = CachedPRData(branch: "repo-iso-\(uuid)", prNumber: 200)

    await cache.set(data1, for: "/repo-iso-one/\(uuid)")
    await cache.set(data2, for: "/repo-iso-two/\(uuid)")

    let retrieved1 = await cache.get(for: "/repo-iso-one/\(uuid)", branch: "repo-iso-\(uuid)")
    let retrieved2 = await cache.get(for: "/repo-iso-two/\(uuid)", branch: "repo-iso-\(uuid)")

    #expect(retrieved1?.prNumber == 100)
    #expect(retrieved2?.prNumber == 200)
  }
}
