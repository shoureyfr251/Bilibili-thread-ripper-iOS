#import "BTRRangeDownloader.h"
#import <JavaScriptCore/JavaScriptCore.h>

static NSError *BTRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"BTRRange" code:code
                          userInfo:@{NSLocalizedDescriptionKey:message ?: @"Download failed"}];
}

@interface BTRAttempt : NSObject
@property(nonatomic,strong) NSDictionary *plan;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,copy,nullable) NSString *rejection;
@property(nonatomic) NSInteger failureCode;
@property(nonatomic) NSTimeInterval began, firstByte, lastProgress;
@end
@implementation BTRAttempt
@end

@interface BTRRangeDownloader () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic,strong) JSContext *context;
@property(nonatomic,strong,nullable) JSValue *job;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) dispatch_queue_t stateQueue;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,BTRAttempt *> *attempts;
@property(nonatomic,strong) NSMutableArray *pieces;
@property(nonatomic,copy) NSDictionary *headers;
@property(nonatomic,copy,nullable) BTRValidatedRangeCompletion completion;
@property(nonatomic,strong) dispatch_queue_t completionQueue;
@property(nonatomic) BOOL allowHTTP;
@property(nonatomic) NSUInteger concurrency;
@property(nonatomic) BOOL requireStrongETag;
@property(nonatomic,copy,nullable) NSString *expectedETag;
@property(nonatomic,copy,nullable) NSString *responseETag;
@property(nonatomic) BOOL closed;
@property(atomic,readwrite) NSUInteger validatedPieces;
@property(atomic,readwrite) NSInteger lastHTTPStatus;
@property(atomic,copy,readwrite,nullable) NSString *lastETagKind;
@property(nonatomic) NSInteger lastFailureCode;
@property(nonatomic) BOOL singleSource;
@property(nonatomic,copy) NSArray *urls;
@property(nonatomic,strong,nullable) dispatch_source_t watchdog;
@end
// A piece with no first byte / no progress for this long is cancelled and reissued
// (next candidate URL when alternates exist), like the desktop rescue of stragglers.
static const NSTimeInterval BTRFirstByteStall = 5, BTRProgressStall = 3;

@implementation BTRRangeDownloader
- (instancetype)initWithRangeCore:(NSString *)core policy:(NSString *)policy error:(NSError **)error {
    return [self initWithRangeCore:core policy:policy allowHTTP:NO concurrency:4
                 completionQueue:dispatch_get_main_queue() error:error];
}
- (instancetype)initWithRangeCore:(NSString *)core policy:(NSString *)policy allowHTTP:(BOOL)allowHTTP
                      concurrency:(NSUInteger)concurrency completionQueue:(dispatch_queue_t)queue error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _allowHTTP = allowHTTP; _concurrency = MAX(1,MIN(8,concurrency)); _completionQueue = queue;
    _stateQueue = dispatch_queue_create("local.btr.range-state", DISPATCH_QUEUE_SERIAL);
    _attempts = [NSMutableDictionary dictionary]; _pieces = [NSMutableArray array];
    __block NSString *scriptError = nil;
    // Create and use JSContext exclusively on the state queue.
    dispatch_sync(_stateQueue, ^{
        self.context = [[JSContext alloc] init];
        self.context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
            context.exception = exception;
        };
        self.context[@"btrDescribeURL"] = ^id(NSString *raw) {
            NSURLComponents *url = [NSURLComponents componentsWithString:raw];
            if (!url || !url.host.length) return [NSNull null];
            return @{ @"scheme":url.scheme.lowercaseString ?: @"",
                      @"host":url.host.lowercaseString ?: @"",
                      @"path":url.percentEncodedPath ?: @"",
                      @"hasCredentials":@((url.user != nil) || (url.password != nil)) };
        };
        [self.context evaluateScript:core];
        if (self.context.exception) scriptError = [self.context.exception toString];
        if (!scriptError) {
            [self.context evaluateScript:policy];
            if (self.context.exception) scriptError = [self.context.exception toString];
        }
    });
    if (scriptError) { if(error) *error = BTRError(1,scriptError); return nil; }
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = self.concurrency;
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil;
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    return self;
}

