import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import https from 'node:https';
import { WSJTXLib, WSJTXMode } from '../dist/src/index.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');
const cacheDir = join(root, '.cache', 'wsjtx-official-q65-samples');

const samples = [
  { name: 'Q65-30A ionoscatter 6m', path: 'samples/Q65/30A_Ionoscatter_6m/201203_022700.wav', q65Period: 30, q65Submode: 'A' },
  { name: 'Q65-60A EME 6m', path: 'samples/Q65/60A_EME_6m/210106_1621.wav', q65Period: 60, q65Submode: 'A' },
  { name: 'Q65-60B 1296 troposcatter', path: 'samples/Q65/60B_1296_Troposcatter/210109_0007.wav', q65Period: 60, q65Submode: 'B' },
  { name: 'Q65-120E ionoscatter 6m', path: 'samples/Q65/120E_Ionoscatter_6m/210130_1438.wav', q65Period: 120, q65Submode: 'E' },
];

function download(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        download(new URL(res.headers.location, url).toString()).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        reject(new Error(`GET ${url} failed with HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
}

async function getSample(path) {
  await mkdir(cacheDir, { recursive: true });
  const local = join(cacheDir, path.replaceAll('/', '__'));
  if (existsSync(local)) return readFile(local);
  const url = `https://raw.githubusercontent.com/WSJTX/wsjtx/master/${path}`;
  const data = await download(url);
  await writeFile(local, data);
  return data;
}

function readAscii(buffer, offset, length) {
  return buffer.subarray(offset, offset + length).toString('ascii');
}

function parseWav(buffer) {
  if (readAscii(buffer, 0, 4) !== 'RIFF' || readAscii(buffer, 8, 4) !== 'WAVE') throw new Error('Not a RIFF/WAVE file');
  let offset = 12;
  let fmt = null;
  let dataOffset = -1;
  let dataLength = 0;
  while (offset + 8 <= buffer.length) {
    const chunkId = readAscii(buffer, offset, 4);
    const chunkSize = buffer.readUInt32LE(offset + 4);
    const chunkData = offset + 8;
    if (chunkId === 'fmt ') {
      fmt = {
        audioFormat: buffer.readUInt16LE(chunkData),
        channels: buffer.readUInt16LE(chunkData + 2),
        sampleRate: buffer.readUInt32LE(chunkData + 4),
        bitsPerSample: buffer.readUInt16LE(chunkData + 14),
      };
    } else if (chunkId === 'data') {
      dataOffset = chunkData;
      dataLength = chunkSize;
    }
    offset = chunkData + chunkSize + (chunkSize % 2);
  }
  if (!fmt) throw new Error('Missing fmt chunk');
  if (dataOffset < 0) throw new Error('Missing data chunk');
  if (fmt.channels !== 1) throw new Error(`Expected mono WAV, got ${fmt.channels} channels`);
  const view = new DataView(buffer.buffer, buffer.byteOffset + dataOffset, dataLength);
  if (fmt.audioFormat === 1 && fmt.bitsPerSample === 16) {
    const audio = new Int16Array(dataLength / 2);
    for (let i = 0; i < audio.length; i++) audio[i] = view.getInt16(i * 2, true);
    return { audio, sampleRate: fmt.sampleRate, format: 'pcm_s16le' };
  }
  if (fmt.audioFormat === 3 && fmt.bitsPerSample === 32) {
    const audio = new Float32Array(dataLength / 4);
    for (let i = 0; i < audio.length; i++) audio[i] = view.getFloat32(i * 4, true);
    return { audio, sampleRate: fmt.sampleRate, format: 'float32le' };
  }
  throw new Error(`Unsupported WAV format: audioFormat=${fmt.audioFormat}, bitsPerSample=${fmt.bitsPerSample}`);
}

function utcFromSamplePath(path) {
  const stem = basename(path, '.wav').split('_').at(-1) ?? '';
  if (/^\d{6}$/.test(stem)) return Number(stem);
  if (/^\d{4}$/.test(stem)) return Number(`${stem}00`);
  return null;
}

function audioStats(audio) {
  let peak = 0;
  let sumSq = 0;
  let nonzero = 0;
  for (const v of audio) {
    const x = Math.abs(v);
    if (x > peak) peak = x;
    if (x > 0) nonzero++;
    sumSq += Number(v) * Number(v);
  }
  return { peak, rms: Math.sqrt(sumSq / audio.length), nonzero };
}

function summarizeMessages(result) {
  return result.messages.map((m) => ({ text: m.text.trim(), snr: m.snr, dt: m.deltaTime, freq: m.deltaFrequency, sync: m.sync }));
}

const lib = new WSJTXLib({ maxThreads: 4 });

async function probeDecode({ audio, q65Period, q65Submode, utc }) {
  const base = {
    threads: 4,
    utc,
    lowFreq: 0,
    highFreq: 5000,
    decodeDepth: 3,
    q65Period,
    q65Submode,
    q65ClearAveraging: true,
  };

  const probes = [
    { label: 'wide-default', frequency: 1500, txFrequency: 1500, tolerance: 5000, q65MaxDrift: 50, q65Averaging: false, q65SingleDecode: false },
    { label: 'wide-avg', frequency: 1500, txFrequency: 1500, tolerance: 5000, q65MaxDrift: 50, q65Averaging: true, q65SingleDecode: false },
    { label: 'wide-single', frequency: 1500, txFrequency: 1500, tolerance: 5000, q65MaxDrift: 50, q65Averaging: false, q65SingleDecode: true },
    { label: 'center-1000', frequency: 1000, txFrequency: 1000, tolerance: 1000, q65MaxDrift: 50, q65Averaging: false, q65SingleDecode: false },
    { label: 'center-1500', frequency: 1500, txFrequency: 1500, tolerance: 1000, q65MaxDrift: 50, q65Averaging: false, q65SingleDecode: false },
    { label: 'center-2000', frequency: 2000, txFrequency: 2000, tolerance: 1000, q65MaxDrift: 50, q65Averaging: false, q65SingleDecode: false },
    { label: 'wide-drift100', frequency: 1500, txFrequency: 1500, tolerance: 5000, q65MaxDrift: 100, q65Averaging: false, q65SingleDecode: false },
  ];

  const probeResults = [];
  let bestMessages = [];
  for (const probe of probes) {
    const result = await lib.decode(WSJTXMode.Q65, audio, { ...base, ...probe });
    const messages = summarizeMessages(result);
    probeResults.push({ label: probe.label, options: { ...probe, utc }, decodedCount: messages.length, messages });
    if (messages.length > bestMessages.length) bestMessages = messages;
  }
  return { probeResults, bestMessages };
}

const selfCases = [
  { name: 'self-Q65-30A', q65Period: 30, q65Submode: 'A', message: 'CQ K1ABC FN20', utc: 120000 },
  { name: 'self-Q65-60A', q65Period: 60, q65Submode: 'A', message: 'CQ K1ABC FN20', utc: 120000 },
  { name: 'self-Q65-60B', q65Period: 60, q65Submode: 'B', message: 'CQ K1ABC FN20', utc: 120000 },
];

let selfFailures = 0;
for (const sample of selfCases) {
  const encoded = await lib.encode(WSJTXMode.Q65, sample.message, 1500, { threads: 1, q65Period: sample.q65Period, q65Submode: sample.q65Submode });
  const { probeResults, bestMessages } = await probeDecode({ audio: encoded.audioData, q65Period: sample.q65Period, q65Submode: sample.q65Submode, utc: sample.utc });
  console.log(JSON.stringify({
    sample: sample.name,
    generated: { message: sample.message, messageSent: encoded.messageSent.trim(), sampleRate: encoded.sampleRate, samples: encoded.audioData.length, seconds: encoded.audioData.length / encoded.sampleRate, stats: audioStats(encoded.audioData) },
    q65: { period: sample.q65Period, submode: sample.q65Submode },
    utc: sample.utc,
    probes: probeResults,
  }));
  if (bestMessages.length === 0) selfFailures++;
}

let officialFailures = 0;
for (const sample of samples) {
  const buffer = await getSample(sample.path);
  const { audio, sampleRate, format } = parseWav(buffer);
  if (sampleRate !== 12000) throw new Error(`${sample.name}: expected 12000 Hz sample rate, got ${sampleRate}`);

  const utc = utcFromSamplePath(sample.path);
  const { probeResults, bestMessages } = await probeDecode({ audio, q65Period: sample.q65Period, q65Submode: sample.q65Submode, utc });

  console.log(JSON.stringify({
    sample: sample.name,
    path: sample.path,
    sampleUtcFromName: utc,
    wav: { sampleRate, samples: audio.length, seconds: audio.length / sampleRate, format, stats: audioStats(audio) },
    q65: { period: sample.q65Period, submode: sample.q65Submode },
    probes: probeResults,
  }));
  if (bestMessages.length === 0) officialFailures++;
}

if (selfFailures > 0 || officialFailures > 0) {
  throw new Error(`${selfFailures} self-generated Q65 sample(s) and ${officialFailures} official Q65 sample(s) produced zero decodes across all probes`);
}
