/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * Float-domain post-processing for the mono PCM samples the Recorder
 * captures. Runs at full IEEE 754 precision, before downsample and
 * quantisation to S16LE happen in the encode pipeline.
 *
 * In order:
 *   1. Remove DC offset (subtract the mean) — eliminates the silence →
 *      first-sample step that would otherwise click on playback.
 *   2. Peak-normalise to target_dbfs (default -1 dBFS) for clip-to-clip
 *      loudness consistency without compressing dynamics.
 *   3. Linear fade-in / fade-out over FADE_MS — guarantees the first and
 *      last samples are exactly zero.
 *   4. Defensive clamp to [-1.0, 1.0].
 *
 * Operates in place on a float[] of mono samples at the given sample rate.
 */

namespace Normalize {

    // Target peak level in dBFS. -1 dBFS = 10^(-1/20) ≈ 0.891 nominal.
    public const double DEFAULT_TARGET_DBFS = -1.0;

    // Linear fade length in ms (applied to both head and tail).
    public const int FADE_MS = 15;

    public void in_place_f32 (float[] samples, int sample_rate,
                              double target_dbfs = DEFAULT_TARGET_DBFS) {
        int n = samples.length;
        if (n == 0) {
            return;
        }

        // 1. DC offset (mean) computed in double for accumulation safety.
        double sum = 0.0;
        for (int i = 0; i < n; i++) {
            sum += samples[i];
        }
        double dc = sum / (double) n;
        if (dc != 0.0) {
            for (int i = 0; i < n; i++) {
                samples[i] = (float) ((double) samples[i] - dc);
            }
        }

        // 2. Peak-normalise.
        double peak = 0.0;
        for (int i = 0; i < n; i++) {
            double a = (double) samples[i];
            if (a < 0.0) a = -a;
            if (a > peak) peak = a;
        }
        if (peak > 0.0) {
            double target = Math.pow (10.0, target_dbfs / 20.0);
            double gain = target / peak;
            for (int i = 0; i < n; i++) {
                samples[i] = (float) ((double) samples[i] * gain);
            }
        }

        // 3. Fade-in / fade-out.
        int fade_samples = int.min (FADE_MS * sample_rate / 1000, n / 2);
        if (fade_samples > 0) {
            for (int i = 0; i < fade_samples; i++) {
                double k = (double) i / (double) fade_samples;
                samples[i] = (float) ((double) samples[i] * k);
                int j = n - 1 - i;
                samples[j] = (float) ((double) samples[j] * k);
            }
        }

        // 4. Defensive clamp — gain might nudge one sample past ±1.0 due
        //    to rounding before the float→int16 quantiser sees it.
        for (int i = 0; i < n; i++) {
            if (samples[i] > 1.0f) samples[i] = 1.0f;
            else if (samples[i] < -1.0f) samples[i] = -1.0f;
        }
    }
}
