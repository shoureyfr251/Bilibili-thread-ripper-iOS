"use strict";
// Shared download core. BTR Desktop keeps an identical copy as test/shared.test.cjs.
const {test}=require("node:test"),assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
const SOURCE=fs.existsSync(path.join(__dirname,"../shared/range-core.js"))?path.join(__dirname,"../shared"):path.join(__dirname,"../src");
function load(){
  const context=vm.createContext({URL,AbortController,DOMException,Response,ReadableStream,Headers,Uint8Array,Promise,setTimeout,clearTimeout,performance,console});
  context.globalThis=context;
  // The resolver's short failure back-off uses Date.now. Tests move this clock forward.
  context.__now=1e12;
  vm.runInContext("Date.now=()=>globalThis.__now;",context);
  for(const file of ["range-core.js","cdn-resolver.js","idm-downloader.js"])vm.runInContext(fs.readFileSync(path.join(SOURCE,file),"utf8"),context,{filename:file});
  return {core:context.__BILI_RANGE_CORE__,cdn:context.__BILI_CDN_RESOLVER_FACTORY__,idm:context.__BILI_IDM_DOWNLOADER_FACTORY__,context,advance:ms=>{context.__now+=ms;}};
}
const mediaUrl=host=>`https://${host}/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&os=x`;
const dead=Object.assign(new Error("Range 校验失败：HTTP 503"),{name:"Error"});
const aborted=new DOMException("并发副本已取消","AbortError");

test("new defaults: mainland CDN, 8 threads, error notices off",()=>{
  const {core}=load();
  const defaults=core.normalizeSettings({});
  assert.equal(defaults.mode,"mainland");assert.equal(defaults.concurrency,8);assert.equal(defaults.errorNotices,false);assert.equal(defaults.debugNotices,false);
  const chosen=core.normalizeSettings({mode:"overseas",concurrency:32,errorNotices:true});
  assert.equal(chosen.mode,"overseas");assert.equal(chosen.concurrency,32);assert.equal(chosen.errorNotices,true);
  assert.equal(core.normalizeSettings({concurrency:7}).concurrency,8);
});

test("a node is banned after two failures that delivered 0 bytes, and only for the current video",()=>{
  const {cdn}=load();
  const banned=[];
  const bans=cdn.createBanList({onBan:host=>banned.push(host)});
  const hw=mediaUrl("upos-sz-mirrorhw.bilivideo.com");
  assert.equal(bans.record(hw,0,aborted),false,"a cancelled hedge copy is not a failure");
  assert.equal(bans.record(hw,4096,dead),false,"a transfer that sent data before stalling is not a dead node");
  assert.equal(bans.record(hw,0,dead),false);assert.equal(bans.allows(hw),true);
  // A different signed URL on the same node counts toward the same node.
  assert.equal(bans.record(hw.replace("30080","30280"),0,dead),true);
  assert.equal(bans.allows(hw),false);assert.deepEqual(Array.from(banned),["upos-sz-mirrorhw.bilivideo.com"]);
  assert.equal(bans.record(hw,0,dead),false,"a banned node is reported once");
  assert.deepEqual(Array.from(bans.hosts()),["upos-sz-mirrorhw.bilivideo.com"]);
  bans.reset();
  assert.equal(bans.allows(hw),true);assert.deepEqual(Array.from(bans.hosts()),[]);
  assert.equal(bans.record(hw,0,dead),false,"strikes start again for the next video");
});