- (void)downloadURLs:(NSArray<NSString *> *)urls start:(uint64_t)start end:(uint64_t)end
            headers:(NSDictionary<NSString *,NSString *> *)headers completion:(BTRRangeCompletion)completion {
    [self startURLs:urls start:start end:end headers:headers expectedETag:nil requireStrongETag:NO
        completion:^(NSData *data,NSNumber *total,NSString *etag,NSError *error) { completion(data,total,error); }];
}
- (void)downloadURL:(NSString *)url start:(uint64_t)start end:(uint64_t)end
            headers:(NSDictionary<NSString *,NSString *> *)headers expectedETag:(NSString *)etag
         completion:(BTRValidatedRangeCompletion)completion {
    [self startURLs:@[url] start:start end:end headers:headers expectedETag:etag requireStrongETag:YES completion:completion];
}
- (void)downloadSources:(NSArray<NSString *> *)urls start:(uint64_t)start end:(uint64_t)end
                headers:(NSDictionary<NSString *,NSString *> *)headers expectedETag:(NSString *)etag
             completion:(BTRValidatedRangeCompletion)completion {
    [self startURLs:urls start:start end:end headers:headers expectedETag:urls.count > 1 ? nil : etag
  requireStrongETag:YES completion:completion];
}
- (void)startURLs:(NSArray *)urls start:(uint64_t)start end:(uint64_t)end headers:(NSDictionary *)headers
     expectedETag:(NSString *)etag requireStrongETag:(BOOL)required completion:(BTRValidatedRangeCompletion)completion {
    NSArray *requestURLs = [urls copy]; NSDictionary *requestHeaders = [headers copy];
    dispatch_async(self.stateQueue, ^{
        [self finish:BTRError(NSURLErrorCancelled,@"Superseded by a new range") data:nil total:nil];
        if(self.closed) {
            dispatch_async(self.completionQueue, ^{ completion(nil,nil,nil,BTRError(2,@"Downloader closed")); });
            return;
        }
        self.completion = completion; self.headers = requestHeaders;
        self.urls = requestURLs; self.singleSource = requestURLs.count == 1;
        self.requireStrongETag = required; self.expectedETag = [etag copy]; self.responseETag = nil;
        self.validatedPieces = 0;
        self.lastHTTPStatus = 0; self.lastFailureCode = 0; self.lastETagKind = nil;
        self.context.exception = nil;
        self.job = [self.context[@"BTRPolicy"][@"Job"] constructWithArguments:
                    @[@{@"urls":requestURLs,@"start":@(start),@"end":@(end),
                         @"concurrency":@(self.concurrency),@"allowHTTP":@(self.allowHTTP),
                         @"allowTestHost":@(self.allowTestHost)}]];
        if(self.context.exception || !self.job || self.job.isUndefined) {
            NSString *message = [self.context.exception toString] ?: @"Invalid range request";
            [self finish:BTRError(3,message) data:nil total:nil]; return;
        }
        NSUInteger count = [[[self.job invokeMethod:@"snapshot" withArguments:@[]] toDictionary][@"pieces"] unsignedIntegerValue];
        for(NSUInteger i=0;i<count;i++) [self.pieces addObject:[NSNull null]];
        [self startWatchdog];
        [self pump];
    });
}

