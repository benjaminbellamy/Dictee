/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * Always-on microphone capture. The GStreamer pipeline is built and started
 * once at app launch and stays in PLAYING for the entire session:
 *
 *   {pipewiresrc|pulsesrc} ! audioconvert ! audioresample
 *     ! audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved
 *     ! appsink
 *
 * The microphone-startup transient (preamp settling, USB-mic boot, AGC
 * stabilisation) is consumed once, at launch, while the user is opening the
 * sentences file — never again per recording, which is what was producing
 * the leading pop in the previous design.
 *
 * Pressing Record only flips a flag; pressing Stop flips it back, slices
 * the captured byte buffer to drop the keypress clicks, writes a hand-built
 * canonical WAV file, and normalises it.
 *
 * Player below is unchanged — playback still uses a per-clip playbin since
 * it has no "first playback is transient" problem.
 */

public class Recorder : Object {

    public signal void stopped (bool success);

    // Drop this much audio after the moment Record was pressed (the
    // acoustic click of the Record key reaching the mic). 0 disables.
    public const int CROP_START_DELAY_MS = 0;

    // Drop this much audio from the tail of the captured buffer — i.e.
    // effectively stop the recording this far before the Stop key was
    // pressed (the click of the Stop key). 0 disables.
    public const int CROP_STOP_DELAY_MS = 0;

    private const int SAMPLE_RATE = 16000;
    private const int CHANNELS = 1;
    private const int BITS_PER_SAMPLE = 16;
    private const int BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8;

    private Gst.Pipeline? pipeline = null;
    private Gst.App.Sink? appsink = null;
    private uint bus_watch_id = 0;

    private Mutex mutex = Mutex ();
    private bool recording = false;
    private string? record_path = null;
    private ByteArray record_buffer = new ByteArray ();

    public bool is_active {
        get { return recording; }
    }

    // Build and start the capture pipeline. Returns false if no source
    // could enter PLAYING. Call once, from the window constructor, after
    // Gst.init.
    public bool init () {
        if (pipeline != null) {
            return true;
        }
        string[] candidates = { "pipewiresrc", "pulsesrc" };
        foreach (unowned string src_factory in candidates) {
            if (Gst.ElementFactory.find (src_factory) == null) {
                continue;
            }
            if (try_init_with (src_factory)) {
                return true;
            }
        }
        warning ("Capture pipeline failed to enter PLAYING with any source");
        return false;
    }

    private bool try_init_with (string src_factory) {
        var pipe = new Gst.Pipeline ("dictee-capture");
        var src  = Gst.ElementFactory.make (src_factory,    "src");
        var conv = Gst.ElementFactory.make ("audioconvert", "conv");
        var resa = Gst.ElementFactory.make ("audioresample", "resa");
        var caps = Gst.ElementFactory.make ("capsfilter",   "caps");
        var sink = Gst.ElementFactory.make ("appsink",      "sink");

        if (pipe == null || src == null || conv == null || resa == null
            || caps == null || sink == null) {
            warning ("Failed to instantiate capture elements (source=%s)",
                     src_factory);
            return false;
        }

        caps.set ("caps", Gst.Caps.from_string (
            "audio/x-raw,format=S16LE,rate=%d,channels=%d,layout=interleaved"
                .printf (SAMPLE_RATE, CHANNELS)));

        // emit-signals=true makes new-sample fire; sync=false keeps the
        // sink from throttling to the pipeline clock (we want raw samples
        // as fast as they come, not paced for playback).
        sink.set ("emit-signals", true);
        sink.set ("sync", false);
        sink.set ("drop", false);
        sink.set ("max-buffers", (uint) 16);

        ((Gst.Bin) pipe).add_many (src, conv, resa, caps, sink);
        if (!src.link_many (conv, resa, caps, sink)) {
            warning ("Failed to link capture elements (source=%s)",
                     src_factory);
            return false;
        }

        // Try to transition first; only commit references and install the
        // bus watch on success. On failure, drain ERROR off the bus for a
        // useful diagnostic before falling back to the next candidate.
        var ret = pipe.set_state (Gst.State.PLAYING);
        if (ret == Gst.StateChangeReturn.FAILURE) {
            var msg = pipe.get_bus ().timed_pop_filtered (
                0, Gst.MessageType.ERROR);
            if (msg != null) {
                Error err;
                string dbg;
                msg.parse_error (out err, out dbg);
                warning ("%s failed: %s (%s)", src_factory, err.message, dbg);
            } else {
                warning ("%s could not enter PLAYING (no error on bus)",
                         src_factory);
            }
            pipe.set_state (Gst.State.NULL);
            return false;
        }

        pipeline = pipe;
        appsink = (Gst.App.Sink) sink;
        appsink.new_sample.connect (on_new_sample);
        bus_watch_id = pipeline.get_bus ().add_watch (
            Priority.DEFAULT, on_bus_message);
        return true;
    }