test("resolvers skip banned nodes but never end up with no address",()=>{
  const {cdn}=load();
  const bans=cdn.createBanList();
  const resolver=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorali.bilivideo.com")},()=> "mainland",bans);
  const hostsOf=list=>Array.from(list,url=>new URL(url).hostname);
  assert.equal(resolver.urls().length,8);
  resolver.failure(mediaUrl("upos-sz-mirrorhw.bilivideo.com"),dead,0);
  assert.equal(resolver.urls().length,8,"one strike does not ban");
  resolver.failure(mediaUrl("upos-sz-mirrorhw.bilivideo.com"),dead,0);
  for(const list of [resolver.urls(),resolver.ordered(0),resolver.rangeCandidates(),resolver.rescueCandidates(),resolver.startupCandidates()]){
    assert.ok(!hostsOf(list).includes("upos-sz-mirrorhw.bilivideo.com"));assert.ok(list.length>0);
  }
  assert.equal(resolver.allows(mediaUrl("upos-sz-mirrorhw.bilivideo.com")),false);
  assert.equal(Array.from(resolver.status()).find(item=>item.host==="upos-sz-mirrorhw.bilivideo.com").state,"banned");
  // Another resolver of the same video (audio track, other quality) shares the list.
  const audio=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorbos.bilivideo.com")},()=> "mainland",bans);
  assert.ok(!hostsOf(audio.urls()).includes("upos-sz-mirrorhw.bilivideo.com"));
  for(const host of cdn.MAINLAND_HOSTS){bans.record(mediaUrl(host),0,dead);bans.record(mediaUrl(host),0,dead);}
  assert.equal(resolver.urls().length,8,"with every node banned the original list is used again");
  assert.ok(resolver.startupCandidates().length>0);
  // Without a ban list the resolver keeps its old behaviour.
  const plain=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorali.bilivideo.com")},()=> "mainland");
  plain.failure(mediaUrl("upos-sz-mirrorhw.bilivideo.com"),dead,0);plain.failure(mediaUrl("upos-sz-mirrorhw.bilivideo.com"),dead,0);
  assert.equal(plain.allows(mediaUrl("upos-sz-mirrorhw.bilivideo.com")),true);
});

test("the downloader reports received bytes, bans a silent node and stops using it",{timeout:60000},async()=>{
  const {cdn,idm,advance}=load();
  const DEAD="upos-sz-mirrorhw.bilivideo.com",PARTIAL="upos-sz-mirrorbos.bilivideo.com";
  const requests=new Map(),banned=[];
  const count=host=>requests.get(host)||0;
  const nativeFetch=async(url,init)=>{
    const host=new URL(url).hostname;requests.set(host,count(host)+1);
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    const headers={"Content-Range":`bytes ${start}-${end}/8388608`};
    if(host===DEAD)return new Response("",{status:503});
    if(host===PARTIAL){
      // Sends a little data, then the connection breaks: slow, not dead.
      let sent=false;
      const body=new ReadableStream({pull(controller){if(sent)controller.error(new Error("连接中断"));else{sent=true;controller.enqueue(new Uint8Array(1024));}}});
      return new Response(body,{status:206,headers});
    }
    const bytes=new Uint8Array(end-start+1);for(let i=0;i<bytes.length;i++)bytes[i]=(start+i)%251;
    return new Response(bytes,{status:206,headers});
  };
  const transfers=[];
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:8}),nativeFetch,onTransfer:event=>{transfers.push(event);return transfers.length;}});
  const bans=cdn.createBanList({onBan:host=>banned.push(host)});
  const resolver=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorali.bilivideo.com")},()=> "mainland",bans);
  const range={start:0,end:1024*1024-1,length:1024*1024};
  const download=async()=>{const result=await downloader.downloadRange(range,resolver,{parallel:true,kind:"video"});assert.equal(result.bytes.length,range.length);assert.ok(result.bytes.every((value,i)=>value===i%251));};
  // Each round starts after the short back-off, as when a user keeps watching. The rounds
  // continue past the ban: the exploration slot only reaches the partial node now and then.
  for(let round=0;round<6;round++){await download();advance(61000);}
  assert.deepEqual(Array.from(banned),[DEAD]);
  // Parallel pieces may already be waiting on the node when the second empty reply arrives.
  assert.ok(count(DEAD)>=2,"banned only after two empty replies");
  assert.ok(count(PARTIAL)>=2,"the partial node was tried");
  assert.equal(bans.allows(mediaUrl(PARTIAL)),true,"a node that sent data is not banned");
  const before=count(DEAD);
  for(let round=0;round<3;round++){await download();advance(61000);}
  assert.equal(count(DEAD),before,"a banned node gets no new requests in this video");
  assert.ok(transfers.some(event=>event.phase==="error"));
  bans.reset();
  assert.equal(resolver.allows(mediaUrl(DEAD)),true);
});

const AKAMAI="upos-hz-mirrorakam.akamaized.net";
const akamaiUrl=os=>`https://${AKAMAI}/upgcxcode/00/00/1/1-1-30080.m4s?deadline=1&os=${os}`;
const refused=Object.assign(new Error("Range 校验失败：HTTP 403"),{status:403});

