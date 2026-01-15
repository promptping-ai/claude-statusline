# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-statusline** is a Swift CLI tool that generates an enhanced multi-line status output for Claude Code. It reads JSON from stdin (Claude Code status information) and outputs a formatted three-line statusline:

- **Line 1:** Project name, plan subject, AI model, context usage %, account
- **Line 2:** PR status with checks, comments, and critical issues (GitHub/Azure DevOps/GitLab)
- **Line 3:** Graphite stacked branch visualization

## Build Commands

```bash
# Build
swift build

# Test
swift test

# Release build
swift build -c release

# Format check
swift format lint -s -p -r Sources Tests Package.swift

# Auto-format
swift format format -p -r -i Sources Tests Package.swift

# Install globally
swift package experimental-install

# Run locally with test input
echo '{"working_directory":"/path/to/repo","model":{"model_name":"opus"}}' | ./.build/debug/claude-statusline
```

## Architecture

### Data Flow

```
stdin JSON → StatusInput parsing → Git/CLI commands → PR data fetch → 3-line formatted output
```

### Key Components (ClaudeStatusline.swift)

| Section | Lines | Purpose |
|---------|-------|---------|
| Input Parsing | 68-122 | `StatusInput` Codable struct with nested `Workspace`, `Model`, `ContextWindow` |
| Platform Detection | 139-155 | `Platform` enum detecting GitHub/Azure/GitLab from remote URL |
| Command Execution | 159-195 | `runCommand()` / `runCommandInDir()` using async `Subprocess` |
| Line 1 (Main) | 220-280 | Project, plan (from `~/.claude/.session-plans.json`), model, context% |
| Line 2 (PR) | 280-400 | Platform-specific PR info via `pull-request-ping` library |
| Line 3 (Stack) | 400-461 | Graphite stack from `gt ls -s` output |

### External CLI Dependencies

The tool shells out to these commands (must be available in PATH):
- `git` - Branch and remote queries
- `gh` - GitHub PR info (JSON output)
- `az` - Azure DevOps PR list
- `glab` - GitLab MR info
- `gt` - Graphite stack visualization

## Testing

Uses **Swift Testing framework** (not XCTest):

```swift
@Test func testFeature() {
    #expect(value == expected)
}
```

Test coverage includes:
- `StatusInput` JSON parsing (minimal and full inputs)
- Platform detection for all supported platforms
- ANSI color code generation

## Dependencies

| Package | Purpose |
|---------|---------|
| `pull-request-ping` | Multi-platform PR API abstraction |
| `swift-argument-parser` | CLI argument parsing |
| `swift-subprocess` | Async process execution |

## Key Patterns

- **Graceful degradation** - Commands return `nil` on failure, output adapts
- **ANSI colors** - Terminal formatting via escape codes (lines 125-135)
- **Async/await** - All subprocess execution is async
- **Platform abstraction** - `ProviderFactory` from `pull-request-ping` handles PR API differences
