// Turn the JPEG frames from record-window.ps1 into a Motion-JPEG AVI.
// Run: node tools/make-avi.mjs <frames-folder> [out.avi]
//
// A real video with real frame timing, and no ffmpeg on the machine to
// make one. MJPEG in AVI is the format you can actually write by hand:
// every frame is a complete JPEG, so there is no inter-frame prediction,
// no bitstream to get wrong, and the container is a handful of fixed
// structs. It plays in VLC and Windows Media Player. Browsers will not
// play AVI — if this needs to go on a web page, ffmpeg and H.264 is the
// answer, and that is a dependency worth asking for rather than assuming.
import { readFileSync, writeFileSync, readdirSync } from "fs";
import { join } from "path";

const dir = process.argv[2];
const out = process.argv[3] ?? "out.avi";
if (!dir) {
  console.error("usage: node tools/make-avi.mjs <frames-folder> [out.avi]");
  process.exit(1);
}
const meta = JSON.parse(readFileSync(join(dir, "meta.json"), "utf8"));
const files = readdirSync(dir).filter((f) => f.endsWith(".jpg")).sort();
if (!files.length) {
  console.error("no .jpg frames in " + dir);
  process.exit(1);
}
const { width: W, height: H, delayMs } = meta;
const frames = files.map((f) => readFileSync(join(dir, f)));

const fourcc = (s) => Buffer.from(s, "ascii");
const u32 = (n) => {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n >>> 0, 0);
  return b;
};
/// RIFF chunks are word-aligned: an odd-length payload gets a pad byte
/// that is not counted in the size. Miss it and every later offset is
/// one out, which players report as a corrupt file.
const chunk = (id, payload) => {
  const parts = [fourcc(id), u32(payload.length), payload];
  if (payload.length % 2) parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
};
const list = (type, payload) =>
  Buffer.concat([fourcc("LIST"), u32(payload.length + 4), fourcc(type), payload]);

const microsPerFrame = delayMs * 1000;
const maxBytes = Math.max(...frames.map((f) => f.length));

// MainAVIHeader
const avih = Buffer.alloc(56);
avih.writeUInt32LE(microsPerFrame, 0);
avih.writeUInt32LE(Math.round(maxBytes / (delayMs / 1000)), 4); // max bytes/sec
avih.writeUInt32LE(0, 8);            // padding granularity
avih.writeUInt32LE(0x10, 12);        // AVIF_HASINDEX
avih.writeUInt32LE(frames.length, 16);
avih.writeUInt32LE(0, 20);           // initial frames
avih.writeUInt32LE(1, 24);           // streams
avih.writeUInt32LE(maxBytes, 28);
avih.writeUInt32LE(W, 32);
avih.writeUInt32LE(H, 36);

// AVIStreamHeader
const strh = Buffer.alloc(56);
fourcc("vids").copy(strh, 0);
fourcc("MJPG").copy(strh, 4);
strh.writeUInt32LE(0, 8);            // flags
strh.writeUInt16LE(0, 12);           // priority
strh.writeUInt16LE(0, 14);           // language
strh.writeUInt32LE(0, 16);           // initial frames
strh.writeUInt32LE(delayMs, 20);     // scale
strh.writeUInt32LE(1000, 24);        // rate -> rate/scale = fps
strh.writeUInt32LE(0, 28);           // start
strh.writeUInt32LE(frames.length, 32);
strh.writeUInt32LE(maxBytes, 36);
strh.writeUInt32LE(0xffffffff, 40);  // quality: default
strh.writeUInt32LE(0, 44);           // sample size: variable
strh.writeUInt16LE(0, 48); strh.writeUInt16LE(0, 50);
strh.writeUInt16LE(W, 52); strh.writeUInt16LE(H, 54);

// BITMAPINFOHEADER
const strf = Buffer.alloc(40);
strf.writeUInt32LE(40, 0);
strf.writeInt32LE(W, 4);
strf.writeInt32LE(H, 8);
strf.writeUInt16LE(1, 12);           // planes
strf.writeUInt16LE(24, 14);          // bit count
fourcc("MJPG").copy(strf, 16);
strf.writeUInt32LE(W * H * 3, 20);   // image size
const hdrl = list("hdrl", Buffer.concat([chunk("avih", avih), list("strl", Buffer.concat([chunk("strh", strh), chunk("strf", strf)]))]));

// movi, and the index that points into it
const movieParts = [];
const idx = [];
let offset = 4; // offsets in idx1 are relative to the 'movi' fourcc
for (const f of frames) {
  const c = chunk("00dc", f);
  movieParts.push(c);
  const entry = Buffer.alloc(16);
  fourcc("00dc").copy(entry, 0);
  entry.writeUInt32LE(0x10, 4);      // AVIIF_KEYFRAME — every MJPEG frame is one
  entry.writeUInt32LE(offset, 8);
  entry.writeUInt32LE(f.length, 12);
  idx.push(entry);
  offset += c.length;
}
const movi = list("movi", Buffer.concat(movieParts));
const idx1 = chunk("idx1", Buffer.concat(idx));

const body = Buffer.concat([fourcc("AVI "), hdrl, movi, idx1]);
const avi = Buffer.concat([fourcc("RIFF"), u32(body.length), body]);
writeFileSync(out, avi);
console.log(
  `${out}: ${frames.length} frames, ${W}x${H}, ${Math.round(1000 / delayMs)}fps, ` +
    `${(avi.length / 1024 / 1024).toFixed(2)} MB`
);