test("akamaized.net addresses are host-swapped only when Bilibili hands out nothing else",()=>{
  const {cdn}=load();
  const hostsOf=list=>Array.from(new Set(Array.from(list,url=>new URL(url).hostname)));
  const akamaiOnly={baseUrl:akamaiUrl("cosovbv"),backupUrl:[akamaiUrl("akam")]};
  const mainland=cdn.representationUrls(akamaiOnly,"mainland");
  assert.equal(mainland.length,16,"two addresses on each of the eight mainland nodes");
  assert.deepEqual(hostsOf(mainland),Array.from(cdn.MAINLAND_HOSTS));
  // Node-major order: the first requests already cover both addresses.
  assert.deepEqual(Array.from(mainland.slice(0,2),url=>new URL(url).searchParams.get("os")),["cosovbv","akam"]);
  const overseas=cdn.representationUrls(akamaiOnly,"overseas");
  assert.deepEqual(Array.from(overseas.slice(0,2)),[akamaiUrl("cosovbv"),akamaiUrl("akam")],"the originals stay first in overseas mode");
  assert.deepEqual(hostsOf(overseas),[AKAMAI,...cdn.OVERSEAS_HOSTS]);
  // With an ordinary address present nothing changes: it is the only donor.
  const mixed={baseUrl:akamaiUrl("akam"),backupUrl:[mediaUrl("upos-sz-mirrorcosov.bilivideo.com")]};
  const mixedMainland=cdn.representationUrls(mixed,"mainland");
  assert.equal(mixedMainland.length,8);
  assert.ok(mixedMainland.every(url=>new URL(url).searchParams.get("os")==="x"));
  assert.equal(cdn.swapOrdinaryHost(akamaiUrl("akam"),"upos-sz-mirrorali.bilivideo.com"),null);
  // A peer CDN's port must not follow the address to another node.
  assert.equal(new URL(cdn.swapOrdinaryHost("https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/a/b.m4s?e=1","upos-sz-mirrorali.bilivideo.com")).port,"");
});

test("a refused address is dropped instead of the nodes it was tried on",()=>{
  const {cdn}=load();
  const banned=[];
  const bans=cdn.createBanList({onBan:(host,_count,_error,kind)=>banned.push(kind)});
  const at=(host,os)=>akamaiUrl(os).replace(AKAMAI,host);
  // Refused before anything has delivered: nobody is blamed yet.
  bans.record(akamaiUrl("cosovbv"),0,refused);bans.record(akamaiUrl("cosovbv"),0,refused);
  assert.equal(bans.allows(akamaiUrl("cosovbv")),true);assert.deepEqual(banned,[]);
  // The same node serves the other address, so the refused address is at fault.
  bans.success(akamaiUrl("akam"));
  assert.equal(bans.allowsAddress(akamaiUrl("cosovbv")),false);
  assert.equal(bans.allows(at("upos-sz-mirrorali.bilivideo.com","cosovbv")),false,"the address is dropped on every node");
  assert.equal(bans.allows(akamaiUrl("akam")),true);assert.deepEqual(Array.from(bans.hosts()),[]);assert.deepEqual(banned,["address"]);
  // A node that refuses an address other nodes serve is at fault itself.
  const lacking="upos-sz-mirrorbos.bilivideo.com";
  bans.record(at(lacking,"akam"),0,refused);assert.equal(bans.allows(at(lacking,"akam")),true);
  bans.record(at(lacking,"akam"),0,refused);
  assert.equal(bans.allowsNode(at(lacking,"akam")),false);assert.equal(bans.allowsAddress(at(lacking,"akam")),true);
  assert.deepEqual(Array.from(bans.hosts()),[lacking]);assert.deepEqual(banned,["address","node"]);
  bans.reset();
  assert.equal(bans.allows(akamaiUrl("cosovbv")),true);assert.equal(bans.allows(at(lacking,"akam")),true);
});

