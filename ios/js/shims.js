/* Browser APIs the desktop downloader needs, for a bare JavaScriptCore context.
 * Native host object `btrNative` supplies only primitives:
 *   now() -> ms, setTimer(id, ms), clearTimer(id),
 *   httpStart(id, url, headers), httpCancel(id)
 * and calls back __btrFireTimer(id), __btrHttpResponse(id, status, headers),
 * __btrHttpData(id, Uint8Array), __btrHttpEnd(id, errorMessageOrNull).
 * The same file runs under Node's vm (ios/dev/engine-test.mjs) with a Node-backed host.
 */
(function installShims(root) {
  'use strict';
  const N = root.btrNative;

  if (!root.performance) root.performance = Object.freeze({ now: () => N.now() });

  const timers = new Map();
  let timerSeq = 0;
  root.setTimeout = function setTimeout(fn, ms, ...args) {
    const id = ++timerSeq;
    timers.set(id, () => fn(...args));
    N.setTimer(id, Math.max(0, Number(ms) || 0));
    return id;
  };
  root.clearTimeout = function clearTimeout(id) { if (timers.delete(id)) N.clearTimer(id); };
  root.__btrFireTimer = function fire(id) {
    const fn = timers.get(id);
    if (!fn) return;
    timers.delete(id);
    try { fn(); } catch (error) { root.__btrUncaught?.(error); }
  };

  class DOMException extends Error {
    constructor(message = '', name = 'Error') { super(message); this.name = name; }
  }
  root.DOMException = DOMException;

  class AbortSignal {
    constructor() { this.aborted = false; this.reason = undefined; this.onabort = null; this._listeners = []; }
    addEventListener(type, fn) { if (type === 'abort' && typeof fn === 'function' && !this.aborted) this._listeners.push(fn); }
    removeEventListener(type, fn) { this._listeners = this._listeners.filter(item => item !== fn); }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    _abort(reason) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason === undefined ? new DOMException('This operation was aborted', 'AbortError') : reason;
      // Every listener runs once: an aborted signal never fires again.
      const listeners = this._listeners; this._listeners = [];
      const event = { type: 'abort', target: this };
      if (typeof this.onabort === 'function') { try { this.onabort(event); } catch (_error) {} }
      for (const fn of listeners) { try { fn.call(this, event); } catch (_error) {} }
    }
  }
  class AbortController {
    constructor() { this.signal = new AbortSignal(); }
    abort(reason) { this.signal._abort(reason); }
  }
  root.AbortSignal = AbortSignal;
  root.AbortController = AbortController;

  // Absolute URLs only; the signed query is kept byte for byte (never re-encoded).
  const DEFAULT_PORT = { 'http:': '80', 'https:': '443' };
  class URL {
    constructor(input, _base) {
      const match = /^([a-zA-Z][a-zA-Z\d+.-]*):\/\/(?:([^:@/?#]*)(?::([^@/?#]*))?@)?([^:/?#]*)(?::(\d*))?([^?#]*)(\?[^#]*)?(#.*)?$/
        .exec(String(input).trim());
      if (!match || !match[4] || /[\s<>^`{|}%\\]/.test(match[4])) throw new TypeError('Invalid URL');
      this._protocol = match[1].toLowerCase() + ':';
      this._username = match[2] || ''; this._password = match[3] || '';
      this._hostname = match[4].toLowerCase();
      this._port = match[5] && match[5] !== DEFAULT_PORT[this._protocol] ? String(Number(match[5])) : '';
      this._pathname = match[6] || '/';
      this._search = match[7] && match[7] !== '?' ? match[7] : '';
      this._hash = match[8] && match[8] !== '#' ? match[8] : '';
    }
    get protocol() { return this._protocol; }
    get username() { return this._username; }
    get password() { return this._password; }
    get hostname() { return this._hostname; }
    set hostname(value) {
      const text = String(value).toLowerCase();
      if (text && !/[\s:/?#@<>^`{|}%\\]/.test(text)) this._hostname = text;
    }
    get port() { return this._port; }
    set port(value) {
      const text = String(value);
      if (text === '' || text === DEFAULT_PORT[this._protocol]) this._port = '';
      else if (/^\d{1,5}$/.test(text) && Number(text) <= 65535) this._port = String(Number(text));
    }
    get host() { return this._port ? `${this._hostname}:${this._port}` : this._hostname; }
    get pathname() { return this._pathname; }
    get search() { return this._search; }
    get hash() { return this._hash; }
    get origin() { return `${this._protocol}//${this.host}`; }
    get href() {
      const auth = this._username || this._password ? `${this._username}${this._password ? ':' + this._password : ''}@` : '';
      return `${this._protocol}//${auth}${this.host}${this._pathname}${this._search}${this._hash}`;
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
  }
  if (typeof root.URL !== 'function') root.URL = URL;
  root.__BTRURL__ = URL;

  // fetch over the native streaming primitives: Response with headers.get and a body reader.
  const requests = new Map();
  let requestSeq = 0;
  function settleReaders(state) {
    while (state.waiters.length && (state.queue.length || state.done || state.error)) {
      const waiter = state.waiters.shift();
      if (state.queue.length) waiter.resolve({ done: false, value: state.queue.shift() });
      else if (state.error) waiter.reject(state.error);
      else waiter.resolve({ done: true, value: undefined });
    }
  }
  function finish(id, error) {
    const state = requests.get(id);
    if (!state) return;
    requests.delete(id);
    state.signal?.removeEventListener('abort', state.onAbort);
    if (error) { state.error = error; state.queue.length = 0; } else state.done = true;
    if (!state.response) { if (error) state.reject(error); else state.reject(new TypeError('Network request failed')); }
    settleReaders(state);
  }
  root.fetch = function fetch(input, init = {}) {
    return new Promise((resolve, reject) => {
      const signal = init.signal;
      if (signal?.aborted) { reject(signal.reason); return; }
      const id = ++requestSeq;
      const state = { resolve, reject, signal, queue: [], waiters: [], done: false, error: null, response: null };
      state.onAbort = () => { if (requests.has(id)) { N.httpCancel(id); finish(id, signal.reason); } };
      requests.set(id, state);
      signal?.addEventListener('abort', state.onAbort);
      const headers = {};
      for (const [name, value] of Object.entries(init.headers || {})) headers[name] = String(value);
      N.httpStart(id, String(input), headers);
    });
  };
  root.__btrHttpResponse = function onResponse(id, status, headers) {
    const state = requests.get(id);
    if (!state || state.response) return;
    const table = new Map(Object.entries(headers || {}).map(([name, value]) => [name.toLowerCase(), String(value)]));
    const reader = {
      read: () => new Promise((resolve, reject) => { state.waiters.push({ resolve, reject }); settleReaders(state); }),
      cancel: () => { if (requests.has(id)) { N.httpCancel(id); finish(id, new DOMException('Reader cancelled', 'AbortError')); } return Promise.resolve(); },
      releaseLock: () => {}
    };
    state.response = {
      status, ok: status >= 200 && status < 300,
      headers: { get: name => table.get(String(name).toLowerCase()) ?? null, has: name => table.has(String(name).toLowerCase()) },
      body: { getReader: () => reader },
      async arrayBuffer() {
        const parts = []; let length = 0;
        for (;;) { const { done, value } = await reader.read(); if (done) break; parts.push(value); length += value.byteLength; }
        const out = new Uint8Array(length); let offset = 0;
        for (const part of parts) { out.set(part, offset); offset += part.byteLength; }
        return out.buffer;
      }
    };
    state.resolve(state.response);
  };
  root.__btrHttpData = function onData(id, chunk) {
    const state = requests.get(id);
    if (!state || !chunk || !chunk.byteLength) return;
    state.queue.push(chunk);
    settleReaders(state);
  };
  root.__btrHttpEnd = function onEnd(id, message) {
    finish(id, message ? new TypeError(String(message)) : null);
  };
  root.__btrShimStats = () => ({ timers: timers.size, requests: requests.size });
})(globalThis);
