import https from 'node:https';
import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
const blocked = new BlockList();
for (const [ip, bits] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.0.2.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['198.51.100.0', 24],
  ['203.0.113.0', 24],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
])
  blocked.addSubnet(ip, bits, 'ipv4');
for (const [ip, bits] of [
  ['::', 128],
  ['::1', 128],
  ['64:ff9b:1::', 48],
  ['100::', 64],
  ['2001:db8::', 32],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
])
  blocked.addSubnet(ip, bits, 'ipv6');
const mapped = new BlockList();
mapped.addSubnet('::ffff:0:0', 96, 'ipv6');
export function publicAddress(address) {
  const family = isIP(address);
  return (
    !!family &&
    !(family === 6 && mapped.check(address, 'ipv6')) &&
    !blocked.check(address, family === 4 ? 'ipv4' : 'ipv6')
  );
}

// Resolve once and pin that public address to the socket, including every redirect.
export async function remoteRequest(
  value,
  { headers = {}, limit = 100_000_000, redirects = false, signal, depth = 0, method = 'GET' } = {}
) {
  const url = new URL(value);
  const deadline = AbortSignal.timeout(45000);
  signal = signal ? AbortSignal.any([signal, deadline]) : deadline;
  signal.throwIfAborted();
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    (url.port && url.port !== '443') ||
    depth > 5
  )
    throw new Error('Invalid remote resource address.');
  const addresses = await lookup(url.hostname, { all: true, verbatim: true });
  signal.throwIfAborted();
  if (!addresses.length || addresses.some(({ address }) => !publicAddress(address)))
    throw new Error('Remote resources must use a public HTTPS address.');
  return new Promise((resolve, reject) => {
    const request = https.request(
      url,
      {
        method,
        headers,
        signal,
        lookup: (_name, options, callback) =>
          options.all
            ? callback(null, addresses)
            : callback(null, addresses[0].address, addresses[0].family),
      },
      (response) => {
        if (
          [301, 302, 303, 307, 308].includes(response.statusCode) &&
          response.headers.location &&
          redirects
        ) {
          response.destroy();
          remoteRequest(new URL(response.headers.location, url), {
            limit,
            redirects,
            signal,
            depth: depth + 1,
            method,
          }).then(resolve, reject);
          return;
        }
        if (Number(response.headers['content-length']) > limit) {
          response.destroy();
          reject(new Error('The file exceeds the download limit.'));
          return;
        }
        let size = 0;
        const chunks = [];
        response.on('data', (chunk) => {
          size += chunk.length;
          if (size > limit) {
            response.destroy();
            reject(new Error('The file exceeds the download limit.'));
          } else chunks.push(chunk);
        });
        response.on('end', () =>
          resolve({
            status: response.statusCode,
            headers: response.headers,
            data: Buffer.concat(chunks),
          })
        );
        response.on('error', reject);
      }
    );
    request.setTimeout(45000, () => request.destroy(new Error('The remote request timed out.')));
    request.on('error', reject);
    request.end();
  });
}