test("a node that delivers one address keeps being used after refusing another that other nodes serve",()=>{
  const {cdn}=load();
  const banned=[];
  const bans=cdn.createBanList({onBan:(host,_count,_error,kind)=>banned.push(kind)});
  const mirror="upos-sz-mirroraliov.bilivideo.com";
  const at=(host,os)=>akamaiUrl(os).replace(AKAMAI,host);
  // The mirror serves both addresses, akamaized.net only one of them.
  bans.success(at(mirror,"cosovbv"));bans.success(at(mirror,"akam"));bans.success(akamaiUrl("akam"));
  bans.record(akamaiUrl("cosovbv"),0,refused);bans.record(akamaiUrl("cosovbv"),0,refused);
  assert.equal(bans.allows(akamaiUrl("cosovbv")),false,"that address is not asked of that node again");
  assert.equal(bans.allows(akamaiUrl("akam")),true,"the node keeps its working address");
  assert.equal(bans.allows(at(mirror,"cosovbv")),true,"the address stays in use where it works");
  assert.deepEqual(Array.from(bans.hosts()),[]);assert.deepEqual(banned,["address"]);
  const resolver=cdn.createResolver({baseUrl:akamaiUrl("cosovbv"),backupUrl:[akamaiUrl("akam")]},()=> "overseas",bans);
  assert.ok(Array.from(resolver.urls()).includes(akamaiUrl("akam")));assert.ok(!Array.from(resolver.urls()).includes(akamaiUrl("cosovbv")));
  assert.ok(Array.from(resolver.status()).every(item=>item.state!=="banned"));
});

test("an akamaized.net-only video downloads in mainland mode and stops asking for the refused address",{timeout:60000},async()=>{
  const {cdn,idm}=load();
  const asked={cosovbv:0,akam:0};
  const nativeFetch=async(url,init)=>{
    const os=new URL(url).searchParams.get("os");asked[os]+=1;
    if(os==="cosovbv")return new Response("",{status:403});
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    return new Response(new Uint8Array(end-start+1),{status:206,headers:{"Content-Range":`bytes ${start}-${end}/8388608`}});
  };
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:8,mode:"mainland"}),nativeFetch});
  const bans=cdn.createBanList();
  const resolver=cdn.createResolver({baseUrl:akamaiUrl("cosovbv"),backupUrl:[akamaiUrl("akam")]},()=> "mainland",bans);
  const meta=await downloader.downloadRange({start:0,end:999,length:1000},resolver,{parallel:false,kind:"meta"});
  assert.equal(meta.bytes.length,1000);
  const range={start:1000,end:1000+1024*1024-1,length:1024*1024};
  assert.equal((await downloader.downloadRange(range,resolver,{parallel:true,kind:"video"})).bytes.length,range.length);
  assert.equal(bans.allowsAddress(akamaiUrl("cosovbv")),false);assert.deepEqual(Array.from(bans.hosts()),[],"no node is banned for the refused address");
  const before=asked.cosovbv;
  await downloader.downloadRange(range,resolver,{parallel:true,kind:"video"});
  assert.equal(asked.cosovbv,before,"the refused address gets no new requests");
  assert.ok(Array.from(resolver.status()).every(item=>item.state!=="banned"));
});

test("a piece with a single address survives failed replies instead of ending the video",{timeout:60000},async()=>{
  const {idm}=load();
  const only=mediaUrl("upos-sz-mirrorali.bilivideo.com");
  let requests=0;
  const nativeFetch=async(_url,init)=>{
    requests+=1;
    if(requests<=2)return new Response("",{status:503});
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    return new Response(new Uint8Array(end-start+1),{status:206,headers:{"Content-Range":`bytes ${start}-${end}/8388608`}});
  };
  const resolver={urls:()=>[only],ordered:()=>[only],rescueCandidates:()=>[only],rangeCandidates:()=>[only],allows:()=>true,success(){},failure(){}};
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:4}),nativeFetch});
  const range={start:0,end:32767,length:32768};
  const result=await downloader.downloadRange(range,resolver,{parallel:true,kind:"video"});
  assert.equal(result.bytes.length,range.length);assert.equal(requests,3);
});

