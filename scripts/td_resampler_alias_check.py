#!/usr/bin/env python3
"""TIM-704: alias-band energy comparison for TD sound callback resampler.

Mimics the verification approach used in TIM-677 for the RA VQA resampler.
Generates a synthetic broadband S16 source at 22050 Hz, runs it through both
the OLD nearest-neighbour callback (byte-cursor, the bug being fixed) and the
NEW linear-interpolation callback (sample-cursor), then computes FFT alias-band
energy in [12, 22] kHz on the device-rate (48000 Hz) output of each.

Why synthetic: TD AUD samples (SOUNDS.MIX) are mostly short SFX with mixed
content; a controlled broadband signal isolates the resampler's frequency
response.  TIM-677 used voiced speech because RA VQA had a real ENGLISH.VQA
narration showing the artifact; for TD we have no equivalent canonical
"clicking" sample, but the underlying aliasing mechanism is identical.
"""
import numpy as np

SRC_RATE = 22050
DST_RATE = 48000
DURATION = 1.0  # seconds


def make_source():
    """Broadband S16 source at SRC_RATE: white noise low-passed at ~9 kHz.

    This matches the spectrum of voiced speech consonants reasonably well —
    significant energy up to source Nyquist (11025 Hz) but no energy above it,
    so any alias-band content in the resampled output is purely a resampler
    artifact (not a quirk of the source).
    """
    rng = np.random.default_rng(42)
    n = int(SRC_RATE * DURATION)
    noise = rng.standard_normal(n)

    # Brick-wall low-pass at 9000 Hz via FFT zeroing (clean enough for analysis).
    nfft = 1
    while nfft < n:
        nfft *= 2
    X = np.fft.rfft(noise, nfft)
    freqs = np.fft.rfftfreq(nfft, 1.0 / SRC_RATE)
    X[freqs > 9000.0] = 0
    s = np.fft.irfft(X, nfft)[:n]
    s = s / np.max(np.abs(s)) * 0.8 * 32767.0
    return s.astype(np.int16)


def old_resample_nn_byte_cursor(src, src_rate, dst_rate):
    """Old td_sound_callback algorithm (pre-TIM-704).

    Cursor is in bytes, stride = 2 * src/dst bytes per output frame, and the
    16-bit read is at the (possibly odd) byte offset — the misaligned-read
    quirk is preserved here for fidelity.
    """
    stride = 2.0 * src_rate / dst_rate  # bytes/frame
    pcm_bytes = src.tobytes()  # little-endian S16
    pcm_len = len(pcm_bytes)
    out_frames = int(len(src) * dst_rate / src_rate)
    out = np.zeros(out_frames, dtype=np.int16)
    cursor = 0.0
    for f in range(out_frames):
        byte_idx = int(cursor)
        if byte_idx + 1 >= pcm_len:
            break
        lo = pcm_bytes[byte_idx]
        hi = pcm_bytes[byte_idx + 1]
        s = lo | (hi << 8)
        if s & 0x8000:
            s -= 0x10000
        out[f] = s
        cursor += stride
    return out


def new_resample_linear(src, src_rate, dst_rate):
    """New td_sound_callback algorithm (TIM-704).

    Cursor is in fractional source samples, stride = src/dst, linear interp
    between samples[i] and samples[i+1].
    """
    stride = src_rate / dst_rate
    total = len(src)
    out_frames = int(total * dst_rate / src_rate)
    out = np.zeros(out_frames, dtype=np.int16)
    cursor = 0.0
    for f in range(out_frames):
        i = int(cursor)
        if i + 1 >= total:
            break
        frac = cursor - i
        a = float(src[i])
        b = float(src[i + 1])
        v = (1.0 - frac) * a + frac * b
        ir = int(v + (0.5 if v >= 0 else -0.5))
        if ir > 32767:
            ir = 32767
        if ir < -32768:
            ir = -32768
        out[f] = ir
        cursor += stride
    return out


def alias_energy(out, dst_rate, src_rate):
    """Sum of |X(f)|^2 in [src_nyquist + margin, dst_nyquist]."""
    n = len(out)
    nfft = 1
    while nfft < n:
        nfft *= 2
    X = np.fft.rfft(out.astype(np.float64), nfft)
    freqs = np.fft.rfftfreq(nfft, 1.0 / dst_rate)
    band_lo = src_rate / 2.0 + 1000.0  # 12025 Hz when src=22050
    band_hi = dst_rate / 2.0
    mask = (freqs >= band_lo) & (freqs < band_hi)
    return float(np.sum(np.abs(X[mask]) ** 2))


def main():
    src = make_source()
    print(f"source: {len(src)} samples @ {SRC_RATE} Hz, max |s| = {int(np.max(np.abs(src)))}")

    old = old_resample_nn_byte_cursor(src, SRC_RATE, DST_RATE)
    new = new_resample_linear(src, SRC_RATE, DST_RATE)

    e_old = alias_energy(old, DST_RATE, SRC_RATE)
    e_new = alias_energy(new, DST_RATE, SRC_RATE)
    ratio_db = 10.0 * np.log10(e_new / max(e_old, 1.0))

    band_lo = int(SRC_RATE / 2 + 1000)
    band_hi = int(DST_RATE / 2)
    print(f"alias band [{band_lo}-{band_hi}] Hz energy:")
    print(f"  old (NN, byte-cursor)   = {e_old:.3e}")
    print(f"  new (linear, sample-cursor) = {e_new:.3e}")
    print(f"  delta = {ratio_db:+.2f} dB")

    # Count large sample-to-sample jumps in each (mirror of TIM-677's "157 jumps")
    def jumps(out, threshold=2000):
        d = np.abs(np.diff(out.astype(np.int32)))
        return int(np.sum(d > threshold))
    j_old = jumps(old)
    j_new = jumps(new)
    print(f"sample-to-sample jumps > 2000:")
    print(f"  old = {j_old}")
    print(f"  new = {j_new}")

    # Sanity: 1 kHz tone preservation.  Both should reproduce the tone, but the
    # new algorithm should land its energy entirely in [800, 1200] Hz with much
    # cleaner spectrum (no alias copies of the tone above source Nyquist).
    n = SRC_RATE  # 1 s
    t = np.arange(n) / SRC_RATE
    tone = (0.5 * 32767 * np.sin(2 * np.pi * 1000.0 * t)).astype(np.int16)
    old_t = old_resample_nn_byte_cursor(tone, SRC_RATE, DST_RATE)
    new_t = new_resample_linear(tone, SRC_RATE, DST_RATE)
    e_old_t = alias_energy(old_t, DST_RATE, SRC_RATE)
    e_new_t = alias_energy(new_t, DST_RATE, SRC_RATE)
    print(f"1 kHz tone alias band energy:")
    print(f"  old = {e_old_t:.3e}")
    print(f"  new = {e_new_t:.3e}")


if __name__ == "__main__":
    main()
