#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^BTRRangeCompletion)(NSData * _Nullable data, NSNumber * _Nullable fileTotal,
                                  NSError * _Nullable error);
typedef void (^BTRValidatedRangeCompletion)(NSData * _Nullable data, NSNumber * _Nullable fileTotal,
                                          NSString * _Nullable strongETag, NSError * _Nullable error);

// Standalone media transport; this does not hook any Bilibili player.
// One in-flight range per instance. Starting another cancels the previous one.
// URLs must describe the same representation and have an approved HTTPS media host.
@interface BTRRangeDownloader : NSObject
@property(atomic,readonly) NSUInteger validatedPieces;
@property(atomic,readonly) NSInteger lastHTTPStatus;
// none / weak / strong / invalid of the last response; never the ETag value.
@property(atomic,copy,readonly,nullable) NSString *lastETagKind;
// Self-test only: also accept http://127.0.0.1 (in-process fault-injection origin).
@property(atomic) BOOL allowTestHost;
// Called on the internal queue after each piece attempt: ok/code/bytes/source/ttfbMs/ms.
@property(atomic,copy,nullable) void (^pieceObserver)(NSDictionary *piece);
- (nullable instancetype)initWithRangeCore:(NSString *)core policy:(NSString *)policy
                                    error:(NSError * _Nullable * _Nullable)error;
// Explicit experimental transport configuration. Legacy callers stay HTTPS / 4 / main.
- (nullable instancetype)initWithRangeCore:(NSString *)core policy:(NSString *)policy
                                allowHTTP:(BOOL)allowHTTP concurrency:(NSUInteger)concurrency
                          completionQueue:(dispatch_queue_t)queue error:(NSError * _Nullable * _Nullable)error;
- (void)downloadURLs:(NSArray<NSString *> *)urls start:(uint64_t)start end:(uint64_t)end
            headers:(NSDictionary<NSString *, NSString *> *)headers
         completion:(BTRRangeCompletion)completion;
// One exact source URL, no redirects. Identity is the strong ETag when present, otherwise @""
// (206 + Content-Range total/length only, as the desktop script); all pieces and the
// expected identity must agree. If-Range is sent only for a strong ETag.
- (void)downloadURL:(NSString *)url start:(uint64_t)start end:(uint64_t)end
            headers:(NSDictionary<NSString *, NSString *> *)headers
       expectedETag:(nullable NSString *)etag completion:(BTRValidatedRangeCompletion)completion;
// Same file on several CDN hosts: pieces rotate across them and a failed/stalled piece
// moves to the next host. Identity is then the Content-Range total only (identity @"").
- (void)downloadSources:(NSArray<NSString *> *)urls start:(uint64_t)start end:(uint64_t)end
                headers:(NSDictionary<NSString *, NSString *> *)headers
           expectedETag:(nullable NSString *)etag completion:(BTRValidatedRangeCompletion)completion;
- (void)cancel;
- (void)close; // Release the URLSession/delegate cycle when the owner is done.
@end
NS_ASSUME_NONNULL_END
