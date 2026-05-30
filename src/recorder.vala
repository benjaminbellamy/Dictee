/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * Always-on microphone capture at 32-bit float / 32 kHz, processed in
 * float, then downsample+quantize once to S16LE / 16 kHz at the write
 * step. Capture pipeline:
 *
 *   {pipewiresrc|pulsesrc} ! audioconvert ! audioresample
 *     ! audio/x-raw,format=F32LE,rate=32000,channels=1,layout=interleaved
 *     ! appsink
 *
 * The capture pipeline is built once at app launch and stays in PLAYING
 * for the entire session, so the microphone-startup transient (preamp
 * settling, USB-mic boot, AGC stabilisation) happens once, here, and
 * never per-recording.
 *
 * Pressing Record flips a flag; pressing Stop:
 *   1. Steals the captured byte buffer.
 *   2. Crops CROP_START_DELAY_MS off the head and CROP_STOP_DELAY_MS off
 *      the tail.
 *   3. Reinterprets the rest as float[] and runs Normalize.in_place_f32
 *      (DC removal, peak-normalise to -1 dBFS, 15 ms fade, defensive
 *      clamp) at full IEEE 754 precision.
 *   4. Pushes the processed float bytes through a short-lived encode
 *      pipeline that does the F32LE/32k → S16LE/16k downsample,
 *      quantises (audioconvert's TPDF dither), and writes the WAV via
 *      wavenc + filesink.
 *
 * Player below is unchanged — playback still uses a per-clip playbin.
 */

public class Recorder : Object {

    public signal void stopped (bool success);

    // Drop this much audio after the moment Record was pressed (the
    // acoustic click of the Record key reaching the mic). 0 disables.
    public const int CROP_START_DELAY_MS = 250;

    // Drop this much audio from the tail of the captured buffer — i.e.
    // effectively stop the recording this far before the Stop key was
    // pressed (the click of the Stop key). 0 disables.
    public const int CROP_STOP_DELAY_MS = 250;

    // Capture at high precision; downsample and quantize only at write.
    public const int CAPTURE_RATE = 32000;          // clean 2:1 to OUTPUT_RATE
    public const int OUTPUT_RATE  = 16000;          // dataset target
    public const int CHANNELS     = 1;
    public const int BYTES_PER_CAPTURE_SAMPLE = 4;  // F32LE

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
            "audio/x-raw,format=F32LE,rate=%d,channels=%d,layout=interleaved"
                .printf (CAPTURE_RATE, CHANNELS)));

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

    // Stop capturing, slice off head/tail crop, normalise in float, encode
    // to S16LE/16 kHz WAV via a short-lived GStreamer pipeline, emit
    // stopped(success).
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

        int head_bytes = CROP_START_DELAY_MS * CAPTURE_RATE / 1000
                       * BYTES_PER_CAPTURE_SAMPLE * CHANNELS;
        int tail_bytes = CROP_STOP_DELAY_MS  * CAPTURE_RATE / 1000
                       * BYTES_PER_CAPTURE_SAMPLE * CHANNELS;
        if (head_bytes + tail_bytes >= captured.length) {
            warning ("Recording shorter than combined crop window — discarded");
            stopped (false);
            return;
        }
        int kept_bytes = captured.length - head_bytes - tail_bytes;
        int n_samples  = kept_bytes / BYTES_PER_CAPTURE_SAMPLE;

        // Reinterpret the kept slice as float[] via a memcpy. Cheap (<1 ms
        // for a multi-second clip) and avoids unowned-array casting tricks.
        float[] samples = new float[n_samples];
        Memory.copy ((uint8*) samples,
                     (uint8*) captured + head_bytes,
                     n_samples * BYTES_PER_CAPTURE_SAMPLE);

        Normalize.in_place_f32 (samples, CAPTURE_RATE);

        // Pack the processed floats back into a byte payload for appsrc.
        // The encode pipeline takes ownership.
        uint8[] payload = new uint8[n_samples * BYTES_PER_CAPTURE_SAMPLE];
        Memory.copy (payload,
                     (uint8*) samples,
                     n_samples * BYTES_PER_CAPTURE_SAMPLE);

        bool ok = write_via_gstreamer (path, (owned) payload);
        stopped (ok);
    }

    // Push the float bytes through a short-lived appsrc-based pipeline
    // that does the F32LE/CAPTURE_RATE → S16LE/OUTPUT_RATE downsample and
    // writes the WAV via wavenc + filesink. Blocks until EOS or a 5 s
    // timeout (whichever comes first). Returns true iff EOS was seen.
    private bool write_via_gstreamer (string path, owned uint8[] float_bytes) {
        var pipe = new Gst.Pipeline ("dictee-encode");
        var src  = Gst.ElementFactory.make ("appsrc",        "asrc");
        var conv = Gst.ElementFactory.make ("audioconvert",  "conv");
        var resa = Gst.ElementFactory.make ("audioresample", "resa");
        var caps = Gst.ElementFactory.make ("capsfilter",    "caps");
        var enc  = Gst.ElementFactory.make ("wavenc",        "enc");
        var sink = Gst.ElementFactory.make ("filesink",      "sink");

        if (pipe == null || src == null || conv == null || resa == null
            || caps == null || enc == null || sink == null) {
            warning ("Failed to instantiate encode elements");
            return false;
        }

        var appsrc = (Gst.App.Src) src;
        appsrc.caps = Gst.Caps.from_string (
            "audio/x-raw,format=F32LE,rate=%d,channels=%d,layout=interleaved"
                .printf (CAPTURE_RATE, CHANNELS));
        appsrc.format = Gst.Format.BYTES;

        caps.set ("caps", Gst.Caps.from_string (
            "audio/x-raw,format=S16LE,rate=%d,channels=%d,layout=interleaved"
                .printf (OUTPUT_RATE, CHANNELS)));

        sink.set ("location", path);

        ((Gst.Bin) pipe).add_many (src, conv, resa, caps, enc, sink);
        if (!src.link_many (conv, resa, caps, enc, sink)) {
            warning ("Failed to link encode elements");
            return false;
        }

        if (pipe.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
            warning ("Encode pipeline failed to enter PLAYING");
            pipe.set_state (Gst.State.NULL);
            return false;
        }

        var buf = new Gst.Buffer.wrapped ((owned) float_bytes);
        appsrc.push_buffer ((owned) buf);
        appsrc.end_of_stream ();

        var msg = pipe.get_bus ().timed_pop_filtered (
            5 * Gst.SECOND,
            Gst.MessageType.EOS | Gst.MessageType.ERROR);

        pipe.set_state (Gst.State.NULL);

        if (msg == null) {
            warning ("Encode pipeline timed out");
            return false;
        }
        if (msg.type == Gst.MessageType.ERROR) {
            Error err;
            string dbg;
            msg.parse_error (out err, out dbg);
            warning ("Encode pipeline error: %s (%s)", err.message, dbg);
            return false;
        }
        return true;
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