test("the custom CDN mode uses only the servers picked in the settings, and only Bilibili's",()=>{
  const {core,cdn}=load();
  assert.equal(core.normalizeCdnHost(" https://CN-GDFS-CT-01-01.bilivideo.com:4483/x?y=1 "),"cn-gdfs-ct-01-01.bilivideo.com");
  for(const bad of ["example.com","bilivideo.com.example.net","https://1.2.3.4/","upos sz.bilivideo.com",""])assert.equal(core.normalizeCdnHost(bad),"",bad);
  const settings=core.normalizeSettings({mode:"custom",customHosts:["upos-sz-mirrorcos.bilivideo.com","example.com","UPOS-SZ-MIRRORCOS.bilivideo.com","cn-gdfs-ct-01-01.bilivideo.com"]});
  assert.equal(settings.mode,"custom");
  assert.deepEqual(Array.from(settings.customHosts),["upos-sz-mirrorcos.bilivideo.com","cn-gdfs-ct-01-01.bilivideo.com"]);
  assert.equal(core.normalizeSettings({mode:"somewhere"}).mode,"mainland");
  // The takeover mode: full replaces the playback core, compat only downloads for it.
  assert.equal(core.normalizeSettings({}).takeover,"full");assert.equal(core.normalizeSettings({takeover:"compat"}).takeover,"compat");assert.equal(core.normalizeSettings({takeover:"a"}).takeover,"full");
  const hostsOf=list=>Array.from(list,url=>new URL(url).hostname);
  let hosts=Array.from(settings.customHosts);
  const resolver=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorali.bilivideo.com")},()=>"custom",null,()=>hosts);
  assert.deepEqual(hostsOf(resolver.urls()),["upos-sz-mirrorcos.bilivideo.com","cn-gdfs-ct-01-01.bilivideo.com"]);
  // The first request of a video does not race Bilibili's own address either.
  assert.deepEqual(hostsOf(resolver.startupCandidates()),["upos-sz-mirrorcos.bilivideo.com","cn-gdfs-ct-01-01.bilivideo.com"]);
  // An address Bilibili handed out on one of the picked servers is kept as it is.
  const own=cdn.createResolver({baseUrl:mediaUrl("upos-sz-mirrorcos.bilivideo.com")},()=>"custom",null,()=>hosts);
  assert.deepEqual(hostsOf(own.urls()),["upos-sz-mirrorcos.bilivideo.com","cn-gdfs-ct-01-01.bilivideo.com"]);
  // With nothing picked the mainland nodes are used, and a change applies at once.
  hosts=[];
  assert.deepEqual(hostsOf(resolver.urls()),Array.from(cdn.MAINLAND_HOSTS));
  assert.equal(hostsOf(resolver.startupCandidates())[0],"upos-sz-mirrorali.bilivideo.com");
  hosts=["upos-sz-mirrorbos.bilivideo.com"];
  assert.deepEqual(hostsOf(resolver.urls()),["upos-sz-mirrorbos.bilivideo.com"]);
});

test("queued pieces move off a cooled node without extra failures and deliver ordered bytes",{timeout:5000},async()=>{
  const {cdn,idm}=load();
  const bad="upos-sz-mirrorali.bilivideo.com",good="upos-sz-mirrorhw.bilivideo.com";
  const resolver=cdn.createResolver({baseUrl:mediaUrl(bad)},()=>"custom",null,()=>[bad,good]);
  let badCalls=0,cooledCalls=0;
  const failures=[];
  const pattern=(start,length)=>Uint8Array.from({length},(_value,index)=>(start+index)%251);
  const nativeFetch=async(url,init)=>{
    const host=new URL(url).hostname;
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    const headers={"Content-Range":`bytes ${start}-${end}/524288`};
    if(host===bad){
      badCalls+=1;
      if(Array.from(resolver.status()).find(item=>item.host===bad).state==="blocked")cooledCalls+=1;
      let sent=false;
      return new Response(new ReadableStream({pull(controller){
        if(sent)controller.error(new Error("partial connection failure"));
        else{sent=true;controller.enqueue(pattern(start,1024));}
      }}),{status:206,headers});
    }
    await new Promise(resolve=>setTimeout(resolve,15));
    return new Response(pattern(start,end-start+1),{status:206,headers});
  };
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:4}),nativeFetch,
    onTransfer:event=>{if(event.phase==="error")failures.push(event);}});
  const ranges=[{start:0,end:262143,length:262144},{start:262144,end:524287,length:262144}];
  const results=await Promise.all(ranges.map(async range=>{
    let next=range.start;
    const chunks=[];
    const result=await downloader.downloadRange(range,resolver,{onOrderedChunk(bytes,piece,total){
      assert.equal(piece.start,next);assert.equal(bytes.length,piece.length);assert.equal(total,524288);
      assert.ok(bytes.every((value,index)=>value===(piece.start+index)%251));
      next+=bytes.length;chunks.push(bytes);
    }});
    assert.equal(next,range.end+1);assert.equal(result.streamed,true);
    assert.equal(chunks.reduce((total,bytes)=>total+bytes.length,0),range.length);
    return result;
  }));
  assert.equal(results.length,2);assert.ok(badCalls>0,"the initial node actually fails");
  assert.equal(cooledCalls,0,"requests waiting for a slot must recheck current health");
  assert.equal(failures.length,badCalls,"redirecting a queued request adds no failure strike");
});

