# Testing Strategy

This document outlines the testing approach for HexBSD, demonstrating a commitment to software quality and modern Swift testing practices.

## Testing Frameworks

HexBSD uses both **Swift Testing** and **XCTest** to ensure comprehensive coverage and demonstrate familiarity with Apple's testing ecosystem.

### Swift Testing

The primary testing framework, chosen for its modern Swift-first design:

- **Declarative syntax** with `@Test` and `@Suite` attributes
- **Parameterized tests** using `arguments:` for data-driven testing
- **Expressive assertions** with `#expect` and `#require` macros
- **Better failure messages** with automatic expression expansion

Example:
```swift
@Test("Memory percentage calculation", arguments: [
    ("8 GB / 16 GB", 50.0),
    ("0 GB / 16 GB", 0.0),
    ("16 GB / 16 GB", 100.0),
])
func memoryPercentage(input: String, expected: Double) {
    #expect(SystemStatusParser.parseUsagePercentage(from: input) == expected)
}
```

### XCTest

Maintained for compatibility and to demonstrate proficiency with the traditional framework:

- Performance testing with `measure { }`
- Integration with Xcode's test navigator
- Familiar assertion patterns (`XCTAssertEqual`, `XCTAssertTrue`, etc.)

## Architecture for Testability

### Protocol-Based Dependency Injection

The `SSHConnectionProviding` protocol allows views and view models to accept any implementation:

```swift
protocol SSHConnectionProviding: AnyObject {
    var isConnected: Bool { get }
    func executeCommand(_ command: String) async throws -> String
    // ...
}
```

This enables:
- **Unit testing** with `MockSSHConnectionManager`
- **Integration testing** with real connections
- **Preview support** with stub implementations

### Extracted Business Logic

Parsing and validation logic is extracted into `SystemStatusParser`:

- Pure functions with no side effects
- Easy to test in isolation
- Clear input/output contracts

## Test Categories

### Unit Tests (`SystemStatusParserTests.swift`)

Test pure functions and parsing logic:
- Percentage parsing
- Usage ratio calculations
- Network rate parsing
- Host/port validation
- Uptime string parsing

### Integration Tests (`SSHConnectionTests.swift`)

Test component interactions using mocks:
- Connection lifecycle
- Command execution
- Error handling
- State management

### Performance Tests (`SystemStatusParserXCTests.swift`)

Ensure parsing operations remain efficient:
- Measure baseline performance
- Detect regressions in CI

## Running Tests

### Xcode

1. Open `HexBSD.xcodeproj`
2. Press `⌘U` to run all tests
3. View results in the Test Navigator (`⌘6`)

### Command Line

```bash
xcodebuild test \
    -project HexBSD.xcodeproj \
    -scheme HexBSD \
    -destination 'platform=macOS'
```

### Continuous Integration

Tests run automatically on every push and pull request via GitHub Actions. See `.github/workflows/tests.yml`.

## Writing New Tests

### Guidelines

1. **Test behavior, not implementation** - Focus on what the code does, not how
2. **Use descriptive test names** - Should read like documentation
3. **One assertion per test** - Makes failures easy to diagnose
4. **Arrange-Act-Assert pattern** - Clear test structure
5. **Prefer Swift Testing** for new tests - Modern syntax and better diagnostics

### Adding a New Test Suite

```swift
import Testing
@testable import HexBSD

@Suite("Feature Name")
struct FeatureNameTests {

    @Test("Descriptive behavior name")
    func behaviorTest() {
        // Arrange
        let input = "test data"

        // Act
        let result = processInput(input)

        // Assert
        #expect(result == expectedValue)
    }
}
```

## Code Coverage

While 100% coverage is not a goal, critical paths should be well-tested:

- **Parsing logic** - All edge cases covered
- **Validation functions** - Boundary conditions tested
- **Error handling** - Failure modes verified
- **State transitions** - Connection lifecycle tested

## Future Improvements

- [ ] UI testing with XCUITest for critical user flows
- [ ] Snapshot testing for view consistency
- [ ] Fuzz testing for parser robustness
- [ ] Contract testing for SSH command responses
