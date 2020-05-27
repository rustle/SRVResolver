#import "SRVRunLoopOperation.h"

@interface SRVRunLoopOperation ()
@property (copy) NSError *error;
@end

@implementation SRVRunLoopOperation {
    SRVOperationState _state;
    NSRecursiveLock *_stateLock;
    BOOL _isCancelled;
    NSRecursiveLock *_cancelLock;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        _stateLock = [[NSRecursiveLock alloc] init];
        _cancelLock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    NSAssert((_state != SRVOperationStateExecuting), @"Run loop operation dealloced while still executing");
}

#pragma mark - Properties

// Returns the effective run loop thread, that is, the one set by the user
// or, if that's not set, the main thread.
- (NSThread *)actualRunLoopThread
{
    NSThread *result = self.runLoopThread;
    if (result == nil) {
        result = [NSThread mainThread];
    }
    return result;
}

// Returns YES if the current thread is the actual run loop thread.
- (BOOL)isActualRunLoopThread
{
    return [[NSThread currentThread] isEqual:self.actualRunLoopThread];
}

- (NSSet *)actualRunLoopModes
{
    NSSet *result = self.runLoopModes;
    if ((result == nil) || 
        ([result count] == 0)) {
        result = [NSSet setWithObject:NSDefaultRunLoopMode];
    }
    return result;
}

#pragma mark * Core state transitions

- (SRVOperationState)state
{
    [_stateLock lock];
    SRVOperationState state = _state;
    [_stateLock unlock];
    return state;
}

// Change the state of the operation, sending the appropriate KVO notifications.
- (void)setState:(SRVOperationState)newState
{
    [_stateLock lock];

    // The state can only go forward, and there
    // should be no redundant changes to the state
    // (that is, newState must never be equal to _state).
    NSAssert((newState > _state), @"Invalid state transition from %@ to %@", @(_state), @(newState));

    // Transitions from executing to finished must be done on the run loop thread.
    NSAssert(((newState != SRVOperationStateFinished) || self.isActualRunLoopThread), @"Attempted transition to finish on non run loop thread");

    // inited    + executing -> isExecuting
    // inited    + finished  -> isFinished
    // executing + finished  -> isExecuting + isFinished
    
    SRVOperationState oldState = _state;
    if ((newState == SRVOperationStateExecuting) ||
        (oldState == SRVOperationStateExecuting)) {
        [self willChangeValueForKey:@"isExecuting"];
    }
    if (newState == SRVOperationStateFinished) {
        [self willChangeValueForKey:@"isFinished"];
    }
    _state = newState;
    if (newState == SRVOperationStateFinished) {
        [self didChangeValueForKey:@"isFinished"];
    }
    if ((newState == SRVOperationStateExecuting) ||
        (oldState == SRVOperationStateExecuting)) {
        [self didChangeValueForKey:@"isExecuting"];
    }

    [_stateLock unlock];
}

// Starts the operation. The actual -start method is very simple,
// deferring all of the work to be done on the run loop thread by this
// method.
- (void)startOnRunLoopThread
{
    NSParameterAssert(self.isActualRunLoopThread);
    // If we got canceled and finished waiting for this to get scheduled, bail
    if (self.state != SRVOperationStateExecuting) {
        return;
    }
    if ([self isCancelled]) {
        // We were cancelled before we even got running.  Flip the the finished 
        // state immediately.
        [self finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    } else {
        [self operationDidStart];
    }
}

// Cancels the operation.
- (void)cancelOnRunLoopThread
{
    NSParameterAssert(self.isActualRunLoopThread);

    // We know that a) state was SRVRunLoopOperationStateExecuting when we were
    // scheduled (that's enforced by -cancel), and b) the state can't go 
    // backwards (that's enforced by -setState), so we know the state must 
    // either be SRVRunLoopOperationStateExecuting or SRVRunLoopOperationStateFinished.
    // We also know that the transition from executing to finished always 
    // happens on the run loop thread.  Thus, we don't need to lock here.  
    // We can look at state and, if we're executing, trigger a cancellation.

    if (self.state == SRVOperationStateExecuting) {
        [self finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    }
}

- (BOOL)finishWithError:(NSError *)error
{
    NSAssert(self.isActualRunLoopThread, @"Entered finishWithError from non run loop thread");
    // If we got canceled and finished waiting for this to get scheduled, bail
    if (self.state != SRVOperationStateExecuting) {
        return NO;
    }
    // error may be nil
    if (self.error == nil) {
        self.error = error;
    }
    [self operationWillFinish];
    self.state = SRVOperationStateFinished;
    return YES;
}

#pragma mark * Subclass override points

- (void)operationDidStart
{
    NSAssert(self.isActualRunLoopThread, @"Entered operationDidStart from non run loop thread");
}

- (void)operationWillFinish
{
    NSAssert(self.isActualRunLoopThread, @"Entered operationWillFinish from non run loop thread");
}

#pragma mark * Overrides

- (BOOL)isAsynchronous
{
    // any thread
    return YES;
}

- (BOOL)isExecuting
{
    // any thread
    return (self.state == SRVOperationStateExecuting);
}

- (BOOL)isFinished
{
    // any thread
    return (self.state == SRVOperationStateFinished);
}

- (void)start
{
    NSAssert((self.state == SRVOperationStateInited), @"Operation started in invalid state %@", @(self.state));

    // We have to change the state here, otherwise isExecuting won't necessarily return 
    // true by the time we return from -start. Also, we don't test for cancellation
    // here because a) handling isCancelled here would result in us sending isFinished
    // notifications on a thread that isn't our run loop thread, and
    // b) confuse the core cancellation code, which expects to run on our run loop thread.
    // Finally, we don't have to worry about races with other threads calling -start.
    // Only one thread is allowed to start us.
    
    self.state = SRVOperationStateExecuting;
    [self performSelector:@selector(startOnRunLoopThread) 
                 onThread:self.actualRunLoopThread
               withObject:nil
            waitUntilDone:NO
                    modes:[self.actualRunLoopModes allObjects]];
}

- (BOOL)isCancelled
{
    [_cancelLock lock];
    BOOL isCancelled = _isCancelled;
    [_cancelLock unlock];
    return isCancelled;
}

- (void)cancel
{
    BOOL cancelledWhileExecuting = NO;

    // We need to take both state and cancel locks here to avoid changes to isCancelled and state
    // while we're running.
    [_stateLock lock];
    [_cancelLock lock];
    if (!_isCancelled) {
        [self willChangeValueForKey:@"isCancelled"];
        _isCancelled = YES;
        [self didChangeValueForKey:@"isCancelled"];
        // If we were the one to set isCancelled (that is, we won the race with regards
        // other threads calling -cancel) and we're actually running (that is, we lost
        // the race with other threads calling -start and the run loop thread finishing),
        // we schedule to finish cancelling on the run loop thread.
        cancelledWhileExecuting = (_state == SRVOperationStateExecuting);
    }
    [_stateLock unlock];
    [_cancelLock unlock];

    if (cancelledWhileExecuting) {
        [self performSelector:@selector(cancelOnRunLoopThread)
                     onThread:self.actualRunLoopThread
                   withObject:nil
                waitUntilDone:YES
                        modes:[self.actualRunLoopModes allObjects]];
    }
}

@end
