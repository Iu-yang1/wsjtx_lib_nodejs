# Q65 transmit/receive chain

This branch exposes a conservative default Q65 path through the existing `WSJTXLib.encode()` and `WSJTXLib.decode()` APIs.

## Implemented scope

- Q65 is reported as both encode-capable and decode-capable.
- Transmit uses the WSJT-X `genq65_()` encoder and `genwave_()` waveform generator.
- Receive routes audio through WSJT-X multimode decoder mode `66`.
- Q65 decode callbacks are forwarded into the Node-visible decoded-message queue.
- The default public profile is Q65-60A at 12 kHz.

## Default transmit parameters

| Parameter | Value |
|---|---:|
| Mode enum | `WSJTXMode.Q65` / `6` |
| Period | 60 s |
| Submode | A |
| Symbols | 85 |
| Default sample rate | 12 kHz |
| Samples per symbol | 7200 at 12 kHz |
| Tone-spacing multiplier | 1 |
| Output length | `60 * sampleRate` samples |

The `frequency` argument is the audio offset in Hz, not the RF dial frequency.

## Default receive parameters

The Q65 receive path sets the underlying decoder to:

- `nmode = 66`
- `ntrperiod = 60`
- `nsubmode = 0`
- `ntxmode = 66`
- `nzhsym = 85`
- `max_drift = 50`

Existing decode options continue to map onto the WSJT-X decoder: `frequency`, `txFrequency`, `lowFreq`, `highFreq`, `tolerance`, station/grid context, decode depth, and QSO progress.

## Not yet exposed as public options

- Q65-30, Q65-120, and Q65-300 periods.
- Q65 submodes B, C, D, and E.
- Non-default Q65 drift or averaging controls beyond the existing decode options.

## Regression coverage

The smoke test suite covers Q65 capability reporting, enum stability, Q65-60A encode frame length, and Q65 silence decode completion.

Run:

```bash
npm run build
npm test
```
