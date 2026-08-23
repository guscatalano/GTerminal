// Turn a folder of raw BGRA frames (from record-window.ps1) into an
// animated GIF. Run: node tools/make-gif.mjs <folder> <out.gif>
//
// Written out longhand because there is no ffmpeg on the box and the
// alternative — a WPF GifBitmapEncoder — writes frames with no delay and
// no loop, which plays as a flicker rather than a recording.
//
// Terminal captures quantise well: large flat areas, few distinct
// colours, so a 5-bit-per-channel bucket count usually lands under 256
// exactly and the palette ends up lossless in practice.
import { readFileSync, writeFileSync, readdirSync } from "fs";
import { join } from "path";

const dir = process.argv[2];
const out = process.argv[3] ?? "out.gif";
if (!dir) {
  console.error("usage: node tools/make-gif.mjs <frames-folder> [out.gif]");
  process.exit(1);
}
const meta = JSON.parse(readFileSync(join(dir, "meta.json"), "utf8"));
const files = readdirSync(dir).filter((f) => f.endsWith(".bgra")).sort();
if (!files.length) {
  console.error("no frames in " + dir);
  process.exit(1);
}
const { width: W, height: H, stride, delayMs } = meta;

// ── palette ────────────────────────────────────────────────────────────
// One global palette for the whole recording, so frames can be written
// without their own colour tables. Colours are bucketed progressively
// coarser until they fit in 256.
function buildPalette(frames) {
  for (const bits of [8, 7, 6, 5, 4, 3]) {
    const shift = 8 - bits;
    const seen = new Map();
    let overflow = false;
    for (const f of frames) {
      for (let y = 0; y < H && !overflow; y++) {
        for (let x = 0; x < W; x++) {
          const i = y * stride + x * 4;
          const key =
            ((f[i + 2] >> shift) << (bits * 2)) | ((f[i + 1] >> shift) << bits) | (f[i] >> shift);
          if (!seen.has(key)) {
            seen.set(key, [f[i + 2], f[i + 1], f[i]]);
            if (seen.size > 256) { overflow = true; break; }
          }
        }
      }
      if (overflow) break;
    }
    if (!overflow) return { shift, bits, map: seen };
  }
  throw new Error("could not fit a palette");
}

const frames = files.map((f) => readFileSync(join(dir, f)));
const { shift, bits, map } = buildPalette(frames);
const keys = [...map.keys()];
const index = new Map(keys.map((k, i) => [k, i]));
const palette = Buffer.alloc(256 * 3);
keys.forEach((k, i) => {
  const [r, g, b] = map.get(k);
  palette[i * 3] = r; palette[i * 3 + 1] = g; palette[i * 3 + 2] = b;
});

function toIndices(f) {
  const px = Buffer.alloc(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = y * stride + x * 4;
      const key =
        ((f[i + 2] >> shift) << (bits * 2)) | ((f[i + 1] >> shift) << bits) | (f[i] >> shift);
      px[y * W + x] = index.get(key) ?? 0;
    }
  }
  return px;
}

// ── LZW, as GIF specifies it ───────────────────────────────────────────
// Variable-width codes, least-significant-bit first, with the dictionary
// reset once it fills — the detail that makes hand-rolled encoders
// produce files that decode as garbage halfway through.
function lzw(pixels, minCodeSize) {
  const clear = 1 << minCodeSize;
  const eoi = clear + 1;
  let dict = new Map();
  let codeSize = minCodeSize + 1;
  let next = eoi + 1;
  const bytes = [];
  let cur = 0, curBits = 0;
  const emit = (code) => {
    cur |= code << curBits;
    curBits += codeSize;
    while (curBits >= 8) {
      bytes.push(cur & 0xff);
      cur >>= 8;
      curBits -= 8;
    }
  };
  const reset = () => {
    dict = new Map();
    codeSize = minCodeSize + 1;
    next = eoi + 1;
  };
  emit(clear);
  reset();
  let prefix = pixels[0];
  for (let i = 1; i < pixels.length; i++) {
    const k = pixels[i];
    const combo = prefix * 4096 + k;
    if (dict.has(combo)) {
      prefix = dict.get(combo);
    } else {
      emit(prefix);
      if (next < 4096) {
        dict.set(combo, next++);
        if (next - 1 === (1 << codeSize) && codeSize < 12) codeSize++;
      } else {
        emit(clear);
        reset();
      }
      prefix = k;
    }
  }
  emit(prefix);
  emit(eoi);
  if (curBits > 0) bytes.push(cur & 0xff);
  return Buffer.from(bytes);
}

function subBlocks(buf) {
  const parts = [];
  for (let i = 0; i < buf.length; i += 255) {
    const chunk = buf.subarray(i, i + 255);
    parts.push(Buffer.from([chunk.length]), chunk);
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

// ── assemble ───────────────────────────────────────────────────────────
const parts = [];
parts.push(Buffer.from("GIF89a", "ascii"));
const lsd = Buffer.alloc(7);
lsd.writeUInt16LE(W, 0);
lsd.writeUInt16LE(H, 2);
lsd[4] = 0xf7;          // global colour table, 256 entries, 8 bits/channel
lsd[5] = 0;             // background colour index
lsd[6] = 0;             // pixel aspect ratio
parts.push(lsd, palette);

// The Netscape extension is what makes it loop; without it the recording
// plays once and freezes on the last frame.
parts.push(Buffer.from([0x21, 0xff, 0x0b]));
parts.push(Buffer.from("NETSCAPE2.0", "ascii"));
parts.push(Buffer.from([0x03, 0x01, 0x00, 0x00, 0x00]));

const delayCs = Math.max(2, Math.round(delayMs / 10)); // GIF delays are centiseconds
for (const f of frames) {
  const gce = Buffer.alloc(8);
  gce[0] = 0x21; gce[1] = 0xf9; gce[2] = 0x04;
  gce[3] = 0x00;                    // no transparency, no disposal
  gce.writeUInt16LE(delayCs, 4);
  gce[6] = 0; gce[7] = 0;
  parts.push(gce);

  const img = Buffer.alloc(10);
  img[0] = 0x2c;
  img.writeUInt16LE(0, 1); img.writeUInt16LE(0, 3);
  img.writeUInt16LE(W, 5); img.writeUInt16LE(H, 7);
  img[9] = 0;                       // no local colour table, not interlaced
  parts.push(img);

  parts.push(Buffer.from([8]));     // LZW minimum code size
  parts.push(subBlocks(lzw(toIndices(f), 8)));
}
parts.push(Buffer.from([0x3b]));

const gif = Buffer.concat(parts);
writeFileSync(out, gif);
console.log(
  `${out}: ${frames.length} frames, ${W}x${H}, ${delayCs * 10}ms each, ` +
    `${map.size} colours, ${(gif.length / 1024 / 1024).toFixed(2)} MB`
);
