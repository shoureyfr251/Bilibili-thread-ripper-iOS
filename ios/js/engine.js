/* iOS glue for the unmodified desktop downloader (range-core, cdn-resolver, idm-downloader).
 * Load order: range-core, shims, engine-prelude, cdn-resolver, idm-downloader, engine.
 * Native calls BTREngine.download/cancel; results return via btrNative.jobDone(id, bytes, total, error, hosts).
 * Mirrors native-range-transport.js: one shared downloader (thread budget, auto threads,
 * hedging, node health), one resolver per file whose candidates are the player's own URLs
 * plus the desktop mirror-host list.
 */
(function installEngine(root) {
  'use strict';
  const N = root.btrNative;
  const core = root.__BILI_RANGE_CORE__;
  const resolvers = root.__BILI_CDN_RESOLVER_FACTORY__;
  const factory = root.__BILI_IDM_DOWNLOADER_FACTORY__;
  const testing = Array.isArray(root.__BTR_TEST_HOSTS__);

  const counters = { jobs: 0, done: 0, failed: 0, cancelled: 0, bytes: 0, transfers: 0, transferErrors: 0, hostsUsedMax: 0 };
  const errorKinds = {};
  // Per host: transfers that finished, failed (by kind/code) or were cancelled. No URLs.
  const hostStats = new Map();
  const transferHosts = new Map();
  let transferSeq = 0;
  function hostEntry(host) {
    let entry = hostStats.get(host);
    if (!entry) { entry = { host, started: 0, done: 0, cancelled: 0, failed: 0, errors: {} }; hostStats.set(host, entry); }
    return entry;
  }
  // Fixed 32 threads: on the bench auto threads stayed at 8 (~1/3 the throughput).
  // Every mirror (8 mainland + 4 overseas) in the custom list; the resolver's speed ranking picks.
  // v12 on the phone: overseas nodes 0.3-0.6 Mbit/s each, mainland 1.4-3 (the player's own host
  // was overseas, so guessing the mode from it chose the slow set).
  // v13 device: mainland mirrors fastest twice (25.6 vs 8.2 Mbit/s with all 12; the overseas
  // nodes at 0.1-0.8 Mbit/s become stragglers). 512 KiB piece floor: see engine-prelude.js.
  // 64 threads (desktop accepts 4/8/16/32/64/128 only): latency-bound bench 42 -> 82 Mbit/s.
  let settings = { mode: 'mainland', concurrency: 64, autoConcurrency: false, iosMinChunkBytes: 512 * 1024 };
  // Fetch over plain http (HTTP/1.1, many connections per host). Over https NSURLSession uses
  // HTTP/2 and folds every request to a host into one connection. The player itself uses http.
  let scheme = 'http';
  // akamai (v15 device: the player's own akamai address, app UA, 4 connections ~22 Mbit/s) joins the
  // mainland mirrors. Its token only fits its own query, so any akamai request is sent with the
  // player's akamai address for that file; without one it is refused for that address only.
  let useAkamai = true;
  const akamaiByAddress = new Map();
  const isAkamai = host => /(?:^|\.)akamaized\.net$/i.test(host);
  function refused() {
    return Promise.resolve({ status: 403, ok: false, headers: { get: () => null, has: () => false }, body: null });
  }
  let modeLocked = false;
  // Release profiles. overseas (default, v15/v16 device data): mainland mirrors + akamai, 64 threads.
  // domestic (users in mainland China, not measured on a device): the player's own mainland hosts
  // plus the mainland mirrors, 32 threads, no akamai.
  const PROFILES = {
    overseas: { concurrency: 64, akamai: true },
    domestic: { concurrency: 32, akamai: false }
  };
  let profile = 'overseas';
  const bans = resolvers.createBanList({ limit: 2 });
  const headersByAddress = new Map();

  function addressOf(url) {
    try { const parsed = new URL(url); return parsed.pathname; } catch (_error) { return ''; }
  }
  // The player's addresses are often http; the desktop policy (and the mirror swap) is https.
  // The signature does not cover the scheme. Test origins stay as they are.
  function secure(url) {
    return testing ? String(url) : String(url).replace(/^http:\/\//i, 'https://');
  }
  function nativeFetch(url, init) {
    const extra = headersByAddress.get(addressOf(url)) || {};
    let target = url;
    if (!testing && useAkamai) {
      let host = '';
      try { host = new URL(url).hostname; } catch (_error) {}
      if (isAkamai(host)) {
        const own = akamaiByAddress.get(addressOf(url));
        if (!own) return refused();
        target = own;
      }
    }
    const wire = !testing && scheme === 'http' ? String(target).replace(/^https:\/\//i, 'http://') : target;
    return root.fetch(wire, { ...init, headers: { ...extra, ...(init && init.headers) } });
  }
  const downloader = factory.createDownloader({
    getSettings: () => settings,
    nativeFetch,
    onTransfer(event) {
      if (event.phase === 'start') {
        counters.transfers += 1;
        let host = '';
        try { host = new URL(event.url).hostname; } catch (_error) {}
        const id = ++transferSeq;
        if (transferHosts.size > 4096) transferHosts.clear();
        transferHosts.set(id, host); hostEntry(host).started += 1;
        return id;
      }
      const host = transferHosts.get(event.id);
      if (event.phase === 'progress' || host === undefined) return null;
      transferHosts.delete(event.id);
      const entry = hostEntry(host);
      if (event.phase === 'done') entry.done += 1;
      else if (event.phase === 'cancel') entry.cancelled += 1;
      else if (event.phase === 'error') {
        counters.transferErrors += 1; entry.failed += 1;
        const error = event.error;
        const kind = String(error?.status ? `http_${error.status}` : error?.name || 'error').slice(0, 40);
        errorKinds[kind] = (errorKinds[kind] || 0) + 1;
        // NSURLError codes arrive as 'NSURLError -1005'; keep the code, never a URL.
        const code = /NSURLError (-?\d+)/.exec(String(error?.message || ''))?.[1];
        const detail = code ? `nsurl_${code}` : kind;
        entry.errors[detail] = (entry.errors[detail] || 0) + 1;
      }
      return null;
    }
  });

  // A file is its path; a new signature or host set for it replaces the resolver but keeps bans.
  const resolverCache = new Map();
  function resolverFor(raw, alternates) {
    const base = secure(raw);
    const backups = (alternates || []).map(secure).filter(url => url !== base);
    const key = addressOf(base);
    const signature = [base, ...backups].join('\n');
    const cached = resolverCache.get(key);
    if (cached && cached.signature === signature) return cached.resolver;
    if (resolverCache.size > 32) resolverCache.clear();
    const resolver = resolvers.createResolver({ baseUrl: base, backupUrl: backups },
      () => settings.mode, bans, () => settings.customHosts || []);
    resolverCache.set(key, { signature, resolver });
    return resolver;
  }
  function chooseMode(raw, alternates) {
    if (testing) { if (!modeLocked) settings = { ...settings, mode: 'overseas' }; return; } // test hosts only, no mirrors
    const akamaiHosts = [];
    if (useAkamai) for (const url of [raw, ...(alternates || [])]) {
      let host = '';
      try { host = new URL(url).hostname; } catch (_error) {}
      if (!isAkamai(host)) continue;
      akamaiByAddress.set(addressOf(secure(url)), String(url));
      if (!akamaiHosts.includes(host)) akamaiHosts.push(host);
    }
    if (akamaiByAddress.size > 64) akamaiByAddress.clear();
    if (modeLocked) return;
    if (profile === 'domestic') {
      const own = [];
      for (const url of [raw, ...(alternates || [])]) {
        let host = '';
        try { host = new URL(url).hostname.toLowerCase(); } catch (_error) {}
        if (host && !isAkamai(host) && !own.includes(host)) own.push(host);
      }
      const hosts = [...own, ...resolvers.MAINLAND_HOSTS].filter((host, index, all) => all.indexOf(host) === index).slice(0, 16);
      settings = { ...settings, mode: 'custom', customHosts: hosts };
      return;
    }
    // Mainland mirrors plus the akamai host as an extra node; without akamai: plain mainland (v15).
    const known = settings.mode === 'custom' ? (settings.customHosts || []) : [];
    const extra = akamaiHosts.filter(host => !known.includes(host));
    if (extra.length) settings = { ...settings, mode: 'custom',
      customHosts: [...resolvers.MAINLAND_HOSTS, ...known.filter(host => isAkamai(host)), ...extra].slice(0, 16) };
  }

  const jobs = new Map();
  root.BTREngine = Object.freeze({
    configure(options) {
      const next = { ...settings };
      if (PROFILES[options?.profile]) {
        profile = options.profile;
        next.concurrency = PROFILES[profile].concurrency;
        useAkamai = PROFILES[profile].akamai;
        next.mode = 'mainland'; delete next.customHosts; // chooseMode rebuilds the node list per file
      }
      if (['mainland', 'overseas', 'custom'].includes(options?.mode)) { next.mode = options.mode; modeLocked = true; }
      if (options?.mode === 'all') { next.mode = 'custom'; next.customHosts = [...resolvers.GLOBAL_HOSTS]; modeLocked = true; }
      if (['http', 'https'].includes(options?.scheme)) scheme = options.scheme;
      if (typeof options?.akamai === 'boolean') useAkamai = options.akamai;
      if (Number(options?.minChunkKiB) >= 32) next.iosMinChunkBytes = Math.trunc(Number(options.minChunkKiB)) * 1024;
      if (Number.isFinite(Number(options?.concurrency))) next.concurrency = Number(options.concurrency);
      if (typeof options?.autoConcurrency === 'boolean') next.autoConcurrency = options.autoConcurrency;
      settings = next;
      downloader.applySettings();
    },
    // meta: a tiny range (the 0-0 length probe) raced across nodes, as for init/index on desktop.
    download(jobId, raw, alternates, headers, start, end, startup, meta) {
      counters.jobs += 1;
      chooseMode(raw, alternates);
      const resolver = resolverFor(raw, alternates);
      const clean = {};
      for (const name of ['User-Agent', 'Referer', 'Origin']) if (headers && typeof headers[name] === 'string') clean[name] = headers[name];
      for (const url of [raw, ...(alternates || [])]) headersByAddress.set(addressOf(secure(url)), clean);
      if (headersByAddress.size > 64) headersByAddress.clear();
      const controller = new AbortController();
      jobs.set(jobId, controller);
      const range = { start, end, length: end - start + 1 };
      const options = meta ? { signal: controller.signal, parallel: false, kind: 'meta' }
        : { signal: controller.signal, parallel: true, startup: !!startup, kind: 'video' };
      downloader.downloadRange(range, resolver, options)
        .then(result => {
          counters.done += 1; counters.bytes += range.length;
          counters.hostsUsedMax = Math.max(counters.hostsUsedMax, result.hosts?.length || 0);
          if (!result.bytes || result.bytes.byteLength !== range.length) throw new Error('Engine length mismatch');
          N.jobDone(jobId, result.bytes, Number.isSafeInteger(result.total) ? result.total : -1, null, result.hosts?.length || 0);
        })
        .catch(error => {
          const cancelled = controller.signal.aborted;
          counters[cancelled ? 'cancelled' : 'failed'] += 1;
          N.jobDone(jobId, null, -1, cancelled ? 'cancelled' : `${error?.name || 'Error'}: ${error?.message || error}`.slice(0, 160), 0);
        })
        .finally(() => jobs.delete(jobId));
    },
    cancel(jobId) {
      const controller = jobs.get(jobId);
      if (controller) controller.abort(new DOMException('Cancelled by loopback', 'AbortError'));
    },
    stats() {
      const nodes = [];
      for (const { resolver } of resolverCache.values()) for (const node of resolver.status()) nodes.push(node);
      const byHost = {};
      for (const node of nodes) {
        const entry = byHost[node.host] || (byHost[node.host] = { host: node.host, state: node.state, mbps: 0 });
        entry.mbps = Math.max(entry.mbps, Math.round(node.bps * 8 / 1e4) / 100);
        if (node.state === 'healthy' || entry.state === 'untested') entry.state = node.state;
      }
      return { ...counters, errorKinds: { ...errorKinds }, profile, mode: settings.mode, scheme, akamai: useAkamai, akamaiAddresses: akamaiByAddress.size, minChunkKiB: Math.round((settings.iosMinChunkBytes || 65536) / 1024), threads: downloader.getConcurrency(),
        auto: factory.autoConcurrency?.status?.() ? { threads: factory.autoConcurrency.status().threads, reason: factory.autoConcurrency.status().reason } : null,
        bannedHosts: bans.hosts(), nodes: Object.values(byHost).slice(0, 24), hostStats: [...hostStats.values()].slice(0, 24), activeJobs: jobs.size, shim: root.__btrShimStats?.() };
    }
  });
})(globalThis);
