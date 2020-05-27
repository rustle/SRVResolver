#import "SRVResolverOperation.h"

#include <dns_util.h>

SRVResolverResultsKey SRVResolverResultsKeyPriority = @"priority"; // NSNumber, host byte order
SRVResolverResultsKey SRVResolverResultsKeyWeight = @"weight"; // NSNumber, host byte order
SRVResolverResultsKey SRVResolverResultsKeyPort = @"port"; // NSNumber, host byte order
SRVResolverResultsKey SRVResolverResultsKeyTarget = @"target"; // NSString

NSErrorDomain SRVResolverErrorDomain = @"SRVResolverErrorDomain";

@interface SRVResolverOperation () {
    DNSServiceRef _sdRef;
    CFSocketRef _sdRefSocket;
    NSMutableArray *_resultsMutable;
    NSOperation *_latestResultsOperation;
}
@end

@implementation SRVResolverOperation
@synthesize srvName = _srvName;
@synthesize delegate = _delegate;
@synthesize delegateQueue = _delegateQueue;

// This thread runs all of our resolver operation run loop callbacks.
+ (void)resolverRunLoopThreadEntry
{
    NSAssert(([NSThread currentThread] == [[self class] resolverRunLoopThread]), @"Entered resolverRunLoopThreadEntry from invalid thread");
    @autoreleasepool {
        // Schedule a timer in the distant future to keep the run loop from simply immediately exiting
        [NSTimer scheduledTimerWithTimeInterval:3600*24*365*10 target:(__nonnull id)nil selector:(__nonnull SEL)nil userInfo:nil repeats:NO];
        while (YES) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, YES);
            }
        }
    }
    NSAssert(NO, @"Exited resolverRunLoopThreadEntry prematurely");
}

+ (NSThread *)resolverRunLoopThread
{
    static NSThread *runLoopThread;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // We run all of our network callbacks on a secondary thread to ensure that they don't
        // contribute to main thread latency. Create and configure that thread.
        runLoopThread = [[NSThread alloc] initWithTarget:[self class] selector:@selector(resolverRunLoopThreadEntry) object:nil];
        NSParameterAssert(runLoopThread != nil);
        [runLoopThread setQualityOfService:NSQualityOfServiceUtility];
        [runLoopThread setName:@"SRVResolver"];
        [runLoopThread start];
    });
    return runLoopThread;
}

// Call (via our CFSocket callback) when we get a response to our query.
// It does some preliminary work, but the bulk of the interesting stuff
// is done in the -processRecord:length: method.
static void QueryRecordCallback(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                uint32_t interfaceIndex,
                                DNSServiceErrorType errorCode,
                                const char * fullname,
                                uint16_t rrtype,
                                uint16_t rrclass,
                                uint16_t rdlen,
                                const void * rdata,
                                uint32_t ttl,
                                void * context) {
    SRVResolverOperation *obj = (__bridge SRVResolverOperation *) context;

    NSCParameterAssert([obj isKindOfClass:[SRVResolverOperation class]]);
    NSCParameterAssert(sdRef == obj->_sdRef);
    NSCParameterAssert(flags & kDNSServiceFlagsAdd);
    NSCParameterAssert(rrtype == kDNSServiceType_SRV);
    NSCParameterAssert(rrclass == kDNSServiceClass_IN);

    if (errorCode == kDNSServiceErr_NoError) {
        [obj processRecord:rdata length:rdlen];
        
        // We're assuming SRV records over unicast DNS here, so the first result packet we get
        // will contain all the information we're going to get.  In a more dynamic situation
        // (for example, multicast DNS or long-lived queries in Back to My Mac) we'd would want
        // to leave the query running.
        
        if (!(flags & kDNSServiceFlagsMoreComing)) {
            [obj finishWithError:nil];
        }
    } else {
        [obj finishWithDNSServiceError:errorCode];
    }
}

// A CFSocket callback.  This runs when we get messages from mDNSResponder
// regarding our DNSServiceRef.  We just turn around and call DNSServiceProcessResult,
// which does all of the heavy lifting (and would typically call QueryRecordCallback).
static void SDRefSocketCallback(CFSocketRef s,
                                CFSocketCallBackType type,
                                CFDataRef address,
                                const void * data,
                                void * info) {
    NSCParameterAssert(type == kCFSocketReadCallBack);

    SRVResolverOperation *obj = (__bridge SRVResolverOperation *)info;
    NSCParameterAssert([obj isKindOfClass:[SRVResolverOperation class]]);
    NSCParameterAssert(s == obj->_sdRefSocket);

    DNSServiceErrorType err = DNSServiceProcessResult(obj->_sdRef);
    if (err != kDNSServiceErr_NoError) {
        [obj finishWithDNSServiceError:err];
    }
}

