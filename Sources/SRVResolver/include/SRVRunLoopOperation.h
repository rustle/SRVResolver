@import Foundation;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SRVOperationState) {
    SRVOperationStateInited,
    SRVOperationStateExecuting,
    SRVOperationStateFinished,
};

/**
 * An abstract subclass of NSOperation for async run loop based operations.
 */

@interface SRVRunLoopOperation : NSOperation

///-----------------------------------------
/// @name Configure before queuing operation
///-----------------------------------------

// IMPORTANT: Do not change these after queuing the operation; it's very likely that 
// bad things will happen if you do.

@property NSThread *runLoopThread; // default is nil, implying main thread
@property (copy) NSSet *runLoopModes; // default is nil, implying set containing NSDefaultRunLoopMode

///-----------------------------
/// @name Valid after completion
///-----------------------------

@property (copy, readonly, nullable) NSError *error;

///----------------------
/// @name Operation state
///----------------------

@property (readonly) SRVOperationState state;
@property (readonly) NSThread *actualRunLoopThread; // main thread if runLoopThread is nil, runLoopThread otherwise
@property (readonly) BOOL isActualRunLoopThread; // YES if the current thread is the actual run loop thread
@property (copy, readonly) NSSet *actualRunLoopModes; // set containing NSDefaultRunLoopMode if runLoopModes is nil or empty, runLoopModes otherwise

@end

@interface SRVRunLoopOperation (SubClassSupport)

// Override points

// A subclass will probably need to override -operationDidStart and -operationWillFinish 
// to set up and tear down its run loop sources, respectively.  These are always called 
// on the actual run loop thread.
//
// Note that -operationWillFinish will be called even if the operation is cancelled. 
//
// -operationWillFinish can check the error property to see whether the operation was 
// successful.  error will be NSCocoaErrorDomain/NSUserCancelledError on cancellation. 
//
// -operationDidStart is allowed to call -finishWithError:.

- (void)operationDidStart;
- (void)operationWillFinish;

// Support methods

// A subclass should call -finishWithError: when the operation is complete, passing nil 
// for no error and an error otherwise.  It must call this on the actual run loop thread. 
// 
// Return value indicates that -finishWithError: was called successfully prior to operation finishing.
// Subclasses that override -finishWithError: should honor return value and not continue.
// 
// Note that this will call -operationWillFinish before returning.

- (BOOL)finishWithError:(NSError *__nullable)error;

- (void)setError:(NSError *__nullable)error;

@end

NS_ASSUME_NONNULL_END
