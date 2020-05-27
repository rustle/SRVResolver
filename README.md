SRVResolver
-------------------

Based on Apple Sample Code.

### Purpose

NSOperation subclass to resolve DNS SRV records based on host name.

### Usage

```
class ThatWhichRequiresResolve: NSObject, SRVResolverDelegate {
    let queue = OperationQueue()
    func resolve(host: String) {
        let operation = SRVResolverOperation(srvName: "_jmap._tcp.\(host)")
        operation.delegate = self
        operation.delegateQueue = queue
        queue.addOperation(operation)
    }

    func srvResolverOperation(_ resolver: SRVResolverOperation,
                              didReceiveResult result: [SRVResolverResultsKey: Any]) {
        guard
            let priority = result[.priority] as? Int,
            let weight = result[.weight] as? Int,
            let port = result[.port] as? Int,
            let target = result[.target] as? String
        else {
            return
        }
        ...
    }

    func srvResolverOperation(_ resolver: SRVResolverOperation,
                              didFinishWithError error: Error?) {
        if let error = error {
            ...
        } else {
            ...
        }
    }
}
```

SRVRunLoopOperation Theory of Operation
-------------------

### Assumptions

1. By the time we're running on the run loop thread, all further state transitions **must** happen on the run loop thread. We can ensure this by defining three states (inited, executing, and finished), only allowing run loop thread code to run in the last two states, and only allowing the executing to finished transition on the run loop thread.
2. `start` **must** only be called once.  Run loop thread code doesn't have to worry about racing with `start` because, by the time the run loop thread code runs, `start` has already been called.
3. `cancel` can be called multiple times from any thread.  Run loop thread code must take care to do the right thing with cancellation.

### Discussion of state transitions

1. It's valid to allocate an operation and never run it.
    * `init (any thread)
    * `dealloc (any thread)
2. It's valid to allocate an operation, cancel it, and never run it.
    * `init` (any thread)
    * `cancel` (any thread)
    * `dealloc` (any thread)
3. **This case can never happen** because while it's valid to cancel an operation before it starting it, this case doesn't happen because -start always bounces to the run loop thread to maintain the invariant that the executing to finished transition always happens on the run loop thread.
    * `init` (any thread)
    * `cancel` (any thread)
    * `start` (any thread)
    * `finishWithError:` (required to be run loop thread, but in this case would be undefined)
    * `dealloc` (any thread)
4. An operation is allocated, `cancel` and `start` are both called, either on the same thread, with `cancel` going first, or on different threads, with `cancel` winning the race to set `state`. Both `cancel` and `start` bounce to the their run loop thread counterparts (`cancelOnRunLoopThread` and `startOnRunLoopThread`) to maintain "the executing to finished transition always happens on the run loop thread" as an invariant.  When `startOnRunLoopThread` checks `state` and finds it isn't executing, it returns early.
    * init (any thread)
        * cancel (thread A)
        * start (thread A)
    * OR
        * cancel (thread A, cancelOnRunLoopThread wins race with startOnRunLoopThread)
        * start (thread B, startOnRunLoopThread loses race with cancelOnRunLoopThread)
    * cancelOnRunLoopThread (run loop thread, calls finishWithError: with an appropriate error)
    * startOnRunLoopThread (run loop thread, returns early after consulting state)
    * finishWithError: (run loop thread, receiving error indicating cancellation)
    * dealloc (any thread)
5. An operation is allocated, `cancel` and `start` are both called, either on the same thread, with `start` going first, or on different threads, with `cancel` winning the race to set `isCancelled` before `startOnRunLoopThread` runs. Both `cancel` and `start` bounce to the their run loop thread counterparts (`cancelOnRunLoopThread` and `startOnRunLoopThread`) to maintain "the executing to finished transition always happens on the run loop thread" as an invariant.  When `startOnRunLoopThread` checks `isCancelled` and finds it is true, it returns early. When cancelOnRunLoopThread
    * `init` (any thread)
        * `start` (thread A)
        * `cancel` (thread A)
    * OR
        * `start` (thread A, `startOnRunLoopThread` wins race with `cancelOnRunLoopThread`)
        * `cancel` (thread B, `cancelOnRunLoopThread` loses race with `startOnRunLoopThread`, but `cancel` wins race to set `isCancelled` to true before `startOnRunLoopThread` runs)
    * `cancelOnRunLoopThread` (run loop thread, sees state is finished and returns early)
    * `startOnRunLoopThread` (run loop thread, sees `isCancelled` is true and calls `finishWithError:` with an appropriate error)
    * `finishWithError:` (run loop thread, receiving error indicating cancellation)
    * `dealloc` (any thread)
6. **This case can never happen** because work scheduled with `performSelector:onThread:withObject:waitUntilDone:modes:` happens in the order they're submitted in and `start` and `cancel` both take the state lock, and `cancel` only schedules if `start` has run.
    * `init` (any thread)
    * `start` (any thread)
    * `cancel` (any thread)
    * `cancelOnRunLoopThread` (run loop thread)
    * `startOnRunLoopThread` (run loop thread)
    * `finishWithError:` (run loop thread)
    * `dealloc` (any thread)
