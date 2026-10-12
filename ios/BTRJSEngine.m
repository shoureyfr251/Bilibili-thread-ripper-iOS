#import "BTRJSEngine.h"
#import "BTRScripts.generated.h"
#import <JavaScriptCore/JavaScriptCore.h>

static void BTRReleaseData(void *bytes, void *context) { CFRelease(context); }

@interface BTREngine () <NSURLSessionDataDelegate>
@end

@implementation BTREngine {
    dispatch_queue_t _jsQueue, _completionQueue;
    JSContext *_context;
    NSURLSession *_session;
    NSMutableDictionary<NSNumber *,dispatch_source_t> *_timers;   // JS queue only
    NSMutableDictionary<NSNumber *,NSURLSessionDataTask *> *_tasks; // @synchronized(self)
    NSMutableDictionary<NSNumber *,NSNumber *> *_taskIds;           // taskIdentifier -> JS id
    NSMutableDictionary<NSNumber *,BTREngineCompletion> *_jobs;     // JS queue only
    uint64_t _jobSeq;
    BOOL _closed;
    NSUInteger _uncaught;
}

- (instancetype)initWithTestHosts:(NSArray<NSString *> *)testHosts error:(NSError **)error {
    if(!(self = [super init])) return nil;
    _jsQueue = dispatch_queue_create("local.btr.engine-js",DISPATCH_QUEUE_SERIAL);
    _completionQueue = dispatch_queue_create("local.btr.engine-done",DISPATCH_QUEUE_SERIAL);
    _timers = [NSMutableDictionary dictionary]; _tasks = [NSMutableDictionary dictionary];
    _taskIds = [NSMutableDictionary dictionary]; _jobs = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPMaximumConnectionsPerHost = 16;
    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO; config.URLCredentialStorage = nil;
    NSOperationQueue *delegateQueue = [NSOperationQueue new]; delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    __block NSString *failure = nil;
    dispatch_sync(_jsQueue, ^{ failure = [self loadWithTestHosts:testHosts]; });
    if(failure) { if(error) *error = [NSError errorWithDomain:@"BTREngine" code:1 userInfo:@{NSLocalizedDescriptionKey:failure}];
        [_session invalidateAndCancel]; return nil; }
    return self;
}

- (NSString *)loadWithTestHosts:(NSArray *)testHosts {
    _context = [JSContext new];
    __weak typeof(self) weak = self;
    _context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        context.exception = exception; typeof(self) strong = weak; if(strong) strong->_uncaught++;
    };
    if(testHosts.count) _context[@"__BTR_TEST_HOSTS__"] = testHosts;
    JSValue *native = [JSValue valueWithNewObjectInContext:_context];
    native[@"now"] = ^double { return NSProcessInfo.processInfo.systemUptime * 1000; };
    native[@"setTimer"] = ^(double identifier, double ms) { [weak setTimer:(uint64_t)identifier ms:ms]; };
    native[@"clearTimer"] = ^(double identifier) { [weak clearTimer:(uint64_t)identifier]; };
    native[@"httpStart"] = ^(double identifier, NSString *url, NSDictionary *headers) { [weak httpStart:(uint64_t)identifier url:url headers:headers]; };
    native[@"httpCancel"] = ^(double identifier) { [weak httpCancel:(uint64_t)identifier]; };
    native[@"jobDone"] = ^(double identifier, JSValue *bytes, double total, JSValue *message, double hosts) {
        [weak jobDone:(uint64_t)identifier bytes:bytes total:(int64_t)total
                error:message.isString ? message.toString : nil hosts:(NSUInteger)MAX(0,hosts)];
    };
    _context[@"btrNative"] = native;
    const char *scripts[] = {BTREngineRangeCoreScript, BTREngineShimScript, BTREnginePreludeScript,
                             BTREngineResolverScript, BTREngineDownloaderScript, BTREngineGlueScript};
    const char *names[] = {"range-core.js","shims.js","engine-prelude.js","cdn-resolver.js","idm-downloader.js","engine.js"};
    for(size_t i = 0; i < sizeof(scripts) / sizeof(scripts[0]); i++) {
        _context.exception = nil;
        [_context evaluateScript:[NSString stringWithUTF8String:scripts[i]] withSourceURL:[NSURL URLWithString:[NSString stringWithUTF8String:names[i]]]];
        if(_context.exception) return [NSString stringWithFormat:@"%s: %@",names[i],_context.exception.toString];
    }
    if(![_context[@"BTREngine"] isObject]) return @"BTREngine missing";
    // Promise jobs must run when native code calls back into JS, or nothing ever settles.
    [_context evaluateScript:@"globalThis.__btrDrain = 0; Promise.resolve().then(() => { globalThis.__btrDrain = 1; });"];
    if(![_context[@"__btrDrain"] toInt32]) return @"microtasks_not_drained";
    _usable = YES;
    return nil;
}