- (instancetype)initWithSRVName:(NSString *)srvName timeout:(NSTimeInterval)timeout
{
    NSParameterAssert(srvName != nil);
    self = [super init];
    if (self != nil) {
        _srvName = [srvName copy];
        NSParameterAssert(timeout > 0);
        _timeout = timeout;
        NSParameterAssert(_srvName != nil);
        _resultsMutable = [[NSMutableArray alloc] init];
    }
    return self;
}

#pragma mark -

- (void)confirmSelectorCalledInInitStateOrThrowException:(SEL)selector
{
    NSParameterAssert(selector);
    SRVOperationState state = self.state;
    if (state != SRVOperationStateInited) {
        [NSException raise:@"Invalid State Exception" format:@"Attempted %@ while in state: %@. May only be attempted prior to queueing operation.", NSStringFromSelector(selector), @(state)];
    }
}

- (void)setDelegate:(id<SRVResolverDelegate>)delegate
{
    [self confirmSelectorCalledInInitStateOrThrowException:_cmd];
    _delegate = delegate;
}

- (NSOperationQueue *)delegateQueue
{
    return _delegateQueue ?: [NSOperationQueue mainQueue];
}

- (void)setDelegateQueue:(NSOperationQueue *)delegateQueue
{
    [self confirmSelectorCalledInInitStateOrThrowException:_cmd];
    if (_delegateQueue != delegateQueue) {
        _delegateQueue = delegateQueue;
    }
}

#pragma mark -

// Called by SRVRunLoopOperation when the operation starts.
- (void)operationDidStart
{
    NSParameterAssert(self.isActualRunLoopThread);
    NSParameterAssert(self.state == SRVOperationStateExecuting);
    NSParameterAssert(_sdRef == nil);
    [self startWithRunLoop:[NSRunLoop currentRunLoop]];
}

// Called by SRVRunLoopOperation when the operation has finished.
- (void)operationWillFinish
{
    NSParameterAssert(self.isActualRunLoopThread);
    NSParameterAssert(self.state == SRVOperationStateExecuting);
    if (_sdRefSocket != nil) {
        CFSocketInvalidate(_sdRefSocket);
        CFRelease(_sdRefSocket);
        _sdRefSocket = nil;
    }
    if (_sdRef != nil) {
        DNSServiceRefDeallocate(_sdRef);
        _sdRef = nil;
    }
    NSOperation *finishOperation = [self finishOperation];
    [self.delegateQueue addOperation:finishOperation];
}

#pragma mark -

- (void)startWithRunLoop:(NSRunLoop *)runLoop
{
    NSParameterAssert(self.isActualRunLoopThread);
    CFSocketContext context = { 0, (__bridge void *) self, NULL, NULL, NULL };
    CFRunLoopSourceRef rls;
    
    NSParameterAssert(_sdRef == nil);
    
    // Create the DNSServiceRef to run our query.
    
    DNSServiceErrorType error = kDNSServiceErr_NoError;
    const char * srvNameCStr = [_srvName UTF8String];
    if (srvNameCStr == nil) {
        error = kDNSServiceErr_BadParam;
    }

    if (error == kDNSServiceErr_NoError) {
        error = DNSServiceQueryRecord(&_sdRef,
                                      kDNSServiceFlagsReturnIntermediates,
                                      0, // interfaceIndex
                                      srvNameCStr,
                                      kDNSServiceType_SRV,
                                      kDNSServiceClass_IN,
                                      QueryRecordCallback,
                                      (__bridge void *)(self));
    }

    // Create a CFSocket to handle incoming messages associated with the
    // DNSServiceRef.

    if (error == kDNSServiceErr_NoError) {
        NSParameterAssert(_sdRef != nil);
        
        int fd = DNSServiceRefSockFD(_sdRef);
        NSParameterAssert(fd >= 0);

        NSParameterAssert(_sdRefSocket == nil);
        _sdRefSocket = CFSocketCreateWithNative(nil,
                                                fd,
                                                kCFSocketReadCallBack,
                                                SDRefSocketCallback,
                                                &context);
        NSParameterAssert(_sdRefSocket != nil);

        CFSocketSetSocketFlags(_sdRefSocket,
                               CFSocketGetSocketFlags(_sdRefSocket) &~ (CFOptionFlags)kCFSocketCloseOnInvalidate);

        rls = CFSocketCreateRunLoopSource(nil, _sdRefSocket, 0);
        NSParameterAssert(rls != NULL);

        CFRunLoopAddSource([runLoop getCFRunLoop], rls, kCFRunLoopDefaultMode);
        CFRelease(rls);

        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:_timeout repeats:NO block:^(NSTimer *__nonnull timer) {
            [weakSelf finishWithError:[NSError errorWithDomain:SRVResolverErrorDomain code:0 userInfo:nil]];
        }];
        [timer setTolerance:1.0];
        [runLoop addTimer:timer forMode:NSDefaultRunLoopMode];
    } else {
        [self finishWithDNSServiceError:error];
    }
}

