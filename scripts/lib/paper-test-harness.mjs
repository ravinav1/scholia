// Run the same paper-study XCTest bodies on Command Line Tools installations
// that do not ship XCTest. Full Xcode can use `swift test --filter Paper` instead.
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '../..');
const output = process.argv[2];
if (!output) throw new Error('Supply the generated Swift output path');
const helpers = `
import Foundation
class PaperSmokeTestCase {}
func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    fatalError(message, file: (file), line: line)
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { XCTFail("Expected true: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { XCTFail("Expected false: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let lhs = try a(), rhs = try b(); if lhs != rhs { XCTFail("Not equal: \\(lhs) / \\(rhs). " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == b() { XCTFail("Unexpected equality: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !(a() < b()) { XCTFail("Expected less than: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !(a() > b()) { XCTFail("Expected greater than: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { XCTFail("Expected nil: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { XCTFail("Expected non-nil: " + message, file: file, line: line) } }
    catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value() } catch { return }
    XCTFail("Expected error: " + message, file: file, line: line)
}
struct PaperSmokeUnwrapError: Error {}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail("Unwrap failed", file: file, line: line); throw PaperSmokeUnwrapError() }
    return value
}
`;
let source = helpers;
let invocations = '', count = 0;
for (const name of ['PaperTutorTests', 'PaperTutorRoutingTests', 'PaperCameraTests', 'PaperStudySessionTests']) {
  let body = await readFile(resolve(root, `apps/macos/Tests/ScholiaMacTests/${name}.swift`), 'utf8');
  const tests = [...body.matchAll(/func (test\w+)\(\)([^\{]*)\{/g)];
  source += `\n#sourceLocation(file: "${name}.swift", line: 1)\n` + body.replace(/^import XCTest\n/m, '').replace(': XCTestCase', ': PaperSmokeTestCase');
  invocations += `let suite${name} = ${name}()\n`;
  for (const [, method, signature] of tests) {
    invocations += `${signature.includes('throws') ? 'try ' : ''}${signature.includes('async') ? 'await ' : ''}suite${name}.${method}()\nprint("PASS ${name}.${method}")\n`;
    count++;
  }
}
source += `\n#sourceLocation()\n@main @MainActor struct PaperTestsRunner {
  static func main() async throws {
    ${invocations}
    print("PASS: ${count} paper-study tests (same bodies as XCTest; Command Line Tools assertion runner)")
  }
}\n`;
await writeFile(output, source);