    // Start capturing into the in-memory buffer; samples written here will
    // be saved to `path` on stop().
    public bool start (string path) {
        if (pipeline == null) {
            return false;
        }
        mutex.lock ();
        record_path = path;
        record_buffer.set_size (0);
        recording = true;
        mutex.unlock ();
        return true;
    }

    // Stop capturing, slice off head/tail crop, write the WAV, normalise,
    // and emit stopped(success).
    public void stop () {
        mutex.lock ();
        if (!recording) {
            mutex.unlock ();
            return;
        }
        recording = false;
        string? path = record_path;
        record_path = null;
        // Take ownership of the captured bytes and reset the field for the
        // next recording. The streaming thread will see recording=false
        // before any further append.
        uint8[] captured = record_buffer.steal ();
        mutex.unlock ();

        if (path == null) {
            stopped (false);
            return;
        }

        // Symmetric-but-independent crop: drop the first CROP_START_DELAY_MS
        // and the last CROP_STOP_DELAY_MS of audio.
        int head_bytes = CROP_START_DELAY_MS * SAMPLE_RATE / 1000
                       * BYTES_PER_SAMPLE * CHANNELS;
        int tail_bytes = CROP_STOP_DELAY_MS  * SAMPLE_RATE / 1000
                       * BYTES_PER_SAMPLE * CHANNELS;
        if (head_bytes + tail_bytes >= captured.length) {
            warning ("Recording shorter than combined crop window — discarded");
            stopped (false);
            return;
        }
        int kept_len = captured.length - head_bytes - tail_bytes;

        uint8[] samples = new uint8[kept_len];
        Memory.copy (samples, (uint8*) captured + head_bytes, kept_len);

        if (!write_wav (path, samples)) {
            stopped (false);
            return;
        }
        Normalize.wav_inplace (path);
        stopped (true);
    }

    // Set pipeline to NULL on app exit.
    public void shutdown () {
        if (pipeline == null) {
            return;
        }
        if (bus_watch_id != 0) {
            Source.remove (bus_watch_id);
            bus_watch_id = 0;
        }
        pipeline.set_state (Gst.State.NULL);
        appsink = null;
        pipeline = null;
    }

    // The new-sample callback fires on the GStreamer streaming thread. Keep
    // it short and lock-disciplined: pull → map → (if recording) append.
    private Gst.FlowReturn on_new_sample () {
        if (appsink == null) {
            return Gst.FlowReturn.OK;
        }
        var sample = appsink.pull_sample ();
        if (sample == null) {
            return Gst.FlowReturn.OK;
        }
        unowned Gst.Buffer? buf = sample.get_buffer ();
        if (buf == null) {
            return Gst.FlowReturn.OK;
        }
        Gst.MapInfo info;
        if (!buf.map (out info, Gst.MapFlags.READ)) {
            return Gst.FlowReturn.OK;
        }

        mutex.lock ();
        if (recording) {
            record_buffer.append (info.data);
        }
        mutex.unlock ();

        buf.unmap (info);
        return Gst.FlowReturn.OK;
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message msg) {
        switch (msg.type) {
            case Gst.MessageType.ERROR:
                Error err;
                string dbg;
                msg.parse_error (out err, out dbg);
                warning ("Capture pipeline error: %s (%s)", err.message, dbg);
                // Don't tear down — leave the pipeline in whatever state
                // GStreamer put it in. Recovery is out of scope; future
                // Record clicks will simply produce empty buffers.
                break;
            default:
                break;
        }
        return Source.CONTINUE;
    }