test("request-time selection avoids an active copy and keeps an all-cooled fallback with 206 validation",{timeout:5000},async()=>{
  const {cdn,idm}=load();
  const hosts=["upos-sz-mirrorali.bilivideo.com","upos-sz-mirrorhw.bilivideo.com","upos-sz-mirrorbos.bilivideo.com"];
  const resolver=cdn.createResolver({baseUrl:mediaUrl(hosts[0])},()=>"custom",null,()=>hosts);
  const urls=Array.from(resolver.urls());
  resolver.success(urls[1],2e6);resolver.success(urls[2],1e6);
  resolver.failure(urls[0],dead,1024);
  assert.equal(resolver.requestUrl(urls[0]),urls[1]);
  assert.equal(resolver.requestUrl(urls[0],new Set([urls[1]])),urls[2],"a ready second node keeps copies apart");
  for(const url of urls)resolver.failure(url,dead,1024);
  assert.equal(resolver.requestUrl(urls[0]),urls[0],"all cooled nodes still allow a bounded retry");
  let calls=0;
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:4}),nativeFetch:async(_url,init)=>{
    calls+=1;
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    const bytes=new Uint8Array(end-start+1).fill(calls===1?99:7);
    return new Response(bytes,{status:calls===1?200:206,headers:{"Content-Range":`bytes ${start}-${end}/8388608`}});
  }});
  const result=await downloader.downloadRange({start:0,end:32767,length:32768},resolver);
  assert.ok(calls>=2,"HTTP 200 is rejected even with matching Range headers");
  assert.ok(result.bytes.every(value=>value===7),"only verified 206 bytes are delivered");
});

test("cancelling queued pieces sends no queued requests and releases their slots",{timeout:5000},async()=>{
  const {cdn,idm}=load();
  const host="upos-sz-mirrorali.bilivideo.com";
  const resolver=cdn.createResolver({baseUrl:mediaUrl(host)},()=>"custom",null,()=>[host]);
  const controller=new AbortController();
  let calls=0,park=true,reachedFour;
  const started=new Promise(resolve=>{reachedFour=resolve;});
  const downloader=idm.createDownloader({getSettings:()=>({concurrency:4}),nativeFetch:async(_url,init)=>{
    calls+=1;if(calls===4)reachedFour();
    if(park)return new Promise((_resolve,reject)=>{
      if(init.signal.aborted)reject(init.signal.reason);
      else init.signal.addEventListener("abort",()=>reject(init.signal.reason),{once:true});
    });
    const [,start,end]=/bytes=(\d+)-(\d+)/.exec(init.headers.Range).map(Number);
    return new Response(new Uint8Array(end-start+1),{status:206,headers:{"Content-Range":`bytes ${start}-${end}/524288`}});
  }});
  const ranges=[{start:0,end:262143,length:262144},{start:262144,end:524287,length:262144}];
  const pending=Promise.allSettled(ranges.map(range=>downloader.downloadRange(range,resolver,{signal:controller.signal})));
  await started;controller.abort(new DOMException("cancel queued media","AbortError"));
  const settled=await pending;
  assert.equal(calls,4,"the second range stays in the queue until cancelled");
  assert.ok(settled.every(item=>item.status==="rejected"&&item.reason.name==="AbortError"));
  assert.equal(resolver.status()[0].state,"untested","cancellation adds no cooldown");
  park=false;
  const result=await downloader.downloadRange({start:0,end:32767,length:32768},resolver);
  assert.equal(result.bytes.length,32768,"the same downloader can acquire slots again");
});

