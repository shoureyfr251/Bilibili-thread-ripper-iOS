#import "BTRSelfTest.h"
#import "../BTRLoopbackRangeAdapter.h"
#import "../BTRJSEngine.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

static const uint64_t BTRMiB = 1024 * 1024;
static double BTRNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static double BTRMs(double since) { return round((BTRNow() - since) * 10000) / 10; }

// Deterministic fake media: any byte is checkable without storing the file.
static inline uint8_t BTRFakeByte(uint64_t i, int variant) {
    uint64_t x = (i + (uint64_t)variant * 7919) * 0x9E3779B97F4A7C15ull;
    return (uint8_t)(x >> 56) ^ (uint8_t)i;
}

static BOOL BTRSendAll(int fd, const void *bytes, size_t length) {
    size_t offset = 0;
    while(offset < length) {
        ssize_t sent = send(fd,(const uint8_t *)bytes + offset,length - offset,0);
        if(sent < 0 && errno == EINTR) continue;
        if(sent <= 0) return NO;
        offset += (size_t)sent;
    }
    return YES;
}
static void BTRSocketDefaults(int fd, int seconds) {
    int yes = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    struct timeval timeout = {seconds,0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
}
// Reads one HTTP header block; extra bytes already received are returned in body.
static NSString *BTRReadHead(int fd, NSMutableData *body) {
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[4096];
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    while(data.length < 16384) {
        ssize_t size = recv(fd,buffer,sizeof(buffer),0);
        if(size < 0 && errno == EINTR) continue;
        if(size <= 0) return nil;
        [data appendBytes:buffer length:(NSUInteger)size];
        NSRange end = [data rangeOfData:separator options:0 range:NSMakeRange(0,data.length)];
        if(end.location != NSNotFound) {
            [body appendData:[data subdataWithRange:NSMakeRange(NSMaxRange(end),data.length - NSMaxRange(end))]];
            return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0,end.location)] encoding:NSASCIIStringEncoding];
        }
    }
    return nil;
}
static NSString *BTRHeader(NSString *head, NSString *name) {
    for(NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if(colon.location == NSNotFound || [[line substringToIndex:colon.location] caseInsensitiveCompare:name] != NSOrderedSame) continue;
        return [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return nil;
}

#pragma mark - Fault-injection origin

// Path: /<mode>/<sizeKiB>/media.m4s[?anything]. Modes: ok throttle reset flaky403
// weak noetag badtag overshoot mutate stall slow. Counters are per mode.
@interface BTRFakeOrigin : NSObject
@property(nonatomic,readonly) uint16_t port;
- (BOOL)start;
- (void)stop;
@end
@implementation BTRFakeOrigin {
    int _fd;
    NSMutableDictionary<NSString *,NSNumber *> *_counts;
}
- (BOOL)start {
    _counts = [NSMutableDictionary dictionary];
    _fd = socket(AF_INET,SOCK_STREAM,0); if(_fd < 0) return NO;
    int yes = 1; setsockopt(_fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address);
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t size = sizeof(address);
    if(bind(_fd,(struct sockaddr *)&address,sizeof(address)) || listen(_fd,64)
       || getsockname(_fd,(struct sockaddr *)&address,&size)) { close(_fd); _fd = -1; return NO; }
    _port = ntohs(address.sin_port);
    int listener = _fd;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        while(YES) {
            int client = accept(listener,NULL,NULL);
            if(client < 0) { if(errno == EINTR) continue; return; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                @autoreleasepool { [self handle:client]; }
                close(client);
            });
        }
    });
    return YES;
}
- (void)stop { if(_fd >= 0) { shutdown(_fd,SHUT_RDWR); close(_fd); _fd = -1; } }
- (NSUInteger)next:(NSString *)mode {
    @synchronized(self) { NSUInteger n = _counts[mode].unsignedIntegerValue + 1; _counts[mode] = @(n); return n; }
}
- (void)handle:(int)fd {
    BTRSocketDefaults(fd,10);
    NSString *head = BTRReadHead(fd,[NSMutableData data]);
    NSArray *first = [[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    if(first.count < 2) return;
    NSString *method = first[0], *path = [first[1] componentsSeparatedByString:@"?"].firstObject;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if(parts.count != 4) return;
    NSString *mode = parts[1];
    NSUInteger n = [self next:mode];
    uint64_t total = (uint64_t)[parts[2] longLongValue] * 1024; int variant = 0;
    NSString *etag = @"\"btr-fake-1\"";
    if([mode isEqual:@"weak"]) etag = @"W/\"btr-fake-1\"";
    else if([mode isEqual:@"noetag"]) etag = nil;
    else if([mode isEqual:@"badtag"]) etag = @"btr-fake-1";
    else if([mode isEqual:@"mutate"] && n > 6) { total += BTRMiB; variant = 1; etag = @"\"btr-fake-2\""; }
    if([mode isEqual:@"slow"]) usleep(1500000);
    if([mode isEqual:@"flaky403"] && n % 3 == 0) {
        const char *forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        BTRSendAll(fd,forbidden,strlen(forbidden)); return;
    }
    uint64_t start = 0, end = total - 1; BOOL ranged = NO;
    NSString *range = BTRHeader(head,@"Range");
    if(range.length) {
        NSArray *bounds = [[range stringByReplacingOccurrencesOfString:@"bytes=" withString:@""] componentsSeparatedByString:@"-"];
        if(bounds.count != 2) return;
        ranged = YES;
        if(![bounds[0] length]) start = total - MIN(total,(uint64_t)[bounds[1] longLongValue]);
        else {
            start = (uint64_t)[bounds[0] longLongValue];
            if([bounds[1] length]) end = MIN(end,(uint64_t)[bounds[1] longLongValue]);
        }
        if(start >= total || end < start) {
            NSString *reply = [NSString stringWithFormat:@"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%llu\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",total];
            BTRSendAll(fd,reply.UTF8String,strlen(reply.UTF8String)); return;
        }
    }
    uint64_t length = end - start + 1;
    NSMutableString *reply = [NSMutableString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: %llu\r\nAccept-Ranges: bytes\r\nConnection: close\r\n",
        ranged ? @"206 Partial Content" : @"200 OK",length];
    // overshoot: a Content-Range that does not match the requested piece.
    if(ranged) [reply appendFormat:@"Content-Range: bytes %llu-%llu/%llu\r\n",start,[mode isEqual:@"overshoot"] ? end + 1 : end,total];
    if(etag) [reply appendFormat:@"ETag: %@\r\n",etag];
    [reply appendString:@"\r\n"];
    if(!BTRSendAll(fd,reply.UTF8String,strlen(reply.UTF8String)) || [method isEqual:@"HEAD"]) return;
    uint8_t chunk[16384]; uint64_t sent = 0; double began = BTRNow();
    for(uint64_t offset = start; offset <= end;) {
        size_t size = (size_t)MIN((uint64_t)sizeof(chunk),end - offset + 1);
        for(size_t i = 0; i < size; i++) chunk[i] = BTRFakeByte(offset + i,variant);
        if(!BTRSendAll(fd,chunk,size)) return;
        offset += size; sent += size;
        if([mode isEqual:@"reset"] && n % 4 == 0 && sent >= 65536) return;
        if([mode isEqual:@"stall"] && n == 2 && sent >= 131072) { sleep(40); return; }
        if([mode isEqual:@"deadhost"]) { sleep(30); return; }
        if([mode isEqual:@"lag"] && n % 3 == 0 && sent == 65536) sleep(8);
        if([mode isEqual:@"throttle"]) {
            double ahead = (double)sent / BTRMiB - (BTRNow() - began); // 1 MiB/s per connection
            if(ahead > 0) usleep((useconds_t)(ahead * 1000000));
        }
    }
}
@end

#pragma mark - Player-like client

typedef NS_ENUM(int, BTRVerify) { BTRVerifyNone, BTRVerifyFake, BTRVerifySHA };

@interface BTRClientResult : NSObject
@property(nonatomic) NSInteger status;
@property(nonatomic) double ttfbMs, totalMs;
@property(nonatomic) uint64_t bytes, contentLength, rangeStart, rangeTotal;
@property(nonatomic) int64_t mismatchAt;
@property(nonatomic) BOOL hasLocation, complete;
@property(nonatomic,copy) NSString *error;
@property(nonatomic,strong) NSData *sha;
@end
@implementation BTRClientResult
- (NSDictionary *)summary {
    return @{@"status":@(self.status),@"ttfbMs":@(self.ttfbMs),@"ms":@(self.totalMs),@"bytes":@(self.bytes),
             @"complete":@(self.complete),@"mismatchAt":@(self.mismatchAt),@"redirect":@(self.hasLocation),
             @"error":self.error ?: @"none"};
}
@end

// Raw socket like IJK: one GET/HEAD, optional pause, optional early close at readLimit.
static BTRClientResult *BTRClient(uint16_t port, NSString *path, NSString *method, NSString *range, uint64_t readLimit,
                                  uint64_t pauseAfter, unsigned pauseSeconds, BTRVerify verify, int variant) {
    BTRClientResult *result = [BTRClientResult new]; result.mismatchAt = -1;
    double began = BTRNow();
    int fd = socket(AF_INET,SOCK_STREAM,0);
    if(fd < 0) { result.error = @"socket"; return result; }
    BTRSocketDefaults(fd,45);
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address);
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
    if(connect(fd,(struct sockaddr *)&address,sizeof(address))) { close(fd); result.error = @"connect"; return result; }
    NSString *request = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%u\r\n%@User-Agent: BTRSelfTest\r\n\r\n",
        method,path,port,range ? [NSString stringWithFormat:@"Range: %@\r\n",range] : @""];
    if(!BTRSendAll(fd,request.UTF8String,strlen(request.UTF8String))) { close(fd); result.error = @"send"; return result; }
    NSMutableData *pending = [NSMutableData data];
    NSString *head = BTRReadHead(fd,pending);
    result.ttfbMs = BTRMs(began);
    if(!head) { close(fd); result.error = @"no_headers"; result.totalMs = BTRMs(began); return result; }
    NSArray *status = [[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    result.status = status.count > 1 ? [status[1] integerValue] : 0;
    result.hasLocation = BTRHeader(head,@"Location") != nil;
    result.contentLength = (uint64_t)[BTRHeader(head,@"Content-Length") longLongValue];
    NSString *contentRange = BTRHeader(head,@"Content-Range");
    if([contentRange hasPrefix:@"bytes "] && ![contentRange hasPrefix:@"bytes */"]) {
        NSScanner *scanner = [NSScanner scannerWithString:[contentRange substringFromIndex:6]];
        unsigned long long value = 0;
        if([scanner scanUnsignedLongLong:&value]) result.rangeStart = value;
        NSRange slash = [contentRange rangeOfString:@"/"];
        if(slash.location != NSNotFound) result.rangeTotal = (uint64_t)[[contentRange substringFromIndex:slash.location + 1] longLongValue];
    }
    uint64_t want = [method isEqual:@"HEAD"] || result.status < 200 || result.status >= 300 ? 0 : MIN(result.contentLength,readLimit);
    CC_SHA256_CTX sha; CC_SHA256_Init(&sha);
    BOOL paused = NO; uint8_t buffer[65536];
    NSData *chunk = pending;
    while(result.bytes < want) {
        if(!chunk) {
            ssize_t size = recv(fd,buffer,(size_t)MIN((uint64_t)sizeof(buffer),want - result.bytes),0);
            if(size < 0 && errno == EINTR) continue;
            if(size <= 0) { result.error = size < 0 ? @"recv_timeout" : @"closed_early"; break; }
            chunk = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)size freeWhenDone:NO];
        }
        NSUInteger usable = (NSUInteger)MIN((uint64_t)chunk.length,want - result.bytes);
        const uint8_t *bytes = chunk.bytes;
        if(verify == BTRVerifySHA) CC_SHA256_Update(&sha,bytes,(CC_LONG)usable);
        else if(verify == BTRVerifyFake && result.mismatchAt < 0)
            for(NSUInteger i = 0; i < usable; i++)
                if(bytes[i] != BTRFakeByte(result.rangeStart + result.bytes + i,variant)) { result.mismatchAt = (int64_t)(result.bytes + i); break; }
        result.bytes += usable; chunk = nil;
        if(pauseSeconds && !paused && result.bytes >= pauseAfter) { paused = YES; sleep(pauseSeconds); }
    }
    result.complete = result.bytes == want;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&sha);
    result.sha = [NSData dataWithBytes:digest length:sizeof(digest)];
    close(fd); result.totalMs = BTRMs(began);
    return result;
}