- (void)startWatchdog {
    if(self.watchdog) return;
    self.watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.stateQueue);
    dispatch_source_set_timer(self.watchdog,dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),250*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(self.watchdog, ^{
        typeof(self) strong = weak; if(!strong || !strong.job) return;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        for(BTRAttempt *attempt in strong.attempts.allValues) {
            if(attempt.rejection) continue;
            BOOL stalled = attempt.firstByte ? now - attempt.lastProgress > BTRProgressStall : now - attempt.began > BTRFirstByteStall;
            // didComplete reports the cancellation; the policy then reissues the piece.
            if(stalled) { attempt.rejection = @"Stalled piece restarted"; attempt.failureCode = 11; [attempt.task cancel]; }
        }
    });
    dispatch_resume(self.watchdog);
}
- (void)report:(BTRAttempt *)attempt ok:(BOOL)ok code:(NSInteger)code {
    void (^observer)(NSDictionary *) = self.pieceObserver;
    if(!observer) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSUInteger source = [self.urls indexOfObject:attempt.plan[@"url"] ?: @""];
    observer(@{@"ok":@(ok),@"code":@(code),@"bytes":@(attempt.body.length),@"source":@(source == NSNotFound ? 0 : source),@"url":attempt.plan[@"url"] ?: @"",
               @"ttfbMs":@(attempt.firstByte ? (attempt.firstByte - attempt.began) * 1000 : -1),@"ms":@((now - attempt.began) * 1000)});
}
- (void)finish:(NSError *)error data:(NSData *)data total:(NSNumber *)total {
    if(self.watchdog) { dispatch_source_cancel(self.watchdog); self.watchdog = nil; }
    if(self.job) [self.job invokeMethod:@"cancel" withArguments:@[]];
    self.job = nil;
    for(BTRAttempt *attempt in self.attempts.allValues) [attempt.task cancel];
    [self.attempts removeAllObjects]; [self.pieces removeAllObjects];
    BTRValidatedRangeCompletion callback = self.completion; self.completion = nil;
    NSString *etag = self.responseETag; self.responseETag = nil;
    if(callback) dispatch_async(self.completionQueue, ^{ callback(data,total,etag,error); });
}

