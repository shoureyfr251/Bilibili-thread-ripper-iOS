/* Metadata-only HTTP/Range policy shared by JavaScriptCore and the local test host. */
(function (root) {
  'use strict';
  const WINDOW = 1024 * 1024;
  function integer(text) {
    if (!/^\d{1,16}$/.test(text)) return null;
    const value = Number(text);
    return Number.isSafeInteger(value) && value >= 0 ? value : null;
  }
  function parseRequest(raw, host) {
    if (typeof raw !== 'string' || raw.length > 8192 || /[^\x09\x0a\x0d\x20-\x7e]/.test(raw)
        || !raw.endsWith('\r\n\r\n')) return {error: 400};
    const lines = raw.slice(0, -4).split('\r\n');
    const first = /^(GET|HEAD) (\/[A-Za-z0-9./_-]{1,256}) HTTP\/(1\.[01])$/.exec(lines.shift());
    if (!first) return {error: 400};
    const headers = Object.create(null);
    for (const line of lines) {
      const found = /^([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*([^\r\n]*)$/.exec(line);
      if (!found) return {error: 400};
      const name = found[1].toLowerCase();
      if (!['host', 'range', 'content-length', 'transfer-encoding'].includes(name)) continue;
      if (name in headers) return {error: 400};
      headers[name] = found[2].trim();
    }
    if ((first[3] === '1.1' && !headers.host) || (headers.host && headers.host !== host)
        || headers['transfer-encoding'] || (headers['content-length'] && headers['content-length'] !== '0')) return {error: 400};
    let range = null;
    if (headers.range && first[1] === 'GET') {
      const match = /^bytes=(\d*)-(\d*)$/i.exec(headers.range);
      if (!match || (!match[1] && !match[2])) return {fallback: true, path: first[2], method: first[1]};
      const start = match[1] ? integer(match[1]) : null;
      const end = match[2] ? integer(match[2]) : null;
      if ((match[1] && start === null) || (match[2] && end === null)) return {error: 400};
      range = {start, end, suffix: !match[1]};
    }
    return {method: first[1], path: first[2], range};
  }
  function resolve(request, total) {
    if (!Number.isSafeInteger(total) || total <= 0) return {fallback: true};
    let start = 0, end = total - 1, status = 200;
    if (request.range && request.method === 'GET') {
      status = 206;
      if (request.range.suffix) {
        if (request.range.end === 0) return {error: 416, total};
        start = Math.max(0, total - request.range.end);
      } else {
        start = request.range.start;
        if (start >= total || (request.range.end !== null && request.range.end < start)) return {error: 416, total};
        end = request.range.end === null ? total - 1 : Math.min(request.range.end, total - 1);
      }
    }
    return {status, start, end, total, length: end - start + 1, head: request.method === 'HEAD'};
  }
  root.BTRLoopbackHTTP = Object.freeze({parseRequest, resolve, WINDOW});
})(globalThis);
