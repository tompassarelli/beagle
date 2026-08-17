// SPDX-License-Identifier: MIT OR Apache-2.0
// Bun's TCP binding around the runtime-neutral FRAMRPC codec/client.

import { createConnection } from 'node:net';
import {
  FRAMRPC_MAX_FRAME_BYTES,
  FramProtocolError,
  FramTransportError,
  framClient as framTransportClient,
  framRpcDeclaredFrameBytes,
  framTransportCheckpoint,
} from './framrpc-core.mjs';

function concatChunks(chunks, length) {
  const joined = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.length;
  }
  return joined;
}

export function framTcpTransport({
  host = '127.0.0.1', port = 7977,
} = {}) {
  if (typeof host !== 'string' || !host) {
    throw new FramProtocolError('host must be a nonempty string', 'client/invalid-host');
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new FramProtocolError('port must be from 1 through 65535', 'client/invalid-port');
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
    const abort = () => finish(new FramTransportError('request aborted'));

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
        finish(new FramProtocolError(
          'response exceeds the frame limit',
          'client/frame-too-large',
        ));
        return;
      }
      try {
        const joined = concatChunks(chunks, received);
        if (declared === null && received >= 26) {
          declared = framRpcDeclaredFrameBytes(joined);
        }
        if (declared !== null && received > declared) {
          finish(new FramProtocolError(
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
      new FramTransportError(`request exceeded ${timeoutMs}ms`),
    ));
    socket.once('end', () => {
      if (!settled) finish(
        new FramTransportError('connection ended before a complete response'),
      );
    });
    socket.once('error', error => finish(
      new FramTransportError(error.message, error),
    ));
  });
}

export function framClient({
  host = '127.0.0.1', port = 7977, transport, ...options
} = {}) {
  return framTransportClient({
    ...options,
    transport: transport ?? framTcpTransport({ host, port }),
  });
}

export function framNativeCheckpoint({
  host = '127.0.0.1', port = 7977, transport, ...options
} = {}) {
  return framTransportCheckpoint({
    ...options,
    transport: transport ?? framTcpTransport({ host, port }),
  });
}

export * from './framrpc-core.mjs';
