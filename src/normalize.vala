/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * Post-processing for the mono S16LE WAV files Dictée produces. In order:
 *   1. Trim TRIM_START_MS off the head (mic startup transient) and
 *      TRIM_END_MS off the tail (Stop-button release click).
 *   2. Remove the DC offset from the remaining samples, since a non-zero
 *      mean is what causes the silence → first-sample step on playback.
 *   3. Peak-normalise to target_dbfs (default -1 dBFS).
 *   4. Apply a short linear fade-in/out so the very first/last sample is
 *      exactly zero, killing any residual playback discontinuity.
 *
 * The WAV header is rebuilt with the new (shorter) data-chunk size and the
 * file is written back atomically via File.replace_contents.
 */

namespace Normalize {

    // Head/tail trim is now zero by default. With the always-on capture
    // pipeline the mic transient never reaches the WAV in the first place,
    // and keypress-click trimming lives in Recorder (CROP_START_DELAY_MS,
    // CROP_STOP_DELAY_MS) so there's a single place to tune it. These two
    // constants stay around as an escape hatch but are kept at zero so
    // Normalize.wav_inplace is now idempotent — useful if it ever runs on
    // a pre-existing file.
    public const int TRIM_START_MS = 0;
    public const int TRIM_END_MS = 0;

    // Target peak level. -1 dBFS leaves a touch of headroom so subsequent
    // resampling or codec passes don't clip.
    public const double DEFAULT_TARGET_DBFS = -1.0;

    // Linear fade-in/out length. 15 ms is below the ear's transient-
    // detection threshold but long enough to ramp away any first-sample step
    // that survives the trim + DC-offset removal.
    public const int FADE_MS = 15;

    public const int SAMPLE_RATE = 16000;

    public void wav_inplace (string path, double target_dbfs = DEFAULT_TARGET_DBFS) {
        uint8[] data;
        try {
            string etag;
            File.new_for_path (path).load_contents (null, out data, out etag);
        } catch (Error e) {
            warning ("normalize: cannot read %s: %s", path, e.message);
            return;
        }

        int data_offset;
        int data_size;
        if (!find_data_chunk (data, out data_offset, out data_size)) {
            warning ("normalize: no data chunk in %s", path);
            return;
        }

        // S16LE mono: every two bytes is one signed 16-bit sample.
        int orig_samples = data_size / 2;
        int trim_start = TRIM_START_MS * SAMPLE_RATE / 1000;
        int trim_end   = TRIM_END_MS   * SAMPLE_RATE / 1000;
        if (trim_start + trim_end >= orig_samples) {
            // Recording is shorter than the combined trim window — nothing
            // usable to keep.
            return;
        }
        int n_samples = orig_samples - trim_start - trim_end;
        int src_start = data_offset + trim_start * 2;

        // DC offset = mean of remaining samples. Subtracting it makes the
        // signal symmetric around zero, which is what eliminates the
        // silence → ambient step on playback.
        int64 sum = 0;
        for (int i = 0; i < n_samples; i++) {
            sum += read_s16le (data, src_start + i * 2);
        }
        int dc = (int) (sum / n_samples);

        // Peak (post DC removal) drives the normalisation gain.
        int peak = 0;
        for (int i = 0; i < n_samples; i++) {
            int s = read_s16le (data, src_start + i * 2) - dc;
            int a = s < 0 ? -s : s;
            if (a > peak) peak = a;
        }
        if (peak == 0) {
            // Pure silence after DC removal — leave the file as-is.
            return;
        }

        double target = Math.pow (10.0, target_dbfs / 20.0) * 32767.0;
        double gain = target / (double) peak;

        // Build a new buffer = original header (up to and including the
        // data-chunk's 8-byte tag+size prefix) + processed samples. Header
        // size and RIFF size are then patched to match the trimmed length.
        int new_data_size = n_samples * 2;
        int new_total = data_offset + new_data_size;
        uint8[] outbuf = new uint8[new_total];
        Memory.copy (outbuf, data, data_offset);

        int fade_samples = int.min (FADE_MS * SAMPLE_RATE / 1000, n_samples / 2);
        for (int i = 0; i < n_samples; i++) {
            int s = read_s16le (data, src_start + i * 2) - dc;
            double v = (double) s * gain;

            if (fade_samples > 0) {
                if (i < fade_samples) {
                    v *= (double) i / (double) fade_samples;
                } else if (i >= n_samples - fade_samples) {
                    int tail = n_samples - 1 - i;
                    v *= (double) tail / (double) fade_samples;
                }
            }

            int rounded = (int) Math.round (v);
            if (rounded > 32767) rounded = 32767;
            else if (rounded < -32768) rounded = -32768;
            write_s16le (outbuf, data_offset + i * 2, rounded);
        }

        // Patch the data-chunk size (4 bytes immediately before data_offset).
        write_u32le (outbuf, data_offset - 4, (uint) new_data_size);
        // Patch the RIFF chunk size at offset 4 = total file size - 8.
        write_u32le (outbuf, 4, (uint) (new_total - 8));

        try {
            string etag_out;
            File.new_for_path (path).replace_contents (
                outbuf, null, false, FileCreateFlags.NONE,
                out etag_out, null);
        } catch (Error e) {
            warning ("normalize: cannot write %s: %s", path, e.message);
        }
    }

    // Walk RIFF chunks past the 12-byte RIFF/size/WAVE preamble to locate
    // the 'data' chunk. Returns false if the file isn't a recognisable WAV
    // or the data chunk overflows the file.
    private bool find_data_chunk (uint8[] data, out int offset, out int size) {
        offset = -1;
        size = 0;
        if (data.length < 12) return false;
        if (data[0] != 'R' || data[1] != 'I' || data[2] != 'F' || data[3] != 'F'
            || data[8] != 'W' || data[9] != 'A' || data[10] != 'V' || data[11] != 'E') {
            return false;
        }

        int pos = 12;
        while (pos + 8 <= data.length) {
            uint chunk_size =
                  (uint) data[pos + 4]
                | ((uint) data[pos + 5] << 8)
                | ((uint) data[pos + 6] << 16)
                | ((uint) data[pos + 7] << 24);

            if (data[pos] == 'd' && data[pos + 1] == 'a'
                && data[pos + 2] == 't' && data[pos + 3] == 'a') {
                int data_off = pos + 8;
                if (data_off + (int) chunk_size > data.length) {
                    return false;
                }
                offset = data_off;
                size = (int) chunk_size;
                return true;
            }
            // RIFF chunks are padded to an even length.
            pos += 8 + (int) chunk_size;
            if ((chunk_size & 1u) != 0) pos++;
        }
        return false;
    }

    private inline int read_s16le (uint8[] data, int off) {
        uint16 raw = (uint16) (data[off] | ((uint16) data[off + 1] << 8));
        return (int16) raw;
    }

    private inline void write_s16le (uint8[] data, int off, int sample) {
        uint16 raw = (uint16) (int16) sample;
        data[off] = (uint8) (raw & 0xFF);
        data[off + 1] = (uint8) ((raw >> 8) & 0xFF);
    }

    private inline void write_u32le (uint8[] data, int off, uint value) {
        data[off]     = (uint8) (value & 0xFF);
        data[off + 1] = (uint8) ((value >> 8) & 0xFF);
        data[off + 2] = (uint8) ((value >> 16) & 0xFF);
        data[off + 3] = (uint8) ((value >> 24) & 0xFF);
    }
}