- (void)finishWithDNSServiceError:(DNSServiceErrorType)errorCode
{
    NSAssert(self.isActualRunLoopThread, @"Entered finishWithDNSServiceError: from non run loop thread");
    NSError *error;
    if (errorCode != kDNSServiceErr_NoError) {
        error = [NSError errorWithDomain:SRVResolverErrorDomain code:errorCode userInfo:nil];
    }
    [self finishWithError:error];
}

- (void)processRecord:(const void *)rdata length:(NSUInteger)rdlen
{
    NSAssert(self.isActualRunLoopThread, @"Entered processRecord:length: from non run loop thread");
    NSMutableData *rrData;
    dns_resource_record_t * rr;
    uint8_t u8;
    uint16_t u16;
    uint32_t u32;

    NSParameterAssert(rdata != nil);
    // rdlen comes from a uint16_t, so can't exceed this.
    // This also constrains [rrData length] to well less than a uint32_t.
    NSParameterAssert(rdlen < 65536);

    // Rather than write a whole bunch of icky parsing code, I just synthesise 
    // a resource record and use <dns_util.h>.

    rrData = [NSMutableData data];
    NSParameterAssert(rrData != nil);

    u8 = 0;
    [rrData appendBytes:&u8 length:sizeof(u8)];
    u16 = htons(kDNSServiceType_SRV);
    [rrData appendBytes:&u16 length:sizeof(u16)];
    u16 = htons(kDNSServiceClass_IN);
    [rrData appendBytes:&u16 length:sizeof(u16)];
    u32 = htonl(666);
    [rrData appendBytes:&u32 length:sizeof(u32)];
    u16 = htons(rdlen);
    [rrData appendBytes:&u16 length:sizeof(u16)];
    [rrData appendBytes:rdata length:rdlen];

    // Parse the record.
    rr = dns_parse_resource_record([rrData bytes], (uint32_t) [rrData length]);
    NSParameterAssert(rr != nil);

    if (rr != nil) {
        NSString *target = [NSString stringWithCString:rr->data.SRV->target encoding:NSASCIIStringEncoding];
        if (target != nil) {
            NSIndexSet *resultIndexSet;

            NSDictionary *result = @{
                SRVResolverResultsKeyPriority: @(rr->data.SRV->priority),
                SRVResolverResultsKeyWeight: @(rr->data.SRV->weight),
                SRVResolverResultsKeyPort: @(rr->data.SRV->port),
                SRVResolverResultsKeyTarget: target,
            };

            [_resultsMutable addObject:result];

            NSBlockOperation *resultsOperation = [NSBlockOperation new];
            [resultsOperation addExecutionBlock:^{
                [self.delegate srvResolverOperation:self didReceiveResult:result];
            }];
            if (_latestResultsOperation != nil) {
                [resultsOperation addDependency:_latestResultsOperation];
            }
            _latestResultsOperation = resultsOperation;
            [self.delegateQueue addOperation:resultsOperation];
        }

        dns_free_resource_record(rr);
    }
}

- (NSOperation *)finishOperation
{
    NSParameterAssert(self.isActualRunLoopThread);
    NSBlockOperation *finishOperation = [NSBlockOperation new];
    [finishOperation addExecutionBlock:^{
        [self.delegate srvResolverOperation:self didFinishWithError:self.error];
    }];
    // Make finish operation dependant on self
    // so that self has to transition into
    // it's finished state before the op fires
    [finishOperation addDependency:self];
    if (_latestResultsOperation != nil) {
        [finishOperation addDependency:_latestResultsOperation];
    }
    _latestResultsOperation = nil;
    return finishOperation;
}

@end