#pragma mark Timers (JS queue)

- (void)setTimer:(uint64_t)identifier ms:(double)ms {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_jsQueue);
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,ms) * NSEC_PER_MSEC)),DISPATCH_TIME_FOREVER,NSEC_PER_MSEC);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strong = weak; if(!strong) return;
        dispatch_source_t own = strong->_timers[@(identifier)];
        if(!own) return;
        dispatch_source_cancel(own); [strong->_timers removeObjectForKey:@(identifier)];
        [strong call:@"__btrFireTimer" arguments:@[@(identifier)]];
    });
    _timers[@(identifier)] = timer;
    dispatch_resume(timer);
}
- (void)clearTimer:(uint64_t)identifier {
    dispatch_source_t timer = _timers[@(identifier)];
    if(timer) { dispatch_source_cancel(timer); [_timers removeObjectForKey:@(identifier)]; }
}
- (void)call:(NSString *)name arguments:(NSArray *)arguments {
    if(_closed) return;
    _context.exception = nil;
    [_context[name] callWithArguments:arguments];
}

#pragma mark HTTP (JS queue in, delegate queue out)

- (void)httpStart:(uint64_t)identifier url:(NSString *)url headers:(NSDictionary *)headers {
    NSURL *target = [url isKindOfClass:NSString.class] ? [NSURL URLWithString:url] : nil;
    if(!target || ![@[@"http",@"https"] containsObject:target.scheme.lowercaseString ?: @""]) {
        [self call:@"__btrHttpEnd" arguments:@[@(identifier),@"Invalid URL"]]; return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
    for(NSString *name in headers) if([headers[name] isKindOfClass:NSString.class]) [request setValue:headers[name] forHTTPHeaderField:name];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
    @synchronized(self) { _tasks[@(identifier)] = task; _taskIds[@(task.taskIdentifier)] = @(identifier); }
    [task resume];
}
- (void)httpCancel:(uint64_t)identifier {
    NSURLSessionDataTask *task;
    @synchronized(self) { task = _tasks[@(identifier)]; [_tasks removeObjectForKey:@(identifier)];
        if(task) [_taskIds removeObjectForKey:@(task.taskIdentifier)]; }
    [task cancel];
}
- (NSNumber *)jsIdFor:(NSURLSessionTask *)task remove:(BOOL)remove {
    @synchronized(self) {
        NSNumber *identifier = _taskIds[@(task.taskIdentifier)];
        if(identifier && remove) { [_taskIds removeObjectForKey:@(task.taskIdentifier)]; [_tasks removeObjectForKey:identifier]; }
        return identifier;
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    NSNumber *identifier = [self jsIdFor:task remove:NO];
    if(!identifier) { handler(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for(id name in http.allHeaderFields) headers[[name description]] = [http.allHeaderFields[name] description];
    NSInteger status = http.statusCode;
    dispatch_async(_jsQueue, ^{ [self call:@"__btrHttpResponse" arguments:@[identifier,@(status),headers]]; });
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSNumber *identifier = [self jsIdFor:task remove:NO];
    if(!identifier || !data.length) return;
    NSData *contiguous = [NSData dataWithData:data]; // One flat buffer, owned by the typed array below.
    dispatch_async(_jsQueue, ^{
        if(self->_closed) return;
        JSGlobalContextRef context = self->_context.JSGlobalContextRef;
        JSValueRef exception = NULL;
        JSObjectRef array = JSObjectMakeTypedArrayWithBytesNoCopy(context,kJSTypedArrayTypeUint8Array,(void *)contiguous.bytes,
            contiguous.length,BTRReleaseData,(void *)CFBridgingRetain(contiguous),&exception);
        if(!array || exception) return;
        [self call:@"__btrHttpData" arguments:@[identifier,[JSValue valueWithJSValueRef:array inContext:self->_context]]];
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    handler(nil); // Signed media addresses are never followed elsewhere.
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *identifier = [self jsIdFor:task remove:YES];
    if(!identifier) return;
    NSString *message = error ? [NSString stringWithFormat:@"NSURLError %ld",(long)error.code] : nil;
    dispatch_async(_jsQueue, ^{ [self call:@"__btrHttpEnd" arguments:@[identifier,message ?: [NSNull null]]]; });
}

#pragma mark Jobs

- (void)configure:(NSDictionary *)options {
    dispatch_async(_jsQueue, ^{
        if(self->_closed) return;
        [self->_context[@"BTREngine"] invokeMethod:@"configure" withArguments:@[options ?: @{}]];
    });
}
- (uint64_t)downloadURL:(NSString *)raw alternates:(NSArray *)alternates headers:(NSDictionary *)headers
                  start:(uint64_t)start end:(uint64_t)end startup:(BOOL)startup completion:(BTREngineCompletion)completion {
    return [self downloadURL:raw alternates:alternates headers:headers start:start end:end startup:startup meta:NO completion:completion];
}
- (uint64_t)downloadURL:(NSString *)raw alternates:(NSArray *)alternates headers:(NSDictionary *)headers
                  start:(uint64_t)start end:(uint64_t)end startup:(BOOL)startup meta:(BOOL)meta completion:(BTREngineCompletion)completion {
    __block uint64_t job = 0;
    dispatch_sync(_jsQueue, ^{
        job = ++self->_jobSeq;
        if(self->_closed || !self->_usable) {
            dispatch_async(self->_completionQueue, ^{ completion(nil,-1,@"engine_closed",0); }); return;
        }
        self->_jobs[@(job)] = [completion copy];
        self->_context.exception = nil;
        [self->_context[@"BTREngine"] invokeMethod:@"download" withArguments:@[@(job),raw,alternates ?: @[],headers ?: @{},
            @((double)start),@((double)end),@(startup),@(meta)]];
        if(self->_context.exception) [self jobDone:job bytes:nil total:-1 error:@"engine_exception" hosts:0];
    });
    return job;
}
- (void)jobDone:(uint64_t)job bytes:(JSValue *)bytes total:(int64_t)total error:(NSString *)error hosts:(NSUInteger)hosts {
    BTREngineCompletion completion = _jobs[@(job)];
    if(!completion) return;
    [_jobs removeObjectForKey:@(job)];
    NSData *data = nil;
    if(!error && bytes.isObject) {
        JSGlobalContextRef context = _context.JSGlobalContextRef; JSValueRef exception = NULL;
        JSObjectRef object = JSValueToObject(context,bytes.JSValueRef,&exception);
        if(object && !exception && JSValueGetTypedArrayType(context,object,&exception) == kJSTypedArrayTypeUint8Array) {
            void *pointer = JSObjectGetTypedArrayBytesPtr(context,object,&exception);
            size_t length = JSObjectGetTypedArrayByteLength(context,object,&exception);
            if(pointer && !exception) data = [NSData dataWithBytes:pointer length:length];
        }
        if(!data) error = @"engine_bytes_unreadable";
    } else if(!error) error = @"engine_no_bytes";
    dispatch_async(_completionQueue, ^{ completion(data,total,error,hosts); });
}
- (void)cancelJob:(uint64_t)job {
    dispatch_async(_jsQueue, ^{
        if(self->_closed) return;
        [self->_context[@"BTREngine"] invokeMethod:@"cancel" withArguments:@[@(job)]];
    });
}
- (NSDictionary *)stats {
    __block NSDictionary *result = @{};
    dispatch_sync(_jsQueue, ^{
        if(self->_closed || !self->_usable) return;
        NSDictionary *stats = [[self->_context[@"BTREngine"] invokeMethod:@"stats" withArguments:@[]] toDictionary];
        NSMutableDictionary *copy = [stats mutableCopy] ?: [NSMutableDictionary dictionary];
        copy[@"uncaught"] = @(self->_uncaught); copy[@"openJobs"] = @(self->_jobs.count);
        result = copy;
    });
    return result;
}
- (void)close {
    dispatch_sync(_jsQueue, ^{
        if(self->_closed) return;
        for(NSNumber *job in self->_jobs.allKeys) [self->_context[@"BTREngine"] invokeMethod:@"cancel" withArguments:@[job]];
        self->_closed = YES;
        for(dispatch_source_t timer in self->_timers.allValues) dispatch_source_cancel(timer);
        [self->_timers removeAllObjects];
        NSDictionary *pending = [self->_jobs copy]; [self->_jobs removeAllObjects];
        for(NSNumber *job in pending) { BTREngineCompletion completion = pending[job];
            dispatch_async(self->_completionQueue, ^{ completion(nil,-1,@"cancelled",0); }); }
    });
    [_session invalidateAndCancel];
}
@end
