#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class BTREngine;

// Experimental same-process, video-only HTTP Range adapter. Disabled by default.
// Script strings are compiled into the dylib; no external resource is required.
@interface BTRLoopbackRangeAdapter : NSObject
@property(nonatomic) BOOL enabled;
// Self-test instances only: also map http://127.0.0.1:<port> (fault-injection origin).
@property(atomic) uint16_t testOriginPort;
// Transport tuning (defaults 4 pieces, 2 MiB windows, 512 KiB first window); set before use.
@property(atomic) NSUInteger pieceConcurrency;
@property(atomic) uint64_t windowBytes, firstWindowBytes;
// Desktop engine (nil = legacy per-connection downloader). Set before use, together with
// useDesktopDefaults; windows beyond the first are prefetched up to prefetchDepth.
@property(atomic,strong,nullable) BTREngine *engine;
@property(atomic) NSUInteger prefetchDepth;
- (void)useDesktopDefaults; // 1 MiB startup window, 16 MiB windows, depth 3
- (nullable instancetype)initWithError:(NSError * _Nullable * _Nullable)error;
// Call BEFORE the original play method. Revokes old token/connections immediately.
- (uint64_t)beginGeneration;
- (void)invalidateGeneration:(uint64_t)generation;
// Synchronous registration only: never waits for network data. Exact signed raw
// URL stays in memory; returns nil when disabled/stale/bypassed/over the mapping cap.
// Each exact source URL gets its own token (CDN switch/reopen); a fallback redirect
// bypasses only that URL for the rest of the generation to avoid loops.
// headers=nil means unknown source metadata (no mapping); @{} means observed
// empty. Only exact observed User-Agent/Referer/Origin strings are forwarded.
- (nullable NSString *)mapVideoURL:(NSString *)rawURL generation:(uint64_t)generation
                           headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                             error:(NSError * _Nullable * _Nullable)error;
// alternates: the same file's URLs on other CDN hosts (same path); pieces rotate across them.
- (nullable NSString *)mapVideoURL:(NSString *)rawURL generation:(uint64_t)generation
                           headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                        alternates:(nullable NSArray<NSString *> *)alternates
                             error:(NSError * _Nullable * _Nullable)error;
// Counters/state only; excludes source URL, token, host, headers, ETag and bodies.
- (NSDictionary *)snapshot;
- (void)close;
@end
NS_ASSUME_NONNULL_END
