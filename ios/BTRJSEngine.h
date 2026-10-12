#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef void (^BTREngineCompletion)(NSData * _Nullable data, int64_t total, NSString * _Nullable error, NSUInteger hosts);

// The unmodified desktop downloader (range-core, cdn-resolver, idm-downloader) in one
// JavaScriptCore context, with native timers and streaming NSURLSession behind ios/js/shims.js.
// One engine = one shared thread budget, node health and ban list (like one desktop page).
// testHosts: self-test only; accepts plain-HTTP origins on these hosts and disables mirrors.
@interface BTREngine : NSObject
@property(atomic,readonly) BOOL usable; // Context loaded and promise jobs drain.
- (nullable instancetype)initWithTestHosts:(nullable NSArray<NSString *> *)testHosts error:(NSError * _Nullable * _Nullable)error;
- (void)configure:(NSDictionary *)options; // mode / concurrency / autoConcurrency
// Completion runs on a private queue. Exactly one completion per job, also after cancel.
- (uint64_t)downloadURL:(NSString *)raw alternates:(nullable NSArray<NSString *> *)alternates
                headers:(NSDictionary<NSString *,NSString *> *)headers start:(uint64_t)start end:(uint64_t)end
                startup:(BOOL)startup completion:(BTREngineCompletion)completion;
- (uint64_t)downloadURL:(NSString *)raw alternates:(nullable NSArray<NSString *> *)alternates
                headers:(NSDictionary<NSString *,NSString *> *)headers start:(uint64_t)start end:(uint64_t)end
                startup:(BOOL)startup meta:(BOOL)meta completion:(BTREngineCompletion)completion;
- (void)cancelJob:(uint64_t)job;
- (NSDictionary *)stats; // Counters, per-host state/speed, errors; no URL or header values.
- (void)close;
@end
NS_ASSUME_NONNULL_END
