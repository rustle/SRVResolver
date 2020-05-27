//
//  SRVRunLoopTests.swift
//  SRVResolverTests
//
//  Copyright © 2020 Doug Russell. All rights reserved.
//

import XCTest
@testable import SRVResolver

class TimerOperation: SRVRunLoopOperation {
    private static let timerThread: Thread = {
        let thread = Thread {
            autoreleasepool {
                Timer.scheduledTimer(withTimeInterval: Date.distantFuture.timeIntervalSinceNow,
                                     repeats: false,
                                     block: { _ in })
                while true {
                    autoreleasepool {
                        _ = CFRunLoopRunInMode(.defaultMode,
                                               10.0,
                                               true)
                    }
                }
            }
            assert(false)
        }
        thread.start()
        thread.name = "Timer"
        return thread
    }()
    private var timer: Timer? {
        didSet {
            assert(isActualRunLoopThread)
        }
    }
    override func operationDidStart() {
        assert(isActualRunLoopThread)
        let runLoop = RunLoop.current
        let timer = Timer(timeInterval: timeInterval,
                          repeats: false) { [weak self] _ in
            self?.fire()
        }
        runLoop.add(timer,
                    forMode: .default)
        self.timer = timer
    }
    override func operationWillFinish() {
        assert(isActualRunLoopThread)
        timer?.invalidate()
    }
    private func fire() {
        assert(isActualRunLoopThread)
        _fire()
        finishWithError(nil)
    }
    let timeInterval: TimeInterval
    let _fire: () -> Void
    init(timeInterval: TimeInterval,
         fire: @escaping () -> Void,
         completion: @escaping () -> Void) {
        self.timeInterval = timeInterval
        _fire = fire
        super.init()
        completionBlock = completion
    }
}

class SRVRunLoopTests: XCTestCase {
    func testTimer() throws {
        let fire = self.expectation(description: "fire")
        let complete = self.expectation(description: "complete")
        let op = TimerOperation(timeInterval: 0.1,
                                fire: {
                                    fire.fulfill()
                                }, completion: {
                                    complete.fulfill()
                                })
        withExtendedLifetime(op) {
            op.start()
            wait(for: [fire, complete],
                 timeout: 1.0)
        }
    }
    func testTimerCancel() throws {
        let complete = self.expectation(description: "complete")
        let op = TimerOperation(timeInterval: 0.1,
                                fire: {
                                    XCTFail()
                                }, completion: {
                                    complete.fulfill()
                                })
        withExtendedLifetime(op) {
            op.start()
            op.cancel()
            wait(for: [complete],
                 timeout: 1.0)
            XCTAssertEqual(op.error as NSError?, NSError(domain: NSCocoaErrorDomain,
                                                         code: NSUserCancelledError,
                                                         userInfo: nil))
        }
    }
    static var allTests = [
        ("testTimer", testTimer),
    ]
}
