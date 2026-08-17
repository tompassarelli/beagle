// SPDX-License-Identifier: MIT OR Apache-2.0
// Bun's TCP binding around the runtime-neutral FRAMRPC codec/client.

import { createConnection } from 'node:net';
import {
  FRAMRPC_MAX_FRAME_BYTES,
  StoreProtocolError,
  StoreTransportError,
  storeClient as storeTransportClient,
  storeRpcDeclaredFrameBytes,
  storeTransportCheckpoint,
} from './store-rpc-core.mjs';

function concatChunks(chunks, length) {
  const joined = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.length;
  }
  return joined;
}

export function storeTcpTransport({
  host = '127.0.0.1', port = 7977,
} = {}) {
  if (typeof host !== 'string' || !host) {
    throw new StoreProtocolError('host must be a nonempty string', 'client/invalid-host');
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new StoreProtocolError('port must be from 1 through 65535', 'client/invalid-port');
  }
  return ({ frame, timeoutMs, signal }) => new Promise((resolve, reject) => {
    let settled = false;
    const chunks = [];
    let received = 0;
    let declared = null;
    const socket = createConnection({ host, port });

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', abort);
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    const abort = () => finish(new StoreTransportError('request aborted'));

    if (signal?.aborted) {
      abort();
      return;
    }
    signal?.addEventListener('abort', abort, { once: true });
    socket.setNoDelay(true);
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => socket.write(frame));
    socket.on('data', chunk => {
      if (settled) return;
      chunks.push(chunk);
      received += chunk.length;
      if (received > FRAMRPC_MAX_FRAME_BYTES) {
        finish(new StoreProtocolError(
          'response exceeds the frame limit',
          'client/frame-too-large',
        ));
        return;
      }
      try {
        const joined = concatChunks(chunks, received);
        if (declared === null && received >= 26) {
          declared = storeRpcDeclaredFrameBytes(joined);
        }
        if (declared !== null && received > declared) {
          finish(new StoreProtocolError(
            'response has bytes beyond its declared body',
            'client/trailing-bytes',
          ));
        } else if (declared !== null && received === declared) {
          finish(null, joined);
        }
      } catch (error) {
        finish(error);
      }
    });
    socket.once('timeout', () => finish(
      new StoreTransportError(`request exceeded ${timeoutMs}ms`),
    ));
    socket.once('end', () => {
      if (!settled) finish(
        new StoreTransportError('connection ended before a complete response'),
      );
    });
    socket.once('error', error => finish(
      new StoreTransportError(error.message, error),
    ));
  });
}

export function storeClient({
  host = '127.0.0.1', port = 7977, transport, ...options
} = {}) {
  return storeTransportClient({
    ...options,
    transport: transport ?? storeTcpTransport({ host, port }),
  });
}

export function storeNativeCheckpoint({
  host = '127.0.0.1', port = 7977, transport, ...options
} = {}) {
  return storeTransportCheckpoint({
    ...options,
    transport: transport ?? storeTcpTransport({ host, port }),
  });
}

export * from './store-rpc-core.mjs';