    // Build a canonical 44-byte RIFF/WAVE/fmt /data header for
    // PCM/mono/16000 Hz/16-bit, concatenate the sample bytes, and write
    // atomically. Returns false on I/O failure.
    private bool write_wav (string path, uint8[] samples) {
        int data_size = samples.length;
        int total = 44 + data_size;
        uint8[] buf = new uint8[total];

        int byte_rate = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE;
        int block_align = CHANNELS * BYTES_PER_SAMPLE;

        // RIFF header
        buf[0] = 'R'; buf[1] = 'I'; buf[2] = 'F'; buf[3] = 'F';
        write_u32le (buf, 4, (uint) (36 + data_size));
        buf[8] = 'W'; buf[9] = 'A'; buf[10] = 'V'; buf[11] = 'E';

        // fmt chunk
        buf[12] = 'f'; buf[13] = 'm'; buf[14] = 't'; buf[15] = ' ';
        write_u32le (buf, 16, 16);                          // fmt size
        write_u16le (buf, 20, 1);                           // PCM
        write_u16le (buf, 22, (uint16) CHANNELS);
        write_u32le (buf, 24, (uint) SAMPLE_RATE);
        write_u32le (buf, 28, (uint) byte_rate);
        write_u16le (buf, 32, (uint16) block_align);
        write_u16le (buf, 34, (uint16) BITS_PER_SAMPLE);

        // data chunk
        buf[36] = 'd'; buf[37] = 'a'; buf[38] = 't'; buf[39] = 'a';
        write_u32le (buf, 40, (uint) data_size);

        Memory.copy ((uint8*) buf + 44, samples, data_size);

        try {
            string etag_out;
            File.new_for_path (path).replace_contents (
                buf, null, false, FileCreateFlags.NONE,
                out etag_out, null);
            return true;
        } catch (Error e) {
            warning ("Cannot write %s: %s", path, e.message);
            return false;
        }
    }

    private static inline void write_u16le (uint8[] data, int off, uint16 v) {
        data[off]     = (uint8) (v & 0xFF);
        data[off + 1] = (uint8) ((v >> 8) & 0xFF);
    }

    private static inline void write_u32le (uint8[] data, int off, uint v) {
        data[off]     = (uint8) (v & 0xFF);
        data[off + 1] = (uint8) ((v >> 8) & 0xFF);
        data[off + 2] = (uint8) ((v >> 16) & 0xFF);
        data[off + 3] = (uint8) ((v >> 24) & 0xFF);
    }
}


public class Player : Object {

    public signal void stopped ();

    private dynamic Gst.Element? playbin = null;
    private uint bus_watch_id = 0;

    public bool is_active {
        get { return playbin != null; }
    }

    public bool play (string uri) {
        if (playbin != null) {
            return false;
        }

        playbin = Gst.ElementFactory.make ("playbin", "dictee-play");
        if (playbin == null) {
            warning ("Could not create playbin element");
            return false;
        }
        playbin.uri = uri;

        var bus = ((Gst.Pipeline) playbin).get_bus ();
        bus_watch_id = bus.add_watch (Priority.DEFAULT, on_bus_message);

        var ret = playbin.set_state (Gst.State.PLAYING);
        if (ret == Gst.StateChangeReturn.FAILURE) {
            warning ("Playback pipeline failed to enter PLAYING state");
            teardown ();
            return false;
        }
        return true;
    }

    public void stop () {
        if (playbin == null) {
            return;
        }
        teardown ();
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message msg) {
        switch (msg.type) {
            case Gst.MessageType.EOS:
                teardown ();
                break;
            case Gst.MessageType.ERROR:
                Error err;
                string dbg;
                msg.parse_error (out err, out dbg);
                warning ("Player error: %s (%s)", err.message, dbg);
                teardown ();
                break;
            default:
                break;
        }
        return Source.CONTINUE;
    }

    private void teardown () {
        if (playbin == null) {
            return;
        }
        if (bus_watch_id != 0) {
            Source.remove (bus_watch_id);
            bus_watch_id = 0;
        }
        playbin.set_state (Gst.State.NULL);
        playbin = null;
        stopped ();
    }
}