#pragma mark - Direct CDN baseline

@interface BTRDirectFetch : NSObject <NSURLSessionDataDelegate>
@property(nonatomic,strong) dispatch_semaphore_t done;
@property(nonatomic) double began, ttfbMs;
@property(nonatomic) uint64_t bytes, total;
@property(nonatomic) NSInteger status;
@property(nonatomic,strong) NSError *error;
@property(nonatomic,strong) NSData *sha;
@property(nonatomic,copy) NSDictionary *wire; // protocol / proxy / reused / IP family of the last transaction
@property(nonatomic) NSTimeInterval timeout;
@end
@implementation BTRDirectFetch { CC_SHA256_CTX _digest; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    NSURLSessionTaskTransactionMetrics *last = metrics.transactionMetrics.lastObject;
    if(!last) return;
    NSString *remote = last.remoteAddress ?: @"";
    self.wire = @{@"protocol":last.networkProtocolName ?: @"unknown",@"proxy":@(last.isProxyConnection),
                  @"reused":@(last.isReusedConnection),@"family":remote.length ? ([remote containsString:@":"] ? @"ipv6" : @"ipv4") : @"unknown"};
}
- (NSDictionary *)run:(NSString *)raw headers:(NSDictionary *)headers start:(uint64_t)start end:(uint64_t)end {
    self.done = dispatch_semaphore_create(0); CC_SHA256_Init(&_digest);
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.timeoutIntervalForRequest = self.timeout > 0 ? self.timeout : 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:raw]];
    for(NSString *name in @[@"User-Agent",@"Referer",@"Origin"]) if(headers[name]) [request setValue:headers[name] forHTTPHeaderField:name];
    [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu",start,end] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    self.began = BTRNow();
    [[session dataTaskWithRequest:request] resume];
    BOOL finished = !dispatch_semaphore_wait(self.done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.timeout > 0 ? self.timeout * 2 : 60) * NSEC_PER_SEC));
    [session invalidateAndCancel];
    return @{@"status":@(self.status),@"ttfbMs":@(self.ttfbMs),@"ms":@(BTRMs(self.began)),@"bytes":@(self.bytes),
             @"finished":@(finished && !self.error),@"errorCode":@(self.error.code)};
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    self.ttfbMs = BTRMs(self.began);
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    self.status = http.statusCode;
    NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
    NSRange slash = [contentRange rangeOfString:@"/"];
    if(slash.location != NSNotFound) self.total = (uint64_t)[[contentRange substringFromIndex:slash.location + 1] longLongValue];
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) { CC_SHA256_Update(&self->_digest,bytes,(CC_LONG)range.length); }];
    self.bytes += data.length;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler { handler(nil); }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.error = error;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&_digest);
    self.sha = [NSData dataWithBytes:digest length:sizeof(digest)];
    dispatch_semaphore_signal(self.done);
}
@end

