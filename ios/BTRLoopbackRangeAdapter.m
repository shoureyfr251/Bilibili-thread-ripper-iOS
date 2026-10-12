#import "BTRLoopbackRangeAdapter.h"
#import "BTRRangeDownloader.h"
#import "BTRJSEngine.h"
#import "BTRScripts.generated.h"
#import <JavaScriptCore/JavaScriptCore.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>

// Small first window for time-to-first-byte; later windows pipelined, 4 pieces each.
static const uint64_t BTRFirstWindow = 512 * 1024;
static const uint64_t BTRWindow = 2 * 1024 * 1024;
static const NSUInteger BTRPieces = 4;
static const NSUInteger BTRMaxConnections = 12;
static const NSUInteger BTRMaxMappings = 32;
// A paused player legitimately stops reading; close only after this long without progress.
static const NSTimeInterval BTRWriteStall = 60;
static NSError *LBError(NSInteger code) {
    return [NSError errorWithDomain:@"BTRLoopback" code:code userInfo:nil];
}

@interface BTRLBMapping : NSObject
@property(nonatomic) uint64_t generation;
@property(nonatomic,copy) NSString *raw;
@property(nonatomic,copy) NSString *path;
@property(nonatomic,copy) NSDictionary *headers;
@property(nonatomic,strong) NSNumber *total;
@property(nonatomic,copy) NSString *etag;
@property(nonatomic) BOOL bypassed;
@property(nonatomic,copy) NSArray<NSString *> *alternates; // Same file on other CDN hosts.
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *sourceOK, *sourceFailed; // Adapter lock.
@property(nonatomic) NSUInteger connections; // Live loopback connections (adapter lock).
@property(nonatomic) NSTimeInterval lastUsed;
@property(nonatomic) NSUInteger slowWaits; // Player starved > BTRSlowWait (adapter lock).
@end
// Never worse than direct: after two windows the player waited this long for, the file goes
// back to the player's own download for the rest of this item.
static const NSTimeInterval BTRSlowWait = 6;
@implementation BTRLBMapping
@end

@interface BTRLBFetch : NSObject
@property(nonatomic,strong) dispatch_semaphore_t done;
@property(nonatomic,strong) BTRRangeDownloader *downloader;
@property(nonatomic) uint64_t start, end;
@property(nonatomic) NSTimeInterval began;
@property(nonatomic) uint64_t engineJob;
@property(nonatomic,strong) BTREngine *engine;
@property(atomic,strong) NSData *data;
@property(atomic,strong) NSNumber *total;
@property(atomic,copy) NSString *tag;
@property(atomic,strong) NSError *error;
@end
@implementation BTRLBFetch
@end

@interface BTRLBConnection : NSObject
@property(nonatomic) int fd;
@property(nonatomic) BOOL cancelled;
@property(nonatomic,strong) BTRRangeDownloader *downloader, *spareDownloader;
@property(nonatomic,weak) BTRLBMapping *mapping;
@property(nonatomic,copy) NSString *failureReason;
@property(nonatomic) NSInteger failureCode, httpStatus;
- (void)cancel;
- (void)closeSocket;
@end
@implementation BTRLBConnection
- (void)cancel {
    @synchronized(self) { self.cancelled = YES; if(self.fd >= 0) shutdown(self.fd,SHUT_RDWR); }
    [self.downloader cancel]; [self.spareDownloader cancel];
}
- (void)closeSocket {
    @synchronized(self) { if(self.fd >= 0) { close(self.fd); self.fd = -1; } }
    [self.downloader close]; [self.spareDownloader close];
}
@end

@interface BTRLoopbackRangeAdapter () {
    BOOL _enabled, _closed;
    uint64_t _generation;
    int _listener;
    uint16_t _port;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _policyQueue, _completionQueue;
    JSContext *_httpContext;
    // Current generation only: one token per exact signed source URL (CDN switch/reopen).
    NSMutableDictionary<NSString *,BTRLBMapping *> *_mappingsByPath, *_mappingsByRaw;
    NSMutableSet *_connections;
    NSMutableDictionary *_stats;
}
@end

