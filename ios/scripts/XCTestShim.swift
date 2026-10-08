// Minimal XCTest stand-in so the core tests run with only Command Line Tools (no Xcode).
import Foundation

var failures = 0
var currentTest = ""
class XCTestCase { required init() {} }
private func fail(_ message: String, _ file: StaticString, _ line: UInt) {
  failures += 1
  print("  FAIL \(currentTest) \(("\(file)" as NSString).lastPathComponent):\(line) \(message)")
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if (try? value()) != true { fail("expected true \(message)", file, line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if (try? value()) != false { fail("expected false \(message)", file, line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if let v = try? value() { fail("expected nil, got \(v) \(message)", file, line) }
}
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if (try? value()) == nil { fail("expected non-nil \(message)", file, line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  do { let x = try a(), y = try b(); if x != y { fail("\(x) != \(y) \(message)", file, line) } }
  catch { fail("threw \(error)", file, line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  do { let x = try a(), y = try b(); if x == y { fail("\(x) == \(y) \(message)", file, line) } }
  catch { fail("threw \(error)", file, line) }
}
func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  do { let x = try a(), y = try b(); if !(abs(x - y) <= accuracy) { fail("\(x) != \(y) ±\(accuracy) \(message)", file, line) } }
  catch { fail("threw \(error)", file, line) }
}
func run<T: XCTestCase>(_ type: T.Type, _ tests: [(String, (T) -> () throws -> Void)]) {
  for (name, test) in tests {
    currentTest = "\(type).\(name)"
    let before = failures
    do { try test(type.init())() } catch { fail("threw \(error)", #filePath, #line) }
    print(failures == before ? "  ok   \(currentTest)" : "  ---- \(currentTest)")
  }
}
func run<T: XCTestCase>(_ type: T.Type, _ tests: [(String, (T) -> () -> Void)]) {
  let throwing: [(String, (T) -> () throws -> Void)] = tests.map { test in (test.0, { instance in { test.1(instance)() } }) }
  run(type, throwing)
}