#pragma mark - Runner

static NSString *BTRMapAlt(BTRLoopbackRangeAdapter *adapter, NSString *raw, NSDictionary *headers, NSArray *alternates,
                           uint64_t generation, uint16_t *port) {
    NSError *error = nil;
    NSString *local = [adapter mapVideoURL:raw generation:generation headers:headers alternates:alternates error:&error];
    NSURL *url = local ? [NSURL URLWithString:local] : nil;
    if(!url) return nil;
    *port = (uint16_t)url.port.unsignedIntValue;
    return url.path;
}
static NSString *BTRMap(BTRLoopbackRangeAdapter *adapter, NSString *raw, NSDictionary *headers, uint64_t generation, uint16_t *port) {
    NSError *error = nil;
    NSString *local = [adapter mapVideoURL:raw generation:generation headers:headers error:&error];
    NSURL *url = local ? [NSURL URLWithString:local] : nil;
    if(!url) return nil;
    *port = (uint16_t)url.port.unsignedIntValue;
    return url.path;
}
static NSDictionary *BTRDelta(NSDictionary *before, NSDictionary *after) {
    // Counters as per-scenario increments; max*/activeConnections as current values.
    NSArray *state = @[@"generation",@"enabled",@"mapped",@"bypassed",@"currentMappings",@"bypassedMappings",
        @"maximumUpstreamConcurrency",@"sourceMetadataGeneration",@"rangeDeliveryVerified",@"downloadReplacementVerified",
        @"sourceMetadataCaptured",@"hasUserAgent",@"hasReferer",@"hasOrigin"];
    NSMutableDictionary *delta = [NSMutableDictionary dictionary];
    for(NSString *key in after) {
        if(![after[key] isKindOfClass:NSNumber.class] || [state containsObject:key]) continue;
        if([key hasPrefix:@"max"] || [key isEqual:@"activeConnections"]) { delta[key] = after[key]; continue; }
        long long change = [after[key] longLongValue] - [before[key] longLongValue];
        if(change) delta[key] = @(change);
    }
    return delta;
}

