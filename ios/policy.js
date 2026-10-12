/* Metadata-only policy for JavaScriptCore. range-core.js must be loaded first.
 * Host must supply btrDescribeURL(string) -> {scheme, host, path, hasCredentials}.
 * All URLs are supplied by the caller for ONE representation; signed strings are
 * retained byte-for-byte. No fetch, URL, timer, AbortController or binary payload.
 */
(function (root) {
  'use strict';
  const core = root.__BILI_RANGE_CORE__;
  const hosts = /(?:^|\.)(?:bilivideo\.(?:com|cn|net)|akamaized\.net|szbdyd\.com|hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$/i;
  const MAX_BYTES = 8 * 1024 * 1024;
  function mediaURL(raw, allowHTTP = false, allowTestHost = false) {
    if (typeof raw !== 'string' || raw.length > 16384) throw new Error('Invalid media URL');
    const info = root.btrDescribeURL(raw);
    // Self-test only: the in-process fault-injection origin on plain loopback HTTP.
    const test = !!info && allowTestHost === true && info.host === '127.0.0.1' && info.scheme === 'http';
    if (!info || (!test && ((info.scheme !== 'https' && !(allowHTTP && info.scheme === 'http')) || !hosts.test(info.host)))
        || info.hasCredentials || !/\.(?:m4s|mp4|flv)$/i.test(info.path)) throw new Error('Unsupported media URL');
    return raw;
  }
  function plan(input) {
    const range = core.parseByteRange(String(input.start) + '-' + String(input.end));
    if (!range || range.length > MAX_BYTES || range.end >= Number.MAX_SAFE_INTEGER)
      throw new Error('Range must be finite and at most 8 MiB');
    if (!Array.isArray(input.urls) || !input.urls.length || input.urls.length > 8)
      throw new Error('Provide 1 to 8 URLs for the same media representation');
    const urls = input.urls.map(url => mediaURL(url, input.allowHTTP === true, input.allowTestHost === true)).filter((url, i, all) => all.indexOf(url) === i);
    const concurrency = Math.max(1, Math.min(8, Math.trunc(Number(input.concurrency)) || 4));
    return {range, urls, concurrency, pieces: core.splitRange(range.start, range.end, concurrency, 64 * 1024)};
  }
  class Job {
    constructor(input) {
      this.plan = plan(input);
      this.parts = this.plan.pieces.map(piece => ({piece, attempt: 0, state: 'pending'}));
      this.active = new Map(); this.sequence = 0; this.total = null;
      this.state = 'running'; this.error = null;
    }
    next() {
      if (this.state !== 'running') return [];
      const output = [];
      for (const part of this.parts) {
        if (this.active.size >= this.plan.concurrency) break;
        if (part.state !== 'pending') continue;
        const request = {id: ++this.sequence, index: part.piece.index,
          url: this.plan.urls[(part.piece.index + part.attempt) % this.plan.urls.length],
          start: part.piece.start, end: part.piece.end, length: part.piece.length};
        part.state = 'active'; this.active.set(request.id, {part, request, headers: false});
        output.push(request);
      }
      return output;
    }
    headers(id, status, contentRange, encoding) {
      const entry = this.active.get(id);
      if (this.state !== 'running' || !entry) return false;
      const range = core.parseContentRange(contentRange);
      if (status !== 206 || !range || range.total === null
          || range.start !== entry.request.start || range.end !== entry.request.end
          || (encoding && encoding.toLowerCase() !== 'identity')
          || (this.total !== null && range.total !== this.total)) return false;
      this.total = range.total; entry.headers = true; return true;
    }
    finish(id, length) {
      const entry = this.active.get(id);
      if (this.state !== 'running' || !entry) return false;
      if (!entry.headers || length !== entry.request.length) return false;
      this.active.delete(id); entry.part.state = 'done';
      if (this.parts.every(part => part.state === 'done')) this.state = 'done';
      return true;
    }
    fail(id, reason) {
      const entry = this.active.get(id);
      if (this.state !== 'running' || !entry) return false;
      this.active.delete(id); entry.part.attempt += 1;
      // Stalled/reset pieces are reissued (rotating hosts): each host twice, at least 4 tries.
      if (entry.part.attempt >= Math.max(4, this.plan.urls.length * 2)) {
        this.state = 'failed'; this.error = String(reason || 'All candidates failed');
      } else entry.part.state = 'pending';
      return true;
    }
    cancel() {
      if (this.state !== 'running') return [];
      const ids = Array.from(this.active.keys());
      this.active.clear(); this.state = 'cancelled'; this.error = 'Cancelled'; return ids;
    }
    snapshot() { return {state: this.state, error: this.error, total: this.total,
      length: this.plan.range.length, completed: this.parts.filter(part => part.state === 'done').length,
      pieces: this.parts.length, active: this.active.size}; }
  }
  root.BTRPolicy = Object.freeze({Job, plan, MAX_BYTES});
})(globalThis);
