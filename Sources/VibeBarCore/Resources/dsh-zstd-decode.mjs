// Decode dsh's append-only sequence of independent Zstandard frames.
//
// The frame-boundary parser is adapted from
// @deepseek-ai/dsh-session-persistence-jsonl (MIT, Copyright 2026 DeepSeek).
// Code CLI Bar runs this signed, bundled helper with the Node executable that
// already powers dsh. It emits only decompressed bytes to its parent process;
// it does not inspect, persist, or transmit session content.

import { readFileSync } from "node:fs";
import { once } from "node:events";
import { zstdDecompressSync } from "node:zlib";

const ZSTD_MAGIC = 0xfd2fb528;
const path = process.argv[2];

if (!path) {
  process.stderr.write("usage: dsh-zstd-decode.mjs <session.jsonl.zstd>\n");
  process.exit(64);
}

function completeFrameRanges(buffer) {
  const frames = [];
  let offset = 0;

  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) break;
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error(`invalid Zstandard frame magic at byte ${offset}`);
    }
    offset += 4;
    if (offset === buffer.length) break;

    const descriptor = buffer.readUInt8(offset++);
    if ((descriptor & 0x18) !== 0) {
      throw new Error(`reserved Zstandard frame-header bit at byte ${offset - 1}`);
    }

    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 0x20) !== 0;
    const hasChecksum = (descriptor & 0x04) !== 0;
    const dictionaryFlag = descriptor & 0x03;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes =
      contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remainingHeader =
      (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeader) break;
    offset += remainingHeader;

    let complete = false;
    while (!complete) {
      if (buffer.length - offset < 3) return frames;
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) {
        throw new Error(`reserved Zstandard block type at byte ${offset - 3}`);
      }
      const payloadBytes = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) return frames;
      offset += payloadBytes;
      complete = lastBlock;
    }

    if (hasChecksum) {
      if (buffer.length - offset < 4) return frames;
      offset += 4;
    }
    frames.push({ start, end: offset });
  }

  return frames;
}

process.stdout.on("error", (error) => {
  if (error.code === "EPIPE") process.exit(0);
  throw error;
});

const source = readFileSync(path);
const frames = completeFrameRanges(source);
if (frames.length === 0 && source.length > 0) {
  throw new Error("no complete Zstandard frame found");
}

for (const frame of frames) {
  const decoded = zstdDecompressSync(source.subarray(frame.start, frame.end));
  if (!process.stdout.write(decoded)) await once(process.stdout, "drain");
}