test("a seek during startup schedules a fresh followup and ignores cancelled generation callbacks",async()=>{
  const {context}=load();
  const source=fs.readFileSync(path.join(SOURCE,"native-mse-player.js"),"utf8");
  // Run the real scheduling functions without starting a browser or recreating its UI.
  const extract=(start,end)=>{
    const from=source.indexOf(start),to=source.indexOf(end,from);
    assert.ok(from>=0&&to>from);return source.slice(from,to);
  };
  const candidate={generation:1,generationController:new AbortController(),startTime:0,
    playbackActivated:false,resumeWanted:false,startupPrefetchLaunched:false,startupProfiled:false,
    startupCompletedBytes:0,startupStartedAt:0,startupTargetSeconds:6,quotaWaits:0,
    mediaSource:{duration:60,readyState:"open"},tracks:[]};
  const segments=Array.from({length:12},(_item,index)=>({startTime:index*5,endTime:(index+1)*5,length:262144}));
  candidate.tracks=["video","audio"].map(kind=>({kind,sidx:{segments},sourceBuffer:{abort(){}},
    startupIndex:0,nextIndex:0,started:false,complete:false,startupComplete:false,
    startupScheduled:false,followupScheduled:false,prefetches:new Map(),operation:Promise.resolve()}));
  const requests=[],loops=[];
  Object.assign(context,{STARTUP_RECOVERY_SECONDS:6,video:{currentTime:0,paused:true,pause(){this.paused=true;}},
    downloaderFactory:{autoConcurrency:{newSession(){}}},sidxTools:{segmentIndexAt:(_segments,time)=>Math.floor(time/5)},
    sessionIsCurrent:value=>value===candidate,openGeneration:value=>{value.generation+=1;value.generationController=new AbortController();},
    aheadTarget:()=>45,bufferedEndAt:(_buffer,time)=>time,
    queuedSourceOperation:(_candidate,_track,operation)=>Promise.resolve(operation()),removeRange:()=>Promise.resolve(),
    wantsToPlay:()=>candidate.resumeWanted,append:()=>Promise.resolve(),updateStartupProfile:()=>6,
    note(){},publishState(){},maybeEndStream(){},options:{onSegment(){}},fatal:(_candidate,error)=>{throw error;},
    segmentDownload(value,track,segment,index,downloadOptions={}){
      let complete;
      const promise=new Promise(resolve=>{complete=resolve;});
      const signal=value.generationController.signal;
      signal.addEventListener("abort",()=>complete({index,error:signal.reason}),{once:true});
      requests.push({generation:value.generation,kind:track.kind,index,options:downloadOptions,
        complete:()=>complete({index,result:{byteLength:segment.length,pieceCount:4,streamed:!!downloadOptions.onOrderedChunk,bytes:new Uint8Array(0)}})});
      return promise;
    }});
  vm.runInContext(extract("    function generationSignal(","    function segmentDownload(")
    +extract("    function maybeStartStartupPrefetch(","    // How far ahead")
    +extract("    async function fillTrack(","    function maybeEndStream(")
    +extract("    async function seekWithinSession(","    async function seek("),context);
  context.ensureBuffer=value=>{for(const track of value.tracks)loops.push(context.fillTrack(value,track));};
  const settle=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
  try{
    context.ensureBuffer(candidate);
    const old=requests.filter(request=>request.generation===1&&request.index===0);
    for(const request of old)request.options.onStartupScheduled();
    assert.equal(candidate.startupPrefetchLaunched,true,"old generation already prefetched");
    old.find(request=>request.kind==="audio").complete();await settle();
    assert.equal(candidate.tracks[1].startupComplete,true);
    assert.equal(candidate.tracks[0].startupComplete,false,"video head is still in flight");
    context.video.currentTime=20;
    await context.seekWithinSession(candidate,20);
    const fresh=requests.filter(request=>request.generation===2&&request.index===4);
    assert.equal(fresh.length,2);
    assert.ok(fresh.every(request=>request.options.startup),"both tracks must restart their startup phase");
    assert.equal(candidate.startupPrefetchLaunched,false,"new generation cannot inherit old prefetch success");
    old[0].options.onStartupScheduled();
    assert.ok(candidate.tracks.every(track=>!track.startupScheduled),"cancelled callbacks cannot mark the new generation");
    for(const request of fresh)request.options.onStartupScheduled();
    assert.equal(requests.filter(request=>request.generation===2&&request.index===5).length,2,"new followups start before the large video segment finishes");
    assert.equal(candidate.resumeWanted,false,"prefetch does not override the viewer's pause intent");
    assert.equal(context.video.paused,true);
    assert.equal(candidate.startupCompletedBytes,0);
    candidate.playbackActivated=true;candidate.resumeWanted=true;candidate.startupPrefetchLaunched=true;
    for(const track of candidate.tracks)track.startupComplete=true;
    context.video.currentTime=40;await context.seekWithinSession(candidate,40);
    assert.equal(candidate.recovering,true,"a normal activated seek retains its recovery path");
    assert.equal(candidate.recoveryTargetSeconds,6);
    assert.equal(candidate.startupPrefetchLaunched,true,"activated seeks do not reset initial startup profiling");
  }finally{
    candidate.generationController.abort(new DOMException("fixture cleanup","AbortError"));
    await Promise.allSettled(loops);
  }
});