7. **This case can never happen** because `startOnRunLoopThread` will finish immediately if it detects `isCancelled` (see case 5). 
    * `init` (any thread)
    * `start` (any thread)
    * `cancel` (any thread)
    * `startOnRunLoopThread` (run loop thread)
    * `cancelOnRunLoopThread` (run loop thread)
    * `finishWithError:` (run loop thread)
    * `dealloc` (any thread)
8. This is the standard run-to-completion case. 
    * `init` (any thread)
    * `start` (any thread)
    * `startOnRunLoopThread` (run loop thread)
    * `finishWithError:` (run loop thread)
    * `dealloc` (any thread)
9. This is the standard cancellation case.  `cancelOnRunLoopThread` wins the race with `finishWithError:`, and it detects that the operation is executing and actually cancels.
    * `init` (any thread)
    * `start` (any thread)
    * `startOnRunLoopThread` (run loop thread)
    * `cancel` (any thread)
    * `cancelOnRunLoopThread` (run loop thread)
    * `finishWithError:` (run loop thread, receiving error indicating cancellation)
    * `dealloc` (any thread)
10. In this case the `cancelOnRunLoopThread` loses the race with `finishWithError:`, but that's OK because `cancelOnRunLoopThread` does nothing if the operation is already finished.
    * `init` (any thread)
    * `start` (any thread)
    * `startOnRunLoopThread` (run loop thread)
    * `cancel` (any thread)
    * `finishWithError:` (run loop thread)
    * `cancelOnRunLoopThread` (run loop thread)
    * `dealloc` (any thread)
11. Cancellating after finishing still sets `isCancelled` to true but has no impact on the run loop thread code.
    * `init` (any thread)
    * `start` (any thread)
    * `startOnRunLoopThread` (run loop thread)
    * `finishWithError:` (run loop thread)
    * `cancel` (any thread)
    * `dealloc` (any thread)
*/

------------------------------------------------

URL: https://developer.apple.com/library/archive/samplecode/SRVResolver/Listings/SRVResolver_m.html#//apple_ref/doc/uid/DTS40009625-SRVResolver_m-DontLinkElementID_5

Contains: Uses <dns_sd.h> APIs to resolve SRV records.

Written by: DTS

Copyright:  Copyright (c) 2010-2012 Apple Inc. All Rights Reserved.

Disclaimer: IMPORTANT: This Apple software is supplied to you by Apple Inc.
("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or
redistribution of this Apple software constitutes acceptance of
these terms.  If you do not agree with these terms, please do
not use, install, modify or redistribute this Apple software.

In consideration of your agreement to abide by the following
terms, and subject to these terms, Apple grants you a personal,
non-exclusive license, under Apple's copyrights in this
original Apple software (the "Apple Software"), to use,
reproduce, modify and redistribute the Apple Software, with or
without modifications, in source and/or binary forms; provided
that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the
following text and disclaimers in all such redistributions of
the Apple Software. Neither the name, trademarks, service marks
or logos of Apple Inc. may be used to endorse or promote
products derived from the Apple Software without specific prior
written permission from Apple.  Except as expressly stated in
this notice, no other rights or licenses, express or implied,
are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or
by other works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis. 
APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING
WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT,
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING
THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN
COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT,
INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY
OUT OF THE USE, REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION
OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY
OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR
OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

------------------------------------------------

URL: http://developer.apple.com/library/ios/#samplecode/MVCNetworking/Listings/Networking_QRunLoopOperation_m.html

Contains:   An abstract subclass of NSOperation for async run loop based operations.

Written by: DTS

Copyright:  Copyright (c) 2010 Apple Inc. All Rights Reserved.

Disclaimer: IMPORTANT: This Apple software is supplied to you by Apple Inc.
("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or
redistribution of this Apple software constitutes acceptance of
these terms.  If you do not agree with these terms, please do
not use, install, modify or redistribute this Apple software.

In consideration of your agreement to abide by the following
terms, and subject to these terms, Apple grants you a personal,
non-exclusive license, under Apple's copyrights in this
original Apple software (the "Apple Software"), to use,
reproduce, modify and redistribute the Apple Software, with or
without modifications, in source and/or binary forms; provided
that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the
following text and disclaimers in all such redistributions of
the Apple Software. Neither the name, trademarks, service marks
or logos of Apple Inc. may be used to endorse or promote
products derived from the Apple Software without specific prior
written permission from Apple.  Except as expressly stated in
this notice, no other rights or licenses, express or implied,
are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or
by other works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis. 
APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING
WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT,
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING
THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN
COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT,
INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY
OUT OF THE USE, REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION
OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY
OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR
OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
