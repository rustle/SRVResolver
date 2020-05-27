//
//  SRVResolverTests.swift
//  SRVResolverTests
//
//  Copyright © 2020 Doug Russell. All rights reserved.
//

import XCTest
@testable import SRVResolver

class SRVResolverTests: XCTestCase {
    class Delegate: NSObject, SRVResolverDelegate {
        var results = [[SRVResolverResultsKey : Any]]()
        var errors = [Error]()
        func srvResolverOperation(_ resolver: SRVResolverOperation,
                                  didReceiveResult result: [SRVResolverResultsKey : Any]) {
            results.append(result)
        }
        func srvResolverOperation(_ resolver: SRVResolverOperation,
                                  didFinishWithError error: Error?) {
            if let error = error {
                errors.append(error)
            }
            completionHandler()
        }
        let completionHandler: () -> Void
        init(_ completionHandler: @escaping () -> Void) {
            self.completionHandler = completionHandler
        }
    }
    // Requires an active internet connection
    var delegate: Delegate?
    func testResolveSRV() throws {
        let expect = expectation(description: "\(#function)-completion")
        delegate = Delegate {
            XCTAssertEqual(self.delegate?.results.count, 1)
            XCTAssertNotNil(self.delegate?.results[0][.priority] as? Int)
            XCTAssertNotNil(self.delegate?.results[0][.weight] as? Int)
            XCTAssertNotNil(self.delegate?.results[0][.target] as? String)
            XCTAssertNotNil(self.delegate?.results[0][.port] as? Int)
            XCTAssertEqual(self.delegate?.errors.count, 0)
            expect.fulfill()
        }
        let queue = OperationQueue()
        let resolveOperation = SRVResolverOperation(srvName: "_jmap._tcp.fastmail.com",
                                                    timeout: 10.0)
        resolveOperation.delegate = delegate
        resolveOperation.delegateQueue = queue
        queue.addOperation(resolveOperation)
        self.waitForExpectations(timeout: 10.0,
                                 handler: nil)
    }
    func testNoSuchRecordOrTimeout() throws {
        let expect = expectation(description: "\(#function)-completion")
        delegate = Delegate {
            XCTAssertEqual(self.delegate?.results.count, 0)
            XCTAssertEqual(self.delegate?.errors.count, 1)
            if let error = self.delegate?.errors[0] as NSError? {
                XCTAssertEqual(error.domain, SRVResolverErrorDomain)
                XCTAssertTrue(error.code == 0 || error.code == kDNSServiceErr_NoSuchRecord)
            } else {
                XCTFail()
            }
            expect.fulfill()
        }
        let queue = OperationQueue()
        let resolveOperation = SRVResolverOperation(srvName: "example.com",
                                                    timeout: 1.0)
        resolveOperation.delegate = delegate
        resolveOperation.delegateQueue = queue
        queue.addOperation(resolveOperation)
        self.waitForExpectations(timeout: 2.0,
                                 handler: nil)
    }
    static var allTests = [
        ("testResolveSRV", testResolveSRV),
    ]
}
