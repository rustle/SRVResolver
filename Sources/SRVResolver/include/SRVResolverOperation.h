@import Foundation;

#import "SRVRunLoopOperation.h"

#include <dns_sd.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SRVResolverDelegate;

typedef NSString *SRVResolverResultsKey NS_EXTENSIBLE_STRING_ENUM;

extern SRVResolverResultsKey SRVResolverResultsKeyPriority; // NSNumber, host byte order
extern SRVResolverResultsKey SRVResolverResultsKeyWeight; // NSNumber, host byte order
extern SRVResolverResultsKey SRVResolverResultsKeyPort; // NSNumber, host byte order
extern SRVResolverResultsKey SRVResolverResultsKeyTarget; // NSString

extern NSErrorDomain SRVResolverErrorDomain;

@interface SRVResolverOperation : SRVRunLoopOperation

- (instancetype)initWithSRVName:(NSString *)srvName timeout:(NSTimeInterval)timeout;

@property (nonatomic, copy, readonly) NSString *srvName;
@property (nonatomic, assign, readonly) NSTimeInterval timeout;
@property (nonatomic, weak, readwrite, nullable) id<SRVResolverDelegate> delegate;
@property (nonatomic, strong, null_resettable) NSOperationQueue *delegateQueue;

@end

@protocol SRVResolverDelegate <NSObject>

/// Called when we've successfully receive an answer. This callback can be
/// called multiple times if there are multiple results. You learn that the last
/// result was delivered by way of the -srvResolver:didStopWithError: callback.
- (void)srvResolverOperation:(SRVResolverOperation *)resolver didReceiveResult:(NSDictionary<SRVResolverResultsKey, id> *)result;

/// Called when the query stops either because it's received all the results (error is nil) or there's been an
/// error
- (void)srvResolverOperation:(SRVResolverOperation *)resolver didFinishWithError:(NSError *__nullable)error;

@end

NS_ASSUME_NONNULL_END
