/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * GStreamer helpers: Recorder captures from the default microphone to a WAV
 * file at exactly S16LE / 16 kHz / mono, and Player plays an existing WAV
 * file through the default audio sink. Both run on the GLib main loop via
 * a bus watch.
 *
 * Stopping a recording MUST send EOS first and wait for the EOS message
 * before transitioning to NULL — otherwise wavenc never patches the WAV
 * header and the resulting file is truncated/corrupt.
 */

public class Recorder : Object {

    public signal void stopped (bool success);

    private Gst.Pipeline? pipeline = null;
    private uint bus_watch_id = 0;

    public bool is_active {
        get { return pipeline != null; }
    }

    public bool start (string abs_path) {
        if (pipeline != null) {
            return false;
        }

        // Try pipewiresrc first, then fall back to pulsesrc. Falling back on
        // factory absence alone is not enough: in a Flatpak sandbox with only
        // --socket=pulseaudio, the pipewiresrc plugin is present but cannot
        // reach the PipeWire socket and fails synchronously at set_state.
        string[] candidates = { "pipewiresrc", "pulsesrc" };
        foreach (unowned string src_factory in candidates) {
            if (Gst.ElementFactory.find (src_factory) == null) {
                continue;
            }
            if (try_start_with (src_factory, abs_path)) {
                return true;
            }
        }
        warning ("Recording pipeline failed to enter PLAYING state with any source");
        return false;
    }

    private bool try_start_with (string src_factory, string abs_path) {
        // Build the pipeline element-by-element rather than via parse_launch.
        // parse_launch's mini-language does not strip single quotes, so any
        // attempt to quote a path containing special characters would leak
        // the quotes into filesink's `location` and break the open() call.
        // Setting the property directly side-steps every quoting question.
        //
        // The microphone-startup transient (initial DC, preamp settling) is
        // handled deterministically in post-processing by Normalize.wav_inplace
        // — that's more reliable than dropping buffers via a valve, because a
        // wall-clock timeout doesn't line up exactly with how much source
        // audio has actually been emitted.
        var pipe  = new Gst.Pipeline ("dictee-rec");
        var src   = Gst.ElementFactory.make (src_factory,    "src");
        var conv  = Gst.ElementFactory.make ("audioconvert", "conv");
        var resa  = Gst.ElementFactory.make ("audioresample", "resa");
        var caps  = Gst.ElementFactory.make ("capsfilter",   "caps");
        var enc   = Gst.ElementFactory.make ("wavenc",       "enc");
        var sink  = Gst.ElementFactory.make ("filesink",     "sink");

        if (pipe == null || src == null || conv == null || resa == null
            || caps == null || enc == null || sink == null) {
            warning ("Failed to instantiate recording elements (source=%s)",
                     src_factory);
            return false;
        }

        caps.set ("caps", Gst.Caps.from_string (
            "audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved"));
        sink.set ("location", abs_path);

        pipe.add_many (src, conv, resa, caps, enc, sink);
        if (!src.link_many (conv, resa, caps, enc, sink)) {
            warning ("Failed to link recording elements (source=%s)",
                     src_factory);
            return false;
        }

        pipeline = pipe;

        // Try to transition first; install the bus watch only on success.
        // Doing it in this order lets us synchronously fish the actual error
        // off the bus when an element refuses to enter PLAYING — otherwise
        // the watch consumes it asynchronously and we lose the message.
        var ret = pipeline.set_state (Gst.State.PLAYING);
        if (ret == Gst.StateChangeReturn.FAILURE) {
            var msg = pipeline.get_bus ().timed_pop_filtered (
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
            pipeline.set_state (Gst.State.NULL);
            pipeline = null;
            return false;
        }

        bus_watch_id = pipeline.get_bus ().add_watch (
            Priority.DEFAULT, on_bus_message);
        return true;
    }

    public void stop () {
        if (pipeline == null) {
            return;
        }
        // Send EOS; the bus watch will tear down once EOS reaches the bus,
        // ensuring wavenc finalises the WAV header on the way out.
        pipeline.send_event (new Gst.Event.eos ());
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message msg) {
        switch (msg.type) {
            case Gst.MessageType.EOS:
                teardown (true);
                break;
            case Gst.MessageType.ERROR:
                Error err;
                string dbg;
                msg.parse_error (out err, out dbg);
                warning ("Recorder error: %s (%s)", err.message, dbg);
                teardown (false);
                break;
            default:
                break;
        }
        return Source.CONTINUE;
    }

    private void teardown (bool success) {
        if (pipeline == null) {
            return;
        }
        if (bus_watch_id != 0) {
            Source.remove (bus_watch_id);
            bus_watch_id = 0;
        }
        pipeline.set_state (Gst.State.NULL);
        pipeline = null;
        stopped (success);
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
