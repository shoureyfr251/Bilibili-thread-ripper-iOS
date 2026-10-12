/* Loads after range-core, before cdn-resolver/idm-downloader (they capture the core object).
 * 1. Always: settings the desktop normalizer fixes but the phone's long-RTT path needs differently.
 *    iosMinChunkBytes raises the piece-size floor: the desktop sizes pieces from connection speed
 *    alone (0.6 s worth); at ~250 KB/s and 0.4-2 s first byte that is ~128 KB pieces spending
 *    most of their time waiting (v13 device: 10747 transfers, ~25 Mbit/s ceiling).
 * 2. Self-test contexts (__BTR_TEST_HOSTS__): accept the fault-injection origins as media URLs
 *    and disable mirror substitution, so a test URL is never rewritten onto a real CDN.
 */
(function installPrelude(root) {
  'use strict';
  const base = root.__BILI_RANGE_CORE__;
  if (!base) return;
  const tuned = {
    ...base,
    normalizeSettings(input) {
      const settings = base.normalizeSettings(input);
      const floor = Math.trunc(Number(input?.iosMinChunkBytes));
      if (floor >= 32 * 1024 && floor <= 4 * 1024 * 1024) settings.minChunkBytes = floor;
      return settings;
    }
  };
  if (Array.isArray(root.__BTR_TEST_HOSTS__)) {
    const hosts = new Set(root.__BTR_TEST_HOSTS__.map(host => String(host).toLowerCase()));
    tuned.isBilibiliMediaUrl = value => {
      try {
        const url = new URL(value);
        return hosts.has(url.hostname) && url.protocol === 'http:' && /\.(?:m4s|mp4|flv)$/i.test(url.pathname);
      } catch (_error) { return false; }
    };
    tuned.normalizeCdnHost = () => '';
  }
  root.__BILI_RANGE_CORE__ = Object.freeze(tuned);
})(globalThis);