@implementation BTRLoopbackRangeAdapter
- (instancetype)initWithError:(NSError **)error {
    if(!(self = [super init])) return nil;
    _listener = -1; _connections = [NSMutableSet set]; _stats = [NSMutableDictionary dictionary];
    _mappingsByPath = [NSMutableDictionary dictionary]; _mappingsByRaw = [NSMutableDictionary dictionary];
    _pieceConcurrency = BTRPieces; _windowBytes = BTRWindow; _firstWindowBytes = BTRFirstWindow; _prefetchDepth = 1;
    _policyQueue = dispatch_queue_create("local.btr.http-policy",DISPATCH_QUEUE_SERIAL);
    _completionQueue = dispatch_queue_create("local.btr.http-completion",DISPATCH_QUEUE_SERIAL);
    __block BOOL valid;
    dispatch_sync(_policyQueue, ^{
        self->_httpContext = [[JSContext alloc] init];
        [self->_httpContext evaluateScript:[NSString stringWithUTF8String:BTRHTTPScript]];
        valid = self->_httpContext.exception == nil;
    });
    if(!valid) { if(error) *error = LBError(1); return nil; }
    return self;
}
- (void)useDesktopDefaults {
    // ios/dev/engine-test.mjs latency-bound model (600 ms first byte, 256 KB/s per connection):
    // 16 MiB windows, 3 ahead, 64 threads, 512 KiB pieces ~2x the v13 setting.
    self.firstWindowBytes = 1024 * 1024; self.windowBytes = 16 * 1024 * 1024; self.prefetchDepth = 3; // ~48 MiB ahead, keeps 64 threads busy
}
- (BOOL)enabled { @synchronized(self) { return _enabled && !_closed; } }
- (void)setEnabled:(BOOL)value {
    @synchronized(self) { _enabled = value && !_closed; if(!value) [self beginGeneration]; }
}
- (uint64_t)beginGeneration {
    NSArray *old; uint64_t generation;
    @synchronized(self) {
        generation = ++_generation; [_mappingsByPath removeAllObjects]; [_mappingsByRaw removeAllObjects];
        _stats[@"sourceMetadataCaptured"] = @NO; _stats[@"sourceMetadataGeneration"] = @(generation);
        _stats[@"hasUserAgent"] = @NO; _stats[@"hasReferer"] = @NO; _stats[@"hasOrigin"] = @NO;
        old = _connections.allObjects;
        if(old.count) _stats[@"cancellations"] = @([_stats[@"cancellations"] unsignedLongLongValue] + old.count);
    }
    for(BTRLBConnection *connection in old) [connection cancel];
    return generation;
}
- (void)invalidateGeneration:(uint64_t)generation {
    @synchronized(self) { if(generation == _generation) [self beginGeneration]; }
}
- (void)add:(NSString *)key amount:(uint64_t)amount generation:(uint64_t)generation {
    @synchronized(self) {
        if(generation != _generation) return;
        uint64_t old = [_stats[key] unsignedLongLongValue];
        _stats[key] = @(MIN(UINT64_MAX - amount,old) + amount);
    }
}
// Per-piece aggregates: where real-CDN time goes (TTFB vs transfer, stalls, hosts).
- (void)recordPiece:(NSDictionary *)piece mapping:(BTRLBMapping *)mapping {
    @synchronized(self) {
        NSString *url = piece[@"url"];
        if(mapping && [url isKindOfClass:NSString.class]) {
            if(!mapping.sourceOK) { mapping.sourceOK = [NSMutableDictionary dictionary]; mapping.sourceFailed = [NSMutableDictionary dictionary]; }
            NSMutableDictionary *table = [piece[@"ok"] boolValue] ? mapping.sourceOK : mapping.sourceFailed;
            table[url] = @([table[url] unsignedIntegerValue] + 1);
        }
        void (^bump)(NSString *, uint64_t) = ^(NSString *key, uint64_t amount) {
            self->_stats[key] = @([self->_stats[key] unsignedLongLongValue] + amount);
        };
        void (^peak)(NSString *, uint64_t) = ^(NSString *key, uint64_t value) {
            if(value > [self->_stats[key] unsignedLongLongValue]) self->_stats[key] = @(value);
        };
        BOOL ok = [piece[@"ok"] boolValue]; NSInteger code = [piece[@"code"] integerValue];
        uint64_t ms = (uint64_t)MAX(0,[piece[@"ms"] doubleValue]), ttfb = (uint64_t)MAX(0,[piece[@"ttfbMs"] doubleValue]);
        bump(ok ? @"pieces" : @"pieceFailures",1);
        bump([NSString stringWithFormat:@"source%@%@",piece[@"source"],ok ? @"Pieces" : @"Failures"],1);
        if(ok) { bump(@"pieceBytes",[piece[@"bytes"] unsignedLongLongValue]); bump(@"pieceMsSum",ms); bump(@"pieceTtfbMsSum",ttfb);
                 peak(@"maxPieceMs",ms); peak(@"maxPieceTtfbMs",ttfb); }
        else if(code == 11) bump(@"pieceStallRestarts",1);
        else bump([NSString stringWithFormat:@"pieceError_%ld",(long)(code < 0 ? -code : code)],1);
    }
}
- (void)recordFailure:(BTRLBConnection *)connection reason:(NSString *)reason generation:(uint64_t)generation {
    @synchronized(self) {
        if(generation != _generation) return;
        NSString *why = reason ?: connection.failureReason ?: @"upstream_failed";
        _stats[@"lastFailure"] = @{@"reason":why,@"code":@(connection.failureCode),
            @"httpStatus":@(connection.httpStatus ?: connection.downloader.lastHTTPStatus),
            @"etagKind":connection.downloader.lastETagKind ?: @"unknown"};
        // Fixed-name histogram so one late failure does not hide the dominant cause.
        NSString *key = [@"failure_" stringByAppendingString:why];
        _stats[key] = @([_stats[key] unsignedLongLongValue] + 1);
    }
}
- (BOOL)startListener {
    // Caller holds self lock. Only INADDR_LOOPBACK, never INADDR_ANY.
    if(_listener >= 0) return YES;
    int fd = socket(AF_INET,SOCK_STREAM,0); if(fd < 0) return NO;
    int yes = 1; if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes))) { close(fd); return NO; }
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address);
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if(bind(fd,(struct sockaddr *)&address,sizeof(address)) || listen(fd,4)) { close(fd); return NO; }
    socklen_t size = sizeof(address);
    if(getsockname(fd,(struct sockaddr *)&address,&size) || fcntl(fd,F_SETFL,O_NONBLOCK) < 0) { close(fd); return NO; }
    _listener = fd; _port = ntohs(address.sin_port);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_acceptSource, ^{ [weak acceptConnections]; });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); });
    dispatch_resume(_acceptSource); return YES;
}
- (NSString *)mapVideoURL:(NSString *)raw generation:(uint64_t)generation headers:(NSDictionary *)headers error:(NSError **)error {
    return [self mapVideoURL:raw generation:generation headers:headers alternates:nil error:error];
}
- (NSString *)mapVideoURL:(NSString *)raw generation:(uint64_t)generation headers:(NSDictionary *)headers
               alternates:(NSArray<NSString *> *)alternates error:(NSError **)error {
    // Never decode/re-encode a signed query, and never allow Location injection.
    BOOL safe = [raw isKindOfClass:NSString.class] && raw.length && raw.length <= 16384;
    for(NSUInteger i=0;safe && i<raw.length;i++) { unichar c = [raw characterAtIndex:i]; if(c <= 32 || c >= 127) safe = NO; }
    NSURLComponents *url = safe ? [NSURLComponents componentsWithString:raw] : nil;
    NSRegularExpression *host = [NSRegularExpression regularExpressionWithPattern:
        @"(^|\\.)(bilivideo\\.(com|cn|net)|akamaized\\.net|szbdyd\\.com|hdslb\\.com|xycdn\\.com|mountaintoys\\.cn|nexusedgeio\\.com|ahdohpiechei\\.com)$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSString *hostname = url.host ?: @"";
    uint16_t testPort = self.testOriginPort;
    BOOL testOrigin = testPort && [hostname isEqual:@"127.0.0.1"] && [url.scheme isEqual:@"http"] && url.port.integerValue == testPort;
    if(!url || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString ?: @""] || url.user || url.password
       || (!testOrigin && ![host firstMatchInString:hostname options:0 range:NSMakeRange(0,hostname.length)])
       || ![@[@"m4s",@"mp4",@"flv"] containsObject:url.percentEncodedPath.pathExtension.lowercaseString ?: @""]
       || url.fragment || (!testOrigin && url.port && url.port.integerValue != ([url.scheme.lowercaseString isEqual:@"https"] ? 443 : 80))) {
        if(error) *error = LBError(2); return nil;
    }
    @synchronized(self) {
        if(!_enabled || _closed || generation != _generation) return nil;
        BTRLBMapping *mapping = _mappingsByRaw[raw];
        // A fallback bypasses only that source URL, avoiding redirect loops.
        if(mapping.bypassed) { if(error) *error = LBError(6); return nil; }
        if(!mapping && _mappingsByRaw.count >= BTRMaxMappings) {
            // Reopens re-sign URLs: evict the least recently used idle mapping.
            BTRLBMapping *idle = nil;
            for(BTRLBMapping *candidate in _mappingsByRaw.allValues)
                if(!candidate.connections && (!idle || candidate.lastUsed < idle.lastUsed)) idle = candidate;
            if(!idle) { if(error) *error = LBError(7); return nil; }
            [_mappingsByRaw removeObjectForKey:idle.raw]; [_mappingsByPath removeObjectForKey:idle.path];
            _stats[@"evictedMappings"] = @([_stats[@"evictedMappings"] unsignedLongLongValue] + 1);
        }
        if(![headers isKindOfClass:NSDictionary.class]) {
            if(!_mappingsByRaw.count) {
                _stats[@"sourceMetadataCaptured"] = @NO;
                _stats[@"sourceMetadataGeneration"] = @(generation);
                _stats[@"hasUserAgent"] = @NO; _stats[@"hasReferer"] = @NO; _stats[@"hasOrigin"] = @NO;
            }
            if(error) *error = LBError(4); return nil;
        }
        NSMutableDictionary *safeHeaders = [NSMutableDictionary dictionary];
        for(NSString *name in @[@"Referer",@"User-Agent",@"Origin"]) {
            id value = headers[name];
            if(!value) continue;
            if(![value isKindOfClass:NSString.class] || [value length] > 1024
               || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
                if(error) *error = LBError(5); return nil;
            }
            safeHeaders[name] = [value copy];
        }
        if(![self startListener]) { if(error) *error = LBError(3); return nil; }
        if(!mapping) {
            unsigned char random[32]; arc4random_buf(random,sizeof(random));
            NSMutableString *token = [NSMutableString string];
            for(NSUInteger i=0;i<sizeof(random);i++) [token appendFormat:@"%02x",random[i]];
            mapping = [BTRLBMapping new]; mapping.generation = generation; mapping.raw = [raw copy];
            mapping.path = [NSString stringWithFormat:@"/%@/media.m4s",token];
            mapping.headers = safeHeaders; mapping.lastUsed = NSProcessInfo.processInfo.systemUptime;
            _mappingsByRaw[mapping.raw] = mapping; _mappingsByPath[mapping.path] = mapping;
            _stats[@"mappings"] = @([_stats[@"mappings"] unsignedLongLongValue] + 1);
            _stats[@"sourceMetadataCaptured"] = @YES; _stats[@"sourceMetadataGeneration"] = @(generation);
            _stats[@"hasUserAgent"] = @(safeHeaders[@"User-Agent"] != nil);
            _stats[@"hasReferer"] = @(safeHeaders[@"Referer"] != nil);
            _stats[@"hasOrigin"] = @(safeHeaders[@"Origin"] != nil);
        }
        if(alternates.count) {
            NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:mapping.alternates ?: @[]];
            for(NSString *other in alternates)
                if([other isKindOfClass:NSString.class] && ![other isEqual:mapping.raw] && merged.count < 3) [merged addObject:[other copy]];
            mapping.alternates = merged.array;
        }
        return [NSString stringWithFormat:@"http://127.0.0.1:%u%@",_port,mapping.path];
    }
}
- (void)acceptConnections {
    while(YES) {
        int fd;
        @synchronized(self) { if(_closed || _listener < 0) return; fd = accept(_listener,NULL,NULL); }
        if(fd < 0) return;
        int yes = 1;
        if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes)) || fcntl(fd,F_SETFL,O_NONBLOCK) < 0) { close(fd); continue; }
        BTRLBConnection *connection = [BTRLBConnection new]; connection.fd = fd;
        @synchronized(self) {
            if(_closed || _connections.count >= BTRMaxConnections) {
                _stats[@"acceptRejected"] = @([_stats[@"acceptRejected"] unsignedLongLongValue] + 1);
                [connection closeSocket]; continue;
            }
            [_connections addObject:connection];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            @autoreleasepool { @try { [self serve:connection]; } @finally {
                [connection closeSocket];
                @synchronized(self) {
                    [self->_connections removeObject:connection];
                    BTRLBMapping *mapping = connection.mapping;
                    if(mapping.connections) { mapping.connections--; mapping.lastUsed = NSProcessInfo.processInfo.systemUptime; }
                }
            } }
        });
    }
}
- (BOOL)alive:(BTRLBConnection *)connection {
    @synchronized(connection) { if(connection.cancelled || connection.fd < 0) return NO; }
    struct pollfd descriptor = {connection.fd,POLLIN,0};
    if(poll(&descriptor,1,0) < 0 || descriptor.revents & (POLLERR|POLLHUP|POLLNVAL)) return NO;
    if(descriptor.revents & POLLIN) { char byte; ssize_t n = recv(connection.fd,&byte,1,MSG_PEEK|MSG_DONTWAIT); if(n == 0) return NO; }
    return YES;
}
- (BOOL)current:(BTRLBMapping *)mapping connection:(BTRLBConnection *)connection {
    @synchronized(self) { if(_closed || !_enabled || mapping != _mappingsByPath[mapping.path] || mapping.generation != _generation) return NO; }
    return [self alive:connection];
}
- (NSData *)readHeaders:(BTRLBConnection *)connection {
    NSMutableData *data = [NSMutableData data]; NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    while(data.length < 8192 && [self alive:connection] && NSProcessInfo.processInfo.systemUptime < deadline) {
        struct pollfd descriptor = {connection.fd,POLLIN,0}; if(poll(&descriptor,1,100) <= 0) continue;
        unsigned char bytes[512]; ssize_t size = recv(connection.fd,bytes,MIN(sizeof(bytes),8192-data.length),0);
        if(size <= 0) return nil; [data appendBytes:bytes length:(NSUInteger)size];
        if(data.length >= 4) {
            NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
            NSRange end = [data rangeOfData:separator options:0 range:NSMakeRange(0,data.length)];
            if(end.location != NSNotFound) { if(NSMaxRange(end) != data.length) return nil; return data; }
        }
    }
    return nil;
}
- (BOOL)write:(NSData *)data connection:(BTRLBConnection *)connection mapping:(BTRLBMapping *)mapping body:(BOOL)body {
    NSUInteger offset = 0; NSTimeInterval progress = NSProcessInfo.processInfo.systemUptime;
    while(offset < data.length && [self alive:connection] && (!mapping || [self current:mapping connection:connection])
          && NSProcessInfo.processInfo.systemUptime - progress < BTRWriteStall) {
        struct pollfd descriptor = {connection.fd,POLLOUT,0}; if(poll(&descriptor,1,100) <= 0) continue;
        ssize_t sent = send(connection.fd,(const unsigned char *)data.bytes+offset,data.length-offset,0);
        if(sent < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if(sent <= 0) return NO; offset += (NSUInteger)sent; progress = NSProcessInfo.processInfo.systemUptime;
        if(body) [self add:@"validatedBytesWritten" amount:(uint64_t)sent generation:mapping.generation];
    }
    return offset == data.length;
}
- (void)status:(NSInteger)status extra:(NSString *)extra connection:(BTRLBConnection *)connection {
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %ld Response\r\nConnection: close\r\nContent-Length: 0\r\n%@\r\n",(long)status,extra ?: @""];
    [self write:[response dataUsingEncoding:NSASCIIStringEncoding] connection:connection mapping:nil body:NO];
}
- (void)fallback:(BTRLBMapping *)mapping connection:(BTRLBConnection *)connection {
    BOOL redirect;
    @synchronized(self) { redirect = _mappingsByPath[mapping.path] == mapping && !mapping.bypassed; if(redirect) mapping.bypassed = YES; }
    if(redirect) {
        [self add:@"fallbacks" amount:1 generation:mapping.generation];
        [self status:302 extra:[NSString stringWithFormat:@"Location: %@\r\n",mapping.raw] connection:connection];
    } else [self status:503 extra:nil connection:connection];
}
- (NSDictionary *)policy:(NSString *)method arguments:(NSArray *)arguments {
    __block NSDictionary *result;
    dispatch_sync(_policyQueue, ^{
        self->_httpContext.exception = nil;
        result = [[self->_httpContext[@"BTRLoopbackHTTP"] invokeMethod:method withArguments:arguments] toDictionary];
        if(self->_httpContext.exception) result = nil;
    });
    return result;
}
- (BTRRangeDownloader *)downloaderForMapping:(BTRLBMapping *)mapping error:(NSError **)error {
    BTRRangeDownloader *downloader = [[BTRRangeDownloader alloc] initWithRangeCore:[NSString stringWithUTF8String:BTRCoreScript]
        policy:[NSString stringWithUTF8String:BTRPolicyScript] allowHTTP:YES concurrency:self.pieceConcurrency
        completionQueue:_completionQueue error:error];
    downloader.allowTestHost = self.testOriginPort != 0;
    __weak typeof(self) weak = self;
    __weak BTRLBMapping *weakMapping = mapping;
    downloader.pieceObserver = ^(NSDictionary *piece) { [weak recordPiece:piece mapping:weakMapping]; };
    return downloader;
}
// Starts one window without waiting; the caller pipelines the next window while writing.
- (BTRLBFetch *)startFetch:(BTRLBMapping *)mapping downloader:(BTRRangeDownloader *)downloader start:(uint64_t)start end:(uint64_t)end {
    return [self startFetch:mapping downloader:downloader start:start end:end startup:NO];
}
- (BTRLBFetch *)startFetch:(BTRLBMapping *)mapping downloader:(BTRRangeDownloader *)downloader start:(uint64_t)start end:(uint64_t)end startup:(BOOL)startup {
    return [self startFetch:mapping downloader:downloader start:start end:end startup:startup meta:NO];
}
- (BTRLBFetch *)startFetch:(BTRLBMapping *)mapping downloader:(BTRRangeDownloader *)downloader start:(uint64_t)start end:(uint64_t)end
                   startup:(BOOL)startup meta:(BOOL)meta {
    BTRLBFetch *fetch = [BTRLBFetch new];
    fetch.done = dispatch_semaphore_create(0); fetch.downloader = downloader; fetch.start = start; fetch.end = end;
    fetch.began = NSProcessInfo.processInfo.systemUptime;
    BTREngine *engine = self.engine;
    if(engine.usable) {
        // Desktop engine: its own node choice (player hosts + mirrors), hedging and thread budget.
        NSArray *alternates; NSDictionary *headers;
        @synchronized(self) { alternates = mapping.alternates ?: @[]; headers = mapping.headers ?: @{}; }
        fetch.engine = engine;
        __weak typeof(self) weak = self;
        fetch.engineJob = [engine downloadURL:mapping.raw alternates:alternates headers:headers start:start end:end startup:startup meta:meta
            completion:^(NSData *data, int64_t total, NSString *error, NSUInteger hosts) {
                fetch.data = data; fetch.total = total >= 0 ? @(total) : nil; fetch.tag = @"";
                if(error) {
                    BOOL cancelled = [error isEqual:@"cancelled"];
                    fetch.error = [NSError errorWithDomain:@"BTREngine" code:cancelled ? NSURLErrorCancelled : 12
                                                  userInfo:@{NSLocalizedDescriptionKey:error}];
                    if(!cancelled) [weak noteEngineError:error];
                } else [weak notePeakHosts:hosts];
                dispatch_semaphore_signal(fetch.done);
            }];
        return fetch;
    }
    NSString *expected; NSArray *sources;
    @synchronized(self) {
        expected = mapping.etag;
        // Health order: hosts that keep failing/stalling go last, or out while others work.
        NSMutableArray *healthy = [NSMutableArray array], *poor = [NSMutableArray array];
        for(NSString *url in [@[mapping.raw] arrayByAddingObjectsFromArray:mapping.alternates ?: @[]]) {
            NSUInteger ok = [mapping.sourceOK[url] unsignedIntegerValue], failed = [mapping.sourceFailed[url] unsignedIntegerValue];
            [(failed >= 2 && failed > ok ? poor : healthy) addObject:url];
        }
        if(poor.count && healthy.count) _stats[@"sourcesDemoted"] = @([_stats[@"sourcesDemoted"] unsignedLongLongValue] + poor.count);
        sources = healthy.count ? healthy : poor;
    }
    [downloader downloadSources:sources start:start end:end headers:mapping.headers expectedETag:expected
        completion:^(NSData *bytes,NSNumber *length,NSString *identity,NSError *error) {
            fetch.data = bytes; fetch.total = length; fetch.tag = identity; fetch.error = error;
            dispatch_semaphore_signal(fetch.done);
        }];
    return fetch;
}
- (void)noteEngineError:(NSString *)error {
    NSString *kind = [[error componentsSeparatedByString:@":"].firstObject stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    if(kind.length > 32) kind = [kind substringToIndex:32];
    @synchronized(self) { NSString *key = [@"engineError_" stringByAppendingString:kind];
        _stats[key] = @([_stats[key] unsignedLongLongValue] + 1); }
}
- (void)notePeakHosts:(NSUInteger)hosts {
    @synchronized(self) { if(hosts > [_stats[@"maxHostsPerWindow"] unsignedIntegerValue]) _stats[@"maxHostsPerWindow"] = @(hosts); }
}
- (void)abandon:(BTRLBFetch *)fetch {
    if(!fetch) return;
    if(fetch.engine) [fetch.engine cancelJob:fetch.engineJob];
    else [fetch.downloader cancel];
    // The downloader is reused only after its job acknowledged cancellation.
    dispatch_semaphore_wait(fetch.done,DISPATCH_TIME_FOREVER);
}
- (NSData *)waitFetch:(BTRLBFetch *)fetch mapping:(BTRLBMapping *)mapping connection:(BTRLBConnection *)connection {
    connection.failureReason = @"metadata_failed"; connection.failureCode = 0;
    NSTimeInterval deadline = fetch.began + 35;
    while(dispatch_semaphore_wait(fetch.done,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))) {
        if(![self current:mapping connection:connection] || NSProcessInfo.processInfo.systemUptime >= deadline) {
            [self abandon:fetch];
            connection.failureReason = [self current:mapping connection:connection] ? @"timeout" : @"cancelled";
            return nil;
        }
    }
    NSError *failure = fetch.error;
    if(failure || fetch.data.length != fetch.end-fetch.start+1 || !fetch.total || !fetch.tag) {
        connection.failureCode = failure.code; connection.httpStatus = fetch.downloader.lastHTTPStatus;
        connection.failureReason = failure.code == 12 ? @"engine_failed" : failure.code == 10 ? @"upstream_http_status" : failure.code == 8 ? @"identity_mismatch"
            : failure.code == 9 ? @"range_protocol_error" : failure.code == NSURLErrorTimedOut ? @"timeout"
            : failure.code == NSURLErrorCancelled ? @"cancelled" : @"upstream_failed";
        return nil;
    }
    @synchronized(self) {
        if(mapping != _mappingsByPath[mapping.path] || mapping.generation != _generation) { connection.failureReason = @"cancelled"; return nil; }
        BOOL single = !mapping.alternates.count;
        if((mapping.total && ![mapping.total isEqual:fetch.total]) || (single && mapping.etag && ![mapping.etag isEqual:fetch.tag])) {
            connection.failureReason = @"identity_mismatch"; return nil;
        }
        mapping.total = fetch.total; mapping.etag = single ? fetch.tag : nil;
        if(fetch.downloader.lastETagKind) _stats[@"upstreamETagKind"] = fetch.downloader.lastETagKind;
    }
    uint64_t ms = (uint64_t)((NSProcessInfo.processInfo.systemUptime - fetch.began) * 1000);
    @synchronized(self) {
        if(mapping.generation == _generation && ms > [_stats[@"maxWindowMs"] unsignedLongLongValue]) _stats[@"maxWindowMs"] = @(ms);
    }
    [self add:@"parallelSegments" amount:fetch.downloader.validatedPieces generation:mapping.generation];
    return fetch.data;
}
- (void)failBeforeHeaders:(BTRLBMapping *)mapping connection:(BTRLBConnection *)connection {
    [self add:@"failedRanges" amount:1 generation:mapping.generation];
    [self recordFailure:connection reason:nil generation:mapping.generation];
    if([self current:mapping connection:connection]) [self fallback:mapping connection:connection];
}
- (void)serve:(BTRLBConnection *)connection {
    NSData *header = [self readHeaders:connection];
    NSString *raw = header ? [[NSString alloc] initWithData:header encoding:NSASCIIStringEncoding] : nil;
    NSString *host; @synchronized(self) { host = [NSString stringWithFormat:@"127.0.0.1:%u",_port]; }
    NSDictionary *request = raw ? [self policy:@"parseRequest" arguments:@[raw,host]] : nil;
    if(!request || request[@"error"]) { [self status:400 extra:nil connection:connection]; return; }
    BTRLBMapping *mapping;
    @synchronized(self) {
        mapping = _enabled && [request[@"path"] isKindOfClass:NSString.class] ? _mappingsByPath[request[@"path"]] : nil;
        if(mapping) { mapping.connections++; mapping.lastUsed = NSProcessInfo.processInfo.systemUptime; connection.mapping = mapping; }
    }
    if(!mapping) { [self status:404 extra:nil connection:connection]; return; }
    if(mapping.bypassed) { [self status:302 extra:[NSString stringWithFormat:@"Location: %@\r\n",mapping.raw] connection:connection]; return; }
    [self add:@"loopbackRequests" amount:1 generation:mapping.generation];
    BOOL head = [request[@"method"] isEqual:@"HEAD"];
    if(head) [self add:@"headRequests" amount:1 generation:mapping.generation];
    // Concurrent GETs are left to the player: it closes what it no longer reads.
    if(request[@"fallback"]) { [self recordFailure:connection reason:@"unsupported_range" generation:mapping.generation];
        [self fallback:mapping connection:connection]; return; }
    NSError *error;
    BOOL engine = self.engine.usable;
    BTRRangeDownloader *downloaders[2] = {nil, nil};
    if(!engine) { downloaders[0] = [self downloaderForMapping:mapping error:&error]; downloaders[1] = [self downloaderForMapping:mapping error:&error]; }
    connection.downloader = downloaders[0]; connection.spareDownloader = downloaders[1];
    if(!engine && (!downloaders[0] || !downloaders[1])) { [self recordFailure:connection reason:@"metadata_failed" generation:mapping.generation];
        [self fallback:mapping connection:connection]; return; }
    NSNumber *total; @synchronized(self) { total = mapping.total; }
    NSDictionary *requestRange = [request[@"range"] isKindOfClass:NSDictionary.class] ? request[@"range"] : nil;
    NSData *first = nil; BTRLBFetch *fetch = nil;
    NSTimeInterval accepted = NSProcessInfo.processInfo.systemUptime;
    if(!total && !head && engine && (!requestRange || ![requestRange[@"suffix"] boolValue])) {
        // Engine: the 0-0 length probe and the startup window run at the same time, so the
        // probe costs no extra round trip; a window past EOF is cancelled, never retried.
        uint64_t start = requestRange ? [requestRange[@"start"] unsignedLongLongValue] : 0;
        BTRLBFetch *probe = [self startFetch:mapping downloader:nil start:0 end:0 startup:NO meta:YES];
        BTRLBFetch *optimistic = [self startFetch:mapping downloader:nil start:start end:start+self.firstWindowBytes-1 startup:YES];
        if(![self waitFetch:probe mapping:mapping connection:connection]) {
            [self abandon:optimistic]; [self failBeforeHeaders:mapping connection:connection]; return;
        }
        total = probe.total;
        if(start + self.firstWindowBytes <= total.unsignedLongLongValue) {
            fetch = optimistic; first = [self waitFetch:optimistic mapping:mapping connection:connection];
            if(!first) { [self failBeforeHeaders:mapping connection:connection]; return; }
        } else { [self abandon:optimistic]; [self add:@"optimisticMisses" amount:1 generation:mapping.generation]; }
    }
    if(!total && !head && !engine) {
        // Skip a separate 0-0 metadata round trip: the first window's 206 carries the total.
        uint64_t start = requestRange && ![requestRange[@"suffix"] boolValue] ? [requestRange[@"start"] unsignedLongLongValue] : 0;
        if(!requestRange || ![requestRange[@"suffix"] boolValue]) {
            fetch = [self startFetch:mapping downloader:downloaders[0] start:start end:start+self.firstWindowBytes-1 startup:YES];
            first = [self waitFetch:fetch mapping:mapping connection:connection];
            if(first) total = fetch.total;
            // Near EOF the optimistic window overshoots: resolve via the 0-0 probe instead.
            else if([connection.failureReason isEqual:@"range_protocol_error"]) [self add:@"optimisticMisses" amount:1 generation:mapping.generation];
            else { [self failBeforeHeaders:mapping connection:connection]; return; }
        }
    }
    if(!total) {
        fetch = [self startFetch:mapping downloader:downloaders[0] start:0 end:0 startup:NO meta:YES];
        if(![self waitFetch:fetch mapping:mapping connection:connection]) { [self failBeforeHeaders:mapping connection:connection]; return; }
        total = fetch.total;
    }
    NSDictionary *range = [self policy:@"resolve" arguments:@[request,total]];
    if(range[@"error"]) {
        [self status:416 extra:[NSString stringWithFormat:@"Content-Range: bytes */%@\r\n",total] connection:connection]; return;
    }
    if(!range || range[@"fallback"]) { [self recordFailure:connection reason:@"metadata_failed" generation:mapping.generation];
        [self fallback:mapping connection:connection]; return; }
    uint64_t start = [range[@"start"] unsignedLongLongValue], end = [range[@"end"] unsignedLongLongValue];
    if(first && (fetch.start != start || fetch.end > end)) {
        // Optimistic window covers [start, ...]; trim to an explicit shorter end.
        first = fetch.start == start && end >= start ? [first subdataWithRange:NSMakeRange(0,(NSUInteger)(end-start+1))] : nil;
    }
    if(!head && !first) {
        fetch = [self startFetch:mapping downloader:downloaders[0] start:start end:MIN(end,start+self.firstWindowBytes-1) startup:YES];
        first = [self waitFetch:fetch mapping:mapping connection:connection];
        if(!first) { [self failBeforeHeaders:mapping connection:connection]; return; }
    }
    NSMutableString *response = [NSMutableString stringWithFormat:@"HTTP/1.1 %@ Response\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nContent-Length: %@\r\n",range[@"status"],range[@"length"]];
    if([range[@"status"] integerValue] == 206) [response appendFormat:@"Content-Range: bytes %llu-%llu/%@\r\n",start,end,total];
    [response appendString:@"\r\n"];
    if(![self write:[response dataUsingEncoding:NSASCIIStringEncoding] connection:connection mapping:mapping body:NO]) {
        [self add:@"failedRanges" amount:1 generation:mapping.generation];
        [self recordFailure:connection reason:@"output_interrupted" generation:mapping.generation]; return;
    }
    if(head) { [self add:@"completedHEAD" amount:1 generation:mapping.generation]; return; }
    uint64_t ttfb = (uint64_t)((NSProcessInfo.processInfo.systemUptime - accepted) * 1000);
    @synchronized(self) {
        if(mapping.generation == _generation && ttfb > [_stats[@"maxFirstByteMs"] unsignedLongLongValue]) _stats[@"maxFirstByteMs"] = @(ttfb);
    }
    // Pipeline: later windows download while this one is written. The legacy downloader has one
    // job per instance (depth 1, two alternating instances); the engine takes prefetchDepth.
    NSUInteger depth = engine ? MAX(1,self.prefetchDepth) : 1;
    NSMutableArray<BTRLBFetch *> *pending = [NSMutableArray array];
    __block uint64_t issued = start + first.length; __block int slot = 1;
    BTRRangeDownloader *legacyA = downloaders[0], *legacyB = downloaders[1];
    void (^refill)(void) = ^{
        while(pending.count < depth && issued <= end) {
            BTRLBFetch *more = [self startFetch:mapping downloader:slot ? legacyB : legacyA start:issued end:MIN(end,issued+self.windowBytes-1)];
            slot ^= 1; issued = more.end + 1; [pending addObject:more];
        }
    };
    void (^abandonAll)(void) = ^{ for(BTRLBFetch *one in pending) [self abandon:one]; [pending removeAllObjects]; };
    NSData *window = first;
    while(window) {
        @autoreleasepool {
            refill();
            if(![self write:window connection:connection mapping:mapping body:YES]) {
                abandonAll();
                [self add:@"failedRanges" amount:1 generation:mapping.generation];
                [self recordFailure:connection reason:@"output_interrupted" generation:mapping.generation];
                if(![self alive:connection]) [self add:@"cancellations" amount:1 generation:mapping.generation];
                return; // Headers/body already started: close, never redirect or fabricate EOF.
            }
            [self add:@"completedRanges" amount:1 generation:mapping.generation];
            window = nil;
            if(!pending.count) break;
            BTRLBFetch *next = pending.firstObject; [pending removeObjectAtIndex:0];
            NSTimeInterval waitStarted = NSProcessInfo.processInfo.systemUptime;
            window = [self waitFetch:next mapping:mapping connection:connection];
            if(!window && ![connection.failureReason isEqual:@"cancelled"] && ![connection.failureReason isEqual:@"identity_mismatch"]
               && [self current:mapping connection:connection]) {
                // Body already started: one fresh retry of this window before closing.
                [self add:@"windowRetries" amount:1 generation:mapping.generation];
                next = [self startFetch:mapping downloader:next.downloader start:next.start end:next.end];
                window = [self waitFetch:next mapping:mapping connection:connection];
            }
            NSTimeInterval waited = NSProcessInfo.processInfo.systemUptime - waitStarted;
            if(waited > BTRSlowWait) {
                BOOL bypass;
                @synchronized(self) { mapping.slowWaits++; bypass = mapping.slowWaits >= 2 && !mapping.bypassed;
                    if(bypass) mapping.bypassed = YES; }
                [self add:@"slowWaits" amount:1 generation:mapping.generation];
                if(bypass) [self add:@"slowBypass" amount:1 generation:mapping.generation];
            }
            if(!window) {
                abandonAll();
                [self add:@"failedRanges" amount:1 generation:mapping.generation];
                [self recordFailure:connection reason:nil generation:mapping.generation];
                if(![self alive:connection]) [self add:@"cancellations" amount:1 generation:mapping.generation];
                return;
            }
        }
    }
    [self add:@"completeHTTPResponses" amount:1 generation:mapping.generation];
}
- (NSDictionary *)snapshot {
    // Engine stats hop to the JS queue: fetch them before taking the adapter lock.
    NSDictionary *engineStats = self.engine.usable ? [self.engine stats] : nil;
    @synchronized(self) {
        NSMutableDictionary *result = [_stats mutableCopy];
        for(NSString *name in @[@"loopbackRequests",@"parallelSegments",@"completedRanges",@"failedRanges",@"fallbacks",@"validatedBytesWritten",@"cancellations",@"completeHTTPResponses"])
            if(!result[name]) result[name] = @0;
        result[@"enabled"] = @(_enabled && !_closed); result[@"generation"] = @(_generation);
        NSUInteger bypassed = 0;
        for(BTRLBMapping *mapping in _mappingsByPath.allValues) if(mapping.bypassed) bypassed++;
        result[@"mapped"] = @(_mappingsByPath.count > 0); result[@"bypassed"] = @(bypassed > 0);
        result[@"currentMappings"] = @(_mappingsByPath.count); result[@"bypassedMappings"] = @(bypassed);
        if(!result[@"mappings"]) result[@"mappings"] = @0;
        result[@"activeConnections"] = @(_connections.count);
        result[@"rangeDeliveryVerified"] = @([result[@"completeHTTPResponses"] unsignedLongLongValue] > 0);
        result[@"downloadReplacementVerified"] = @NO;
        result[@"maximumUpstreamConcurrency"] = @(self.pieceConcurrency);
        result[@"counterScope"] = @"process_lifetime";
        result[@"transportEngine"] = engineStats ? @"desktop" : @"legacy";
        if(engineStats) result[@"engine"] = engineStats;
        return result;
    }
}
- (void)close {
    NSArray *old;
    @synchronized(self) { _closed = YES; _enabled = NO; [_mappingsByPath removeAllObjects]; [_mappingsByRaw removeAllObjects]; old = _connections.allObjects;
        if(_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; _listener = -1; } }
    for(BTRLBConnection *connection in old) [connection cancel];
    [self.engine close];
}
@end