- (void)pump {
    if(!self.job || !self.completion) return;
    NSDictionary *snapshot = [[self.job invokeMethod:@"snapshot" withArguments:@[]] toDictionary];
    if([snapshot[@"state"] isEqual:@"failed"]) {
        [self finish:BTRError(self.lastFailureCode ?: 4,snapshot[@"error"]) data:nil total:nil]; return;
    }
    if([snapshot[@"state"] isEqual:@"done"]) {
        NSMutableData *data = [NSMutableData dataWithCapacity:[snapshot[@"length"] unsignedIntegerValue]];
        for(id piece in self.pieces) {
            if(![piece isKindOfClass:[NSData class]]) { [self finish:BTRError(5,@"Missing range piece") data:nil total:nil]; return; }
            [data appendData:piece];
        }
        if(data.length != [snapshot[@"length"] unsignedIntegerValue]) {
            [self finish:BTRError(6,@"Reassembly length mismatch") data:nil total:nil]; return;
        }
        self.validatedPieces = [snapshot[@"pieces"] unsignedIntegerValue];
        [self finish:nil data:data total:snapshot[@"total"]]; return;
    }
    NSArray *plans = [[self.job invokeMethod:@"next" withArguments:@[]] toArray];
    for(NSDictionary *plan in plans) {
        NSURL *url = [NSURL URLWithString:plan[@"url"]];
        if(!url) { [self.job invokeMethod:@"fail" withArguments:@[plan[@"id"],@"Invalid native URL"]]; continue; }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:[NSString stringWithFormat:@"bytes=%@-%@",plan[@"start"],plan[@"end"]] forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        if(self.expectedETag.length && self.singleSource) [request setValue:self.expectedETag forHTTPHeaderField:@"If-Range"];
        // Explicit caller-owned transport metadata only, never copied account cookies.
        for(NSString *name in @[@"Referer",@"User-Agent",@"Origin"])
            if(self.headers[name]) [request setValue:self.headers[name] forHTTPHeaderField:name];
        BTRAttempt *attempt = [[BTRAttempt alloc] init];
        attempt.plan = plan; attempt.body = [NSMutableData data]; attempt.began = NSProcessInfo.processInfo.systemUptime;
        attempt.task = [self.session dataTaskWithRequest:request];
        self.attempts[@(attempt.task.taskIdentifier)] = attempt;
        [attempt.task resume];
    }
    // A URL rejected natively advances policy without creating a delegate callback.
    if(!self.attempts.count && plans.count) [self pump];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    dispatch_async(self.stateQueue, ^{
        BTRAttempt *attempt = self.attempts[@(task.taskIdentifier)];
        if(!attempt || !self.job) { completionHandler(NSURLSessionResponseCancel); return; }
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (id)response : nil;
        self.lastHTTPStatus = http.statusCode;
        NSString *range = [http valueForHTTPHeaderField:@"Content-Range"];
        NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
        NSString *etag = [http valueForHTTPHeaderField:@"ETag"];
        BOOL strong = etag.length >= 2 && etag.length <= 1024 && [etag hasPrefix:@"\""] && [etag hasSuffix:@"\""]
            && [etag rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
        for(NSUInteger i=1;strong && i+1<etag.length;i++) {
            unichar c = [etag characterAtIndex:i];
            // One RFC opaque-tag, not a comma-joined list or invalid encoding.
            if(c == '"' || c < 0x21 || c > 0x7e) strong = NO;
        }
        self.lastETagKind = !etag ? @"none" : strong ? @"strong" : [etag hasPrefix:@"W/"] ? @"weak" : @"invalid";
        // Weak/absent/invalid tags give no byte identity: fall back to the validated
        // 206 + Content-Range total, but never mix with a strong tag across pieces.
        // Across CDN hosts ETags differ for the same file: identity is the 206 total only.
        NSString *identity = strong && self.singleSource ? etag : @"";
        NSString *reference = self.expectedETag ?: self.responseETag;
        BOOL mismatch = self.requireStrongETag && reference && ![identity isEqual:reference];
        BOOL valid = [[self.job invokeMethod:@"headers" withArguments:
                      @[attempt.plan[@"id"],@(http.statusCode),range ?: @"",encoding ?: @""]] toBool];
        if(response.expectedContentLength >= 0 && (uint64_t)response.expectedContentLength != [attempt.plan[@"length"] unsignedLongLongValue]) valid = NO;
        if(mismatch) valid = NO;
        if(!valid) attempt.failureCode = http && http.statusCode != 206 ? 10 : mismatch ? 8 : 9;
        if(valid && self.requireStrongETag && !self.responseETag) self.responseETag = identity;
        if(!valid) attempt.rejection = @"Invalid 206 / Content-Range / length response";
        completionHandler(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    // Back-pressure the independent delegate queue: do not enqueue unlimited
    // NSData blocks while the state queue is checking the bounded buffer.
    // The state queue never waits synchronously on the delegate queue.
    dispatch_sync(self.stateQueue, ^{
        BTRAttempt *attempt = self.attempts[@(task.taskIdentifier)];
        if(!attempt || !self.job || attempt.rejection) return;
        NSUInteger maximum = [attempt.plan[@"length"] unsignedIntegerValue];
        if(data.length > maximum - attempt.body.length) {
            attempt.rejection = @"Response exceeds requested range"; attempt.failureCode = 9; [task cancel]; return;
        }
        [attempt.body appendData:data];
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if(!attempt.firstByte) attempt.firstByte = now;
        attempt.lastProgress = now;
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_async(self.stateQueue, ^{
        NSNumber *key = @(task.taskIdentifier); BTRAttempt *attempt = self.attempts[key];
        // Replacement/cancellation removes the task entry; old callbacks are inert.
        if(!attempt || !self.job) return;
        [self.attempts removeObjectForKey:key];
        BOOL accepted = NO;
        if(!error && !attempt.rejection)
            accepted = [[self.job invokeMethod:@"finish" withArguments:@[attempt.plan[@"id"],@(attempt.body.length)]] toBool];
        if(accepted) { self.pieces[[attempt.plan[@"index"] unsignedIntegerValue]] = attempt.body; [self report:attempt ok:YES code:0]; }
        else {
            self.lastFailureCode = attempt.failureCode ?: (error ? error.code : 9);
            [self report:attempt ok:NO code:self.lastFailureCode];
            [self.job invokeMethod:@"fail" withArguments:@[attempt.plan[@"id"],
                attempt.rejection ?: (error.localizedDescription ?: @"Response length mismatch")]];
        }
        [self pump];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // Do not send a signed URL to an unvalidated redirect target.
    dispatch_async(self.stateQueue, ^{
        BTRAttempt *attempt = self.attempts[@(task.taskIdentifier)];
        attempt.rejection = @"Redirect unsupported; supply the final authorized media URL";
        completionHandler(nil);
    });
}

- (void)cancel {
    dispatch_async(self.stateQueue, ^{ [self finish:BTRError(NSURLErrorCancelled,@"Cancelled") data:nil total:nil]; });
}
- (void)close {
    dispatch_async(self.stateQueue, ^{
        self.closed = YES; [self finish:BTRError(NSURLErrorCancelled,@"Closed") data:nil total:nil];
        [self.session invalidateAndCancel]; self.session = nil;
    });
}
@end