test("a buffer gap does not admit far-future writes, including held ranges, but nearby media still fills",async()=>{
  const {context}=load();
  const source=fs.readFileSync(path.join(SOURCE,"native-mse-player.js"),"utf8");
  const extract=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
  const segments=Array.from({length:110},(_item,index)=>({startTime:index*5,endTime:(index+1)*5,length:262144}));
  let ranges=[[347,360],[360.07,400]],current=352;
  const sourceBuffer={buffered:{get length(){return ranges.length;},start:index=>ranges[index][0],end:index=>ranges[index][1]}};
  const track={kind:"video",sourceBuffer,sidx:{segments},nextIndex:80,startupIndex:0,
    started:true,complete:false,startupComplete:true,prefetches:new Map(),operation:Promise.resolve()};
  const candidate={generation:1,generationController:new AbortController(),startTime:352,tracks:[track]};
  const requests=[],writes=[];
  Object.assign(context,{video:{get currentTime(){return current;}},
    sessionIsCurrent:value=>value===candidate,aheadTarget:()=>45,updateStartupProfile:()=>6,
    note(){},options:{onSegment(){}},ensureBuffer(){},maybeEndStream(){},fatal:(_candidate,error)=>{throw error;},
    segmentDownload(_candidate,_track,_segment,index){requests.push(index);return Promise.resolve({index,
      result:{bytes:new Uint8Array([index]),byteLength:262144,pieceCount:1,streamed:false}});},
    append:async(_candidate,_track,bytes)=>{
      const index=bytes[0];writes.push(index);
      const entries=[...ranges,[segments[index].startTime,segments[index].endTime]].sort((a,b)=>a[0]-b[0]);
      ranges=[];for(const entry of entries){const last=ranges.at(-1);if(last&&last[1]>=entry[0])last[1]=Math.max(last[1],entry[1]);else ranges.push(entry.slice());}
    }});
  vm.runInContext(extract("  function bufferedEndAt(","  function bufferedStart(")
    +extract("    function generationSignal(","    function segmentDownload(")
    +extract("    async function fillTrack(","    function maybeEndStream("),context);
  assert.equal(context.bufferedEndAt(sourceBuffer,current),360,"playback sees only the continuous range, not data beyond the gap");
  await context.fillTrack(candidate,track);
  assert.equal(writes.length,0,"next segment at 400 s is outside the 45 s window from 352 s");
  assert.equal(requests.length,0,"no additional far-future bytes are requested");
  track.held={index:80,result:{bytes:new Uint8Array([80]),byteLength:262144,pieceCount:1,streamed:false}};
  await context.fillTrack(candidate,track);
  assert.equal(writes.length,0,"a previously held future range also waits for playback to approach");
  assert.ok(track.held);
  current=390;await context.fillTrack(candidate,track);
  assert.equal(writes[0],80,"the held range is appended naturally after playback advances");
  assert.equal(track.held,null);
  assert.ok(requests.every(index=>segments[index].startTime-current<45));
  ranges=[];current=352;track.nextIndex=70;track.complete=false;track.prefetches.clear();
  requests.length=0;writes.length=0;
  await context.fillTrack(candidate,track);
  assert.equal(writes[0],70,"a nearby segment containing the playhead is still downloaded and appended");
  assert.ok(requests.length>0);
});
