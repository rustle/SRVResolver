import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(SRVResolverTests.allTests),
        testCase(SRVRunLoopTests.allTests),
    ]
}
#endif