void BTRSelfTestRun(NSDictionary *realSource, void (^completion)(NSDictionary *result)) {
    dispatch_async(dispatch_queue_create("local.btr.selftest",DISPATCH_QUEUE_SERIAL), ^{ @autoreleasepool {
        double started = BTRNow();
        NSMutableArray *results = [NSMutableArray array];
        void (^record)(NSString *, NSString *, BOOL, NSDictionary *) = ^(NSString *identifier, NSString *name, BOOL pass, NSDictionary *detail) {
            [results addObject:@{@"id":identifier,@"name":name,@"pass":@(pass),@"detail":detail ?: @{}}];
        };
        BTRFakeOrigin *origin = [BTRFakeOrigin new];
        NSError *error = nil;
        BTRLoopbackRangeAdapter *adapter = [[BTRLoopbackRangeAdapter alloc] initWithError:&error];
        if(![origin start] || !adapter) {
            record(@"F0",@"测试环境",NO,@{@"origin":@(origin.port),@"adapter":@(adapter != nil)});
        } else {
            adapter.testOriginPort = origin.port; adapter.enabled = YES;
            // The fault suite runs on the production path: the desktop engine (test hosts only).
            NSError *engineError = nil;
            BTREngine *testEngine = [[BTREngine alloc] initWithTestHosts:@[@"127.0.0.1",@"localhost"] error:&engineError];
            if(testEngine.usable) { adapter.engine = testEngine; [adapter useDesktopDefaults]; }
            record(@"F0",@"桌面下载引擎在本机加载",testEngine.usable,@{@"error":engineError.localizedDescription ?: @"none"});
            NSDictionary *ua = @{@"User-Agent":@"BTRSelfTest"};
            NSString *(^raw)(NSString *, uint64_t, NSString *) = ^NSString *(NSString *mode, uint64_t kib, NSString *query) {
                return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/%llu/media.m4s%@",origin.port,mode,kib,query ?: @""];
            };
            // Each scenario: fresh generation and mapping, adapter counter delta in detail.
            NSDictionary *(^scenario)(NSString *, uint64_t, BTRClientResult *(^)(uint16_t, NSString *)) =
                ^NSDictionary *(NSString *mode, uint64_t kib, BTRClientResult *(^body)(uint16_t, NSString *)) {
                NSDictionary *before = [adapter snapshot];
                uint16_t port = 0; NSString *path = BTRMap(adapter,raw(mode,kib,nil),ua,[adapter beginGeneration],&port);
                if(!path) return @{@"mapped":@NO};
                BTRClientResult *result = body(port,path);
                return @{@"client":[result summary],@"adapter":BTRDelta(before,[adapter snapshot]),@"ok":@(result.complete && result.mismatchAt < 0)};
            };
            const uint64_t size = 24 * 1024; // KiB

            NSDictionary *f1 = scenario(@"ok",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            BOOL f1ok = [f1[@"ok"] boolValue] && [f1[@"client"][@"bytes"] unsignedLongLongValue] == size * 1024;
            NSMutableDictionary *f1detail = [f1 mutableCopy];
            f1detail[@"mbps"] = @(round([f1[@"client"][@"bytes"] doubleValue] * 8 / MAX(1,[f1[@"client"][@"ms"] doubleValue]) / 10) / 100);
            record(@"F1",@"顺序完整读取 24MB",f1ok,f1detail);

            BTRClientResult *direct = BTRClient(origin.port,[NSString stringWithFormat:@"/throttle/%llu/media.m4s",size],@"GET",
                                                @"bytes=0-8388607",UINT64_MAX,0,0,BTRVerifyFake,0);
            NSDictionary *f2 = scenario(@"throttle",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-8388607",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            double speedup = [f2[@"client"][@"ms"] doubleValue] > 0 ? direct.totalMs / [f2[@"client"][@"ms"] doubleValue] : 0;
            NSMutableDictionary *f2detail = [f2 mutableCopy];
            f2detail[@"directMs"] = @(direct.totalMs); f2detail[@"speedup"] = @(round(speedup * 100) / 100);
            record(@"F2",@"单连接限速 1MB/s 时的并发加速",[f2[@"ok"] boolValue] && direct.complete && speedup >= 1.8,f2detail);

            NSDictionary *f3 = scenario(@"ok",size,^BTRClientResult *(uint16_t port, NSString *path) {
                BTRClientResult *worst = nil;
                for(int k = 0; k < 8; k++) {
                    uint64_t offset = (uint64_t)k * 2900000 + 12345;
                    BTRClientResult *one = BTRClient(port,path,@"GET",[NSString stringWithFormat:@"bytes=%llu-",offset],600 * 1024,0,0,BTRVerifyFake,0);
                    if(!worst || !one.complete || one.mismatchAt >= 0 || one.ttfbMs > worst.ttfbMs) worst = one;
                    if(!one.complete || one.mismatchAt >= 0) break;
                }
                return worst;
            });
            record(@"F3",@"连续 8 次 seek（每次读 600KB 后断开）",[f3[@"ok"] boolValue] && [f3[@"client"][@"ttfbMs"] doubleValue] < 3000,f3);

            NSDictionary *f4 = scenario(@"ok",size,^BTRClientResult *(uint16_t port, NSString *path) {
                dispatch_group_t group = dispatch_group_create();
                NSMutableArray *all = [NSMutableArray array];
                for(int k = 0; k < 4; k++) dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                    BTRClientResult *one = BTRClient(port,path,@"GET",[NSString stringWithFormat:@"bytes=%llu-",(uint64_t)k * 6 * BTRMiB],
                                                     3 * BTRMiB,0,0,BTRVerifyFake,0);
                    @synchronized(all) { [all addObject:one]; }
                });
                dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
                BTRClientResult *worst = all.firstObject;
                for(BTRClientResult *one in all) if(!one.complete || one.mismatchAt >= 0 || one.totalMs > worst.totalMs) worst = one;
                for(BTRClientResult *one in all) if(!one.complete || one.mismatchAt >= 0) worst = one;
                return worst;
            });
            record(@"F4",@"4 个连接同时读取不同位置",[f4[@"ok"] boolValue],f4);

            NSDictionary *f5 = scenario(@"ok",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-",6 * BTRMiB,BTRMiB,20,BTRVerifyFake,0);
            });
            record(@"F5",@"读 1MB 后暂停 20 秒再继续",[f5[@"ok"] boolValue],f5);

            NSDictionary *f6 = scenario(@"ok",size,^BTRClientResult *(uint16_t port, NSString *path) {
                for(int k = 0; k < 15; k++)
                    BTRClient(port,path,@"GET",[NSString stringWithFormat:@"bytes=%llu-",(uint64_t)k * BTRMiB],50 * 1024,0,0,BTRVerifyNone,0);
                BTRClientResult *final = BTRClient(port,path,@"GET",@"bytes=0-4194303",UINT64_MAX,0,0,BTRVerifyFake,0);
                sleep(3);
                return final;
            });
            NSUInteger leftover = [[adapter snapshot][@"activeConnections"] unsignedIntegerValue];
            NSMutableDictionary *f6detail = [f6 mutableCopy]; f6detail[@"activeConnectionsAfter"] = @(leftover);
            record(@"F6",@"15 次快速打开/中断后再完整读取",[f6[@"ok"] boolValue] && leftover == 0,f6detail);

            {   // Small file: optimistic first window overshoots EOF, then suffix / tail / HEAD / 416.
                NSDictionary *before = [adapter snapshot];
                uint16_t port = 0; NSString *path = BTRMap(adapter,raw(@"ok",300,nil),ua,[adapter beginGeneration],&port);
                const uint64_t small = 300 * 1024;
                BTRClientResult *full = path ? BTRClient(port,path,@"GET",@"bytes=0-",UINT64_MAX,0,0,BTRVerifyFake,0) : nil;
                BTRClientResult *tail = path ? BTRClient(port,path,@"GET",[NSString stringWithFormat:@"bytes=%llu-",small - 200],UINT64_MAX,0,0,BTRVerifyFake,0) : nil;
                BTRClientResult *suffix = path ? BTRClient(port,path,@"GET",@"bytes=-1000",UINT64_MAX,0,0,BTRVerifyFake,0) : nil;
                BTRClientResult *head = path ? BTRClient(port,path,@"HEAD",nil,UINT64_MAX,0,0,BTRVerifyNone,0) : nil;
                BTRClientResult *beyond = path ? BTRClient(port,path,@"GET",@"bytes=400000-",UINT64_MAX,0,0,BTRVerifyNone,0) : nil;
                BOOL pass = full.complete && full.mismatchAt < 0 && full.bytes == small
                    && tail.complete && tail.bytes == 200 && tail.mismatchAt < 0
                    && suffix.complete && suffix.bytes == 1000 && suffix.mismatchAt < 0 && suffix.rangeStart == small - 1000
                    && head.status == 200 && head.contentLength == small && beyond.status == 416;
                record(@"F7",@"小文件：首窗越界/文件尾/后缀/HEAD/416",pass,@{@"full":[full summary] ?: @{},@"tail":[tail summary] ?: @{},
                    @"suffix":[suffix summary] ?: @{},@"headStatus":@(head.status),@"beyondStatus":@(beyond.status),
                    @"adapter":BTRDelta(before,[adapter snapshot])});
            }

            NSDictionary *f8 = scenario(@"reset",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-8388607",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            record(@"F8",@"上游每 4 个请求断开一次",[f8[@"ok"] boolValue],f8);

            NSDictionary *f9 = scenario(@"flaky403",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-6291455",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            record(@"F9",@"上游每 3 个请求返回 403",[f9[@"ok"] boolValue],f9);

            NSMutableDictionary *tags = [NSMutableDictionary dictionary]; BOOL tagsOK = YES;
            for(NSString *mode in @[@"weak",@"noetag",@"badtag"]) {
                NSDictionary *one = scenario(mode,size,^BTRClientResult *(uint16_t port, NSString *path) {
                    return BTRClient(port,path,@"GET",@"bytes=0-",3 * BTRMiB,0,0,BTRVerifyFake,0);
                });
                tags[mode] = one; tagsOK = tagsOK && [one[@"ok"] boolValue];
            }
            record(@"F10",@"弱/缺失/不规范 ETag",tagsOK,tags);

            NSDictionary *f11 = scenario(@"overshoot",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            record(@"F11",@"上游 Content-Range 错误时回退原地址",[f11[@"client"][@"status"] integerValue] == 302
                && [f11[@"client"][@"redirect"] boolValue],f11);

            NSDictionary *f12 = scenario(@"mutate",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-",12 * BTRMiB,0,0,BTRVerifyFake,0);
            });
            record(@"F12",@"源文件中途变化时不输出错误数据",[f12[@"client"][@"mismatchAt"] longLongValue] < 0,f12);

            NSDictionary *f13 = scenario(@"stall",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-6291455",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            record(@"F13",@"上游分片卡死 40 秒",[f13[@"ok"] boolValue],f13);

            {   // Re-signed URLs: mapping cap/eviction must keep the newest URLs usable.
                NSDictionary *before = [adapter snapshot];
                uint64_t generation = [adapter beginGeneration]; uint16_t port = 0; NSString *path = nil; NSUInteger mapped = 0;
                for(int k = 0; k < 40; k++) {
                    NSString *one = BTRMap(adapter,raw(@"ok",size,[NSString stringWithFormat:@"?sig=%d",k]),ua,generation,&port);
                    if(one) { path = one; mapped++; }
                }
                BTRClientResult *last = path ? BTRClient(port,path,@"GET",@"bytes=0-",2 * BTRMiB,0,0,BTRVerifyFake,0) : nil;
                NSDictionary *delta = BTRDelta(before,[adapter snapshot]);
                record(@"F14",@"40 个重签 URL（映射淘汰）",mapped == 40 && last.complete && last.mismatchAt < 0,
                       @{@"mapped":@(mapped),@"client":[last summary] ?: @{},@"adapter":delta});
            }

            NSDictionary *f15 = scenario(@"slow",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-",3 * BTRMiB,0,0,BTRVerifyFake,0);
            });
            record(@"F15",@"上游首字节慢 1.5 秒",[f15[@"ok"] boolValue] && [f15[@"client"][@"ttfbMs"] doubleValue] < 5000,f15);
            {   // Dead CDN host among two: stalled pieces move to the live host, then the dead one is demoted.
                NSDictionary *before = [adapter snapshot];
                uint16_t port = 0;
                NSString *alive = [raw(@"ok",size,nil) stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"];
                NSString *path = BTRMapAlt(adapter,raw(@"deadhost",size,nil),ua,@[alive],[adapter beginGeneration],&port);
                BTRClientResult *one = path ? BTRClient(port,path,@"GET",@"bytes=0-6291455",UINT64_MAX,0,0,BTRVerifyFake,0) : nil;
                record(@"F16",@"两个 CDN 中一个无响应：自动换线并降级",one.complete && one.mismatchAt < 0 && one.totalMs < 25000,
                       @{@"client":[one summary] ?: @{@"mapped":@NO},@"adapter":BTRDelta(before,[adapter snapshot])});
            }
            NSDictionary *f17 = scenario(@"lag",size,^BTRClientResult *(uint16_t port, NSString *path) {
                return BTRClient(port,path,@"GET",@"bytes=0-8388607",UINT64_MAX,0,0,BTRVerifyFake,0);
            });
            record(@"F17",@"单个分片中途停顿 8 秒（拖尾分片重发）",[f17[@"ok"] boolValue] && [f17[@"client"][@"ms"] doubleValue] < 20000,f17);
            [adapter close];
        }
        [origin stop];

        // Real CDN on the last accepted video source (memory only, never exported). Every
        // measurement reads its own range far from the start the player already warmed.
        NSString *source = [realSource[@"raw"] isKindOfClass:NSString.class] ? realSource[@"raw"] : nil;
        NSDictionary *headers = [realSource[@"headers"] isKindOfClass:NSDictionary.class] ? realSource[@"headers"] : nil;
        NSArray *alternates = [realSource[@"alternates"] isKindOfClass:NSArray.class] ? realSource[@"alternates"] : @[];
        BTRDirectFetch *probe = source && headers ? [BTRDirectFetch new] : nil;
        NSDictionary *probeResult = [probe run:source headers:headers start:0 end:0];
        uint64_t total = probe.total;
        uint64_t span = MIN(12 * BTRMiB,total / 24); // Distinct cold ranges, ~110 MB in total.
        if(!probe || span < BTRMiB) {
            record(@"R1",@"真实 CDN：冷区间直连 vs 桌面引擎",NO,@{@"skipped":probe ? @"total_unknown_or_small" : @"no_video_source",
                @"probeStatus":probeResult[@"status"] ?: @0,@"alternates":@(alternates.count)});
        } else {
            __block NSUInteger slot = 0;
            uint64_t (^nextRange)(void) = ^uint64_t { slot++; return total / 24 * (slot + 9); }; // From ~40% onwards.
            // config: engine YES {threads, windowMiB, mode?} or NO {pieces, windowMiB} (legacy downloader).
            NSDictionary *(^measure)(NSDictionary *, uint64_t) = ^NSDictionary *(NSDictionary *config, uint64_t length) {
                NSError *failure = nil;
                BTRLoopbackRangeAdapter *real = [[BTRLoopbackRangeAdapter alloc] initWithError:&failure];
                uint64_t window = [config[@"windowMiB"] unsignedLongLongValue] * BTRMiB;
                BOOL useEngine = [config[@"engine"] boolValue];
                if(useEngine) {
                    BTREngine *engine = [[BTREngine alloc] initWithTestHosts:nil error:&failure];
                    if(engine.usable) {
                        real.engine = engine; [real useDesktopDefaults]; real.windowBytes = window;
                        NSMutableDictionary *options = [@{@"concurrency":config[@"threads"] ?: @32} mutableCopy];
                        if(config[@"mode"]) options[@"mode"] = config[@"mode"];
                        if(config[@"scheme"]) options[@"scheme"] = config[@"scheme"];
                        if(config[@"minChunkKiB"]) options[@"minChunkKiB"] = config[@"minChunkKiB"];
                        if(config[@"akamai"]) options[@"akamai"] = config[@"akamai"];
                        [engine configure:options];
                    }
                } else { real.pieceConcurrency = [config[@"pieces"] unsignedIntegerValue]; real.windowBytes = window; }
                real.enabled = YES;
                uint16_t port = 0; uint64_t offset = nextRange();
                NSString *path = BTRMapAlt(real,source,headers,alternates,[real beginGeneration],&port);
                BTRClientResult *loop = path ? BTRClient(port,path,@"GET",[NSString stringWithFormat:@"bytes=%llu-%llu",offset,offset + length - 1],
                                                         UINT64_MAX,0,0,BTRVerifySHA,0) : nil;
                NSDictionary *stats = [real snapshot];
                [real close];
                NSMutableDictionary *summary = [NSMutableDictionary dictionary];
                for(NSString *key in stats)
                    if([key hasPrefix:@"piece"] || [key hasPrefix:@"maxPiece"] || [key hasPrefix:@"engineError_"] || [key hasPrefix:@"failure_"]
                       || [@[@"windowRetries",@"maxWindowMs",@"maxFirstByteMs",@"maxHostsPerWindow",@"slowWaits",@"transportEngine"] containsObject:key])
                        summary[key] = stats[key];
                return @{@"config":config,@"offset":@(offset),@"engineLoaded":@(!useEngine || real.engine != nil),
                         @"client":[loop summary] ?: @{@"mapped":@NO},@"ok":@(loop.complete && loop.mismatchAt < 0),
                         @"mbps":@(loop.totalMs > 0 ? round(loop.bytes * 8 / loop.totalMs / 10) / 100 : 0),
                         @"adapter":summary,@"engine":stats[@"engine"] ?: @{},@"sha":loop.sha ?: [NSData data]};
            };
            NSDictionary *standard = @{@"engine":@YES,@"threads":@64,@"windowMiB":@16}; // defaults: mainland, http, 512 KiB pieces
            // R1: cold direct single connection vs the desktop engine on another cold range, plus byte check.
            uint64_t directOffset = nextRange();
            BTRDirectFetch *directFetch = [BTRDirectFetch new];
            NSDictionary *direct = [directFetch run:source headers:headers start:directOffset end:directOffset + span - 1];
            double directMbps = [direct[@"ms"] doubleValue] > 0 ? round(directFetch.bytes * 8 / [direct[@"ms"] doubleValue] / 10) / 100 : 0;
            NSDictionary *loop = measure(standard,span);
            BTRDirectFetch *check = [BTRDirectFetch new];
            uint64_t loopOffset = [loop[@"offset"] unsignedLongLongValue];
            NSDictionary *checked = [check run:source headers:headers start:loopOffset end:loopOffset + span - 1];
            // The direct re-read is only a reference when it completed; a cut-off one proves nothing.
            BOOL verifiable = [checked[@"finished"] boolValue] && check.bytes == span;
            BOOL same = [loop[@"ok"] boolValue] && (!verifiable || [loop[@"sha"] isEqual:check.sha]);
            NSMutableDictionary *r1 = [loop mutableCopy]; [r1 removeObjectForKey:@"sha"];
            r1[@"direct"] = direct; r1[@"directMbps"] = @(directMbps); r1[@"identicalBytes"] = verifiable ? @(same) : @"unverifiable";
            r1[@"speedup"] = @(directMbps > 0 ? round([loop[@"mbps"] doubleValue] / directMbps * 100) / 100 : 0);
            r1[@"spanMiB"] = @(span / BTRMiB); r1[@"alternates"] = @(alternates.count);
            record(@"R1",@"真实 CDN：冷区间直连 vs 桌面引擎（国内镜像＋akamai，64 线程）",same && [r1[@"speedup"] doubleValue] >= 1,r1);

            // R2: seeks — engine first on cold ranges, then direct re-read for the byte check.
            NSMutableArray *seeks = [NSMutableArray array]; BOOL all = YES;
            for(int k = 0; k < 3; k++) {
                NSDictionary *one = measure(@{@"engine":@YES,@"threads":@64,@"windowMiB":@2},2 * BTRMiB);
                uint64_t offset = [one[@"offset"] unsignedLongLongValue];
                BTRDirectFetch *expected = [BTRDirectFetch new];
                NSDictionary *d = [expected run:source headers:headers start:offset end:offset + 2 * BTRMiB - 1];
                BOOL verifiable = [d[@"finished"] boolValue] && expected.bytes == 2 * BTRMiB;
                BOOL match = [one[@"ok"] boolValue] && (!verifiable || [one[@"sha"] isEqual:expected.sha]);
                all = all && match;
                [seeks addObject:@{@"match":verifiable ? @(match) : @"unverifiable",@"loopOk":one[@"ok"],@"loop":one[@"client"],@"direct":d}];
            }
            record(@"R2",@"真实 CDN：3 次冷区间 seek 数据一致",all,@{@"seeks":seeks});

            // R3: strategy matrix on separate cold ranges; picks the fastest configuration.
            NSMutableArray *matrix = [NSMutableArray array];
            // Thread counts must be 4/8/16/32/64/128 (the desktop normalizer turns others into 8).
            NSArray *configs = @[@{@"engine":@YES,@"threads":@64,@"windowMiB":@16,@"mode":@"mainland"},  // v15 / release 1 (no akamai)
                                 @{@"engine":@YES,@"threads":@64,@"windowMiB":@16,@"minChunkKiB":@1024},
                                 @{@"engine":@YES,@"threads":@32,@"windowMiB":@8,@"minChunkKiB":@64},
                                 @{@"engine":@YES,@"threads":@128,@"windowMiB":@32},
                                 @{@"engine":@YES,@"threads":@64,@"windowMiB":@16,@"akamai":@NO}];
            for(NSDictionary *config in configs) {
                NSMutableDictionary *one = [measure(config,span) mutableCopy];
                [one removeObjectForKey:@"sha"]; [matrix addObject:one];
            }
            NSDictionary *best = nil;
            for(NSDictionary *one in matrix) if([one[@"ok"] boolValue] && (!best || [one[@"mbps"] doubleValue] > [best[@"mbps"] doubleValue])) best = one;
            record(@"R3",@"真实 CDN：线程数/窗口/节点模式矩阵",best && [best[@"mbps"] doubleValue] > directMbps,
                   @{@"directMbps":@(directMbps),@"alternates":@(alternates.count),@"matrix":matrix,
                     @"best":best ? @{@"config":best[@"config"],@"mbps":best[@"mbps"]} : @{}});

            // R4-R6: why the overseas nodes are slow here while the web page plays HDR fine on the
            // same Wi-Fi. Every probe reads its own cold 1 MiB (6-35% of the file), no URL stored.
            __block NSUInteger probeSlot = 0;
            uint64_t (^probeOffset)(void) = ^uint64_t { probeSlot++; return total / 1000 * (60 + probeSlot * 9); };
            NSString *(^onHost)(NSString *, NSString *) = ^NSString *(NSString *url, NSString *host) {
                NSURLComponents *parts = [NSURLComponents componentsWithString:url];
                if(host) parts.host = host;
                parts.scheme = @"http"; parts.port = nil;
                return parts.URL.absoluteString;
            };
            NSString *browserUA = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
            NSDictionary *(^probeOne)(NSString *, NSDictionary *, uint64_t) = ^NSDictionary *(NSString *url, NSDictionary *probeHeaders, uint64_t offset) {
                BTRDirectFetch *one = [BTRDirectFetch new]; one.timeout = 10;
                NSDictionary *r = [one run:url headers:probeHeaders start:offset end:offset + BTRMiB - 1];
                double ms = [r[@"ms"] doubleValue];
                return @{@"host":[NSURL URLWithString:url].host ?: @"?",@"status":r[@"status"],@"ttfbMs":r[@"ttfbMs"],@"bytes":r[@"bytes"],
                         @"errorCode":r[@"errorCode"],@"mbps":@(ms > 0 ? round(one.bytes * 8 / ms / 10) / 100 : 0),@"wire":one.wire ?: @{}};
            };
            NSMutableArray *originals = [NSMutableArray arrayWithObject:source];
            for(NSString *other in alternates) if([other isKindOfClass:NSString.class]) [originals addObject:other];
            NSArray *mirrors = @[@"upos-sz-mirrorali.bilivideo.com",@"upos-sz-mirrorhw.bilivideo.com",@"upos-sz-mirrorbos.bilivideo.com",
                @"upos-sz-mirror08c.bilivideo.com",@"upos-sz-mirrorbd.bilivideo.com",@"upos-sz-mirror14b.bilivideo.com",
                @"upos-sz-estgoss.bilivideo.com",@"upos-sz-mirrorcos.bilivideo.com",@"upos-sz-mirrorcosov.bilivideo.com",
                @"upos-sz-mirroraliov.bilivideo.com",@"cn-hk-eq-01-01.bilivideo.com",@"cn-hk-eq-01-03.bilivideo.com"];
            NSMutableArray *hostProbes = [NSMutableArray array];
            for(NSString *url in originals) [hostProbes addObject:probeOne(onHost(url,nil),headers,probeOffset())];
            NSString *donor = source;
            for(NSString *host in mirrors) [hostProbes addObject:probeOne(onHost(donor,host),headers,probeOffset())];
            record(@"R4",@"真实 CDN：逐个主机单连接测速（App UA）",YES,@{@"probes":hostProbes});

            // R5: request headers — the app UA vs a desktop browser UA with the web Referer.
            NSMutableArray *uaProbes = [NSMutableArray array];
            NSDictionary *browser = @{@"User-Agent":browserUA,@"Referer":@"https://www.bilibili.com/"};
            for(NSString *url in originals) {
                [uaProbes addObject:@{@"ua":@"app",@"probe":probeOne(onHost(url,nil),headers,probeOffset())}];
                [uaProbes addObject:@{@"ua":@"browser",@"probe":probeOne(onHost(url,nil),browser,probeOffset())}];
            }
            [uaProbes addObject:@{@"ua":@"app_https",@"probe":probeOne([onHost(source,nil) stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"],headers,probeOffset())}];
            record(@"R5",@"真实 CDN：App UA 与浏览器 UA/https 对比",YES,@{@"probes":uaProbes});

            // R6: four simultaneous connections to each of the player's own hosts (akamai bans?).
            NSMutableArray *parallelProbes = [NSMutableArray array];
            for(NSString *url in originals) {
                NSMutableArray *four = [NSMutableArray array];
                dispatch_group_t group = dispatch_group_create();
                for(int k = 0; k < 4; k++) {
                    uint64_t offset = probeOffset();
                    dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                        NSDictionary *one = probeOne(onHost(url,nil),headers,offset);
                        @synchronized(four) { [four addObject:one]; }
                    });
                }
                dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
                [parallelProbes addObject:@{@"host":[NSURL URLWithString:url].host ?: @"?",@"connections":four}];
            }
            record(@"R6",@"真实 CDN：播放器原始主机 4 连接并发",YES,@{@"hosts":parallelProbes});
        }        NSUInteger passed = 0; NSMutableArray *failed = [NSMutableArray array];
        for(NSDictionary *one in results) {
            if([one[@"pass"] boolValue]) passed++;
            else [failed addObject:[NSString stringWithFormat:@"%@ %@",one[@"id"],one[@"name"]]];
        }
        NSDictionary *result = @{@"schema":@"btr.selftest.v1",@"passed":@(passed),@"total":@(results.count),
            @"seconds":@(round((BTRNow() - started) * 10) / 10),@"failed":failed,@"scenarios":results};
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    }});
}
