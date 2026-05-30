/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 *
 * Main window: walks the user through a list of sentences, records each one
 * to audio_NN.wav, and keeps a tab-separated manifest (trans.txt) in sync
 * with what is actually on disk.
 */

private enum Mode {
    IDLE,
    RECORDING,
    PLAYING
}

// Tracks the user's last semantic button action. Drives the keyboard
// focus transitions documented in build_working_view and the four
// handlers below.
private enum LastAction {
    INITIAL,
    PREVIOUS,
    NEXT,
    RECORD,
    STOP,
    PLAY
}

public class DicteeWindow : Adw.ApplicationWindow {

    // State
    private string[] sentences = {};
    private int index = 0;
    private File? sentences_file = null;
    private File? output_dir = null;
    private string manifest_name = "trans.txt";
    private int pad_width = 2;
    private bool[] recorded = {};
    private Mode mode = Mode.IDLE;

    private Recorder recorder = new Recorder ();
    private Player player = new Player ();
    private bool mic_available = false;
    private LastAction last_action = LastAction.INITIAL;

    // Widgets we mutate after construction
    private Adw.WindowTitle window_title;
    private Adw.ToolbarView toolbar_view;
    private Gtk.Stack body_stack;
    private Adw.StatusPage empty_page;
    private Gtk.Label sentence_label;
    private Gtk.Label status_indicator;
    private Gtk.Button prev_button;
    private Gtk.Button record_button;
    private Gtk.Button play_button;
    private Gtk.Button next_button;

    public DicteeWindow (Adw.Application app) {
        Object (application: app);

        set_default_size (720, 480);
        set_title ("Dictée");

        build_ui ();
        wire_shortcuts ();

        recorder.stopped.connect (on_recorder_stopped);
        player.stopped.connect (on_player_stopped);

        // Start the always-on capture pipeline immediately so the
        // microphone-startup transient is consumed once, here, while the
        // user is opening their sentences file. From then on, every
        // recording is a slice of a long-running warm stream.
        mic_available = recorder.init ();
        if (!mic_available) {
            warning ("Microphone unavailable — Record will stay disabled");
        }

        // On close: finalise any in-flight recording, then stop the
        // capture pipeline cleanly.
        close_request.connect (on_close_request);
    }

    private bool on_close_request () {
        if (mode == Mode.RECORDING) {
            recorder.stop ();
        }
        if (mode == Mode.PLAYING) {
            player.stop ();
        }
        recorder.shutdown ();
        return false; // let the default destroy path proceed
    }

    // Move keyboard focus to `target` and force the focus ring to be
    // visible (GTK4 hides it by default when focus is set programmatically
    // rather than via Tab). Deferred via Idle.add so it works regardless of
    // whether we are mid-realisation or mid-signal-dispatch. We honour the
    // rule strictly — no silent fall-back to Record. If the target happens
    // to be insensitive, grab_focus is a no-op and focus stays where it
    // was; that's still preferable to misleading the user about which
    // button is selected.
    private void focus_button (Gtk.Button target) {
        Idle.add (() => {
            target.grab_focus ();
            this.focus_visible = true;
            return Source.REMOVE;
        });
    }

    // ---------------------------------------------------------------- UI

    private void build_ui () {
        toolbar_view = new Adw.ToolbarView ();

        var header = new Adw.HeaderBar ();
        window_title = new Adw.WindowTitle ("Dictée", "");
        header.title_widget = window_title;

        // Hamburger menu: open sentences file, change output folder.
        var menu = new Menu ();
        menu.append (_("Open sentences file…"), "win.open-sentences");
        menu.append (_("Change output folder…"), "win.change-output");

        var menu_button = new Gtk.MenuButton ();
        menu_button.icon_name = "open-menu-symbolic";
        menu_button.menu_model = menu;
        header.pack_end (menu_button);

        toolbar_view.add_top_bar (header);

        // Actions backing the menu items.
        var act_open = new SimpleAction ("open-sentences", null);
        act_open.activate.connect (() => choose_sentences_file.begin ());
        add_action (act_open);

        var act_out = new SimpleAction ("change-output", null);
        act_out.activate.connect (() => choose_output_folder.begin ());
        add_action (act_out);

        // Body: a stack with the empty state and the working view.
        body_stack = new Gtk.Stack ();
        body_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;

        empty_page = new Adw.StatusPage ();
        empty_page.icon_name = "audio-input-microphone-symbolic";
        empty_page.title = _("No sentences loaded");
        empty_page.description = _("Open a UTF-8 text file with one sentence per line.");
        var open_btn = new Gtk.Button.with_label (_("Open sentences file…"));
        open_btn.halign = Gtk.Align.CENTER;
        open_btn.add_css_class ("suggested-action");
        open_btn.add_css_class ("pill");
        open_btn.clicked.connect (() => choose_sentences_file.begin ());
        empty_page.child = open_btn;
        body_stack.add_named (empty_page, "empty");

        body_stack.add_named (build_working_view (), "working");

        toolbar_view.content = body_stack;
        set_content (toolbar_view);
    }

    private Gtk.Widget build_working_view () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 24;
        box.margin_bottom = 24;
        box.margin_start = 24;
        box.margin_end = 24;

        status_indicator = new Gtk.Label ("");
        status_indicator.halign = Gtk.Align.CENTER;
        status_indicator.add_css_class ("dim-label");
        box.append (status_indicator);

        sentence_label = new Gtk.Label ("");
        sentence_label.wrap = true;
        sentence_label.justify = Gtk.Justification.CENTER;
        sentence_label.halign = Gtk.Align.CENTER;
        sentence_label.valign = Gtk.Align.CENTER;
        sentence_label.hexpand = true;
        sentence_label.vexpand = true;
        sentence_label.add_css_class ("title-1");
        sentence_label.max_width_chars = 60;
        box.append (sentence_label);

        var button_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        button_row.halign = Gtk.Align.CENTER;
        button_row.margin_top = 12;
        // Lock all four buttons to the same width. This keeps Record/Stop
        // identical in size (the only one whose label swaps) so the focus
        // ring doesn't shift visually when toggling state.
        button_row.homogeneous = true;

        prev_button = make_button ("go-previous-symbolic", _("Previous"));
        prev_button.clicked.connect (on_prev_clicked);
        button_row.append (prev_button);

        record_button = make_button ("media-record-symbolic", _("Record"));
        record_button.add_css_class ("suggested-action");
        record_button.clicked.connect (on_record_clicked);
        button_row.append (record_button);

        play_button = make_button ("media-playback-start-symbolic", _("Play"));
        play_button.clicked.connect (on_play_clicked);
        button_row.append (play_button);

        next_button = make_button ("go-next-symbolic", _("Next"));
        next_button.clicked.connect (on_next_clicked);
        button_row.append (next_button);

        box.append (button_row);

        return box;
    }

    private Gtk.Button make_button (string icon, string label) {
        var btn = new Gtk.Button ();
        var content = new Adw.ButtonContent ();
        content.icon_name = icon;
        content.label = label;
        btn.child = content;
        return btn;
    }

    private void wire_shortcuts () {
        var ctrl = new Gtk.ShortcutController ();
        ctrl.scope = Gtk.ShortcutScope.GLOBAL;

        ctrl.add_shortcut (new Gtk.Shortcut (
            Gtk.ShortcutTrigger.parse_string ("space"),
            new Gtk.CallbackAction ((w, _a) => { on_record_clicked (); return true; })));

        ctrl.add_shortcut (new Gtk.Shortcut (
            Gtk.ShortcutTrigger.parse_string ("Left"),
            new Gtk.CallbackAction ((w, _a) => { on_prev_clicked (); return true; })));

        ctrl.add_shortcut (new Gtk.Shortcut (
            Gtk.ShortcutTrigger.parse_string ("Right"),
            new Gtk.CallbackAction ((w, _a) => { on_next_clicked (); return true; })));

        ctrl.add_shortcut (new Gtk.Shortcut (
            Gtk.ShortcutTrigger.parse_string ("p"),
            new Gtk.CallbackAction ((w, _a) => { on_play_clicked (); return true; })));

        ((Gtk.Widget) this).add_controller (ctrl);
    }

    // ------------------------------------------------------ Sentence list

    public void load_sentences (File file) {
        string contents;
        try {
            uint8[] raw;
            file.load_contents (null, out raw, null);
            contents = (string) raw;
        } catch (Error e) {
            warning ("Could not read sentences file: %s", e.message);
            show_error (_("Could not read sentences file: %s").printf (e.message));
            return;
        }

        if (!contents.validate ()) {
            warning ("Sentences file is not valid UTF-8");
            show_error (_("Sentences file is not valid UTF-8."));
            return;
        }

        var list = new GenericArray<string> ();
        foreach (unowned string raw_line in contents.split ("\n")) {
            string line = raw_line.chomp ();      // strip trailing whitespace incl. \r
            if (line.length == 0) {
                continue;                          // ignore blank lines
            }
            list.add (line);
        }

        if (list.length == 0) {
            show_error (_("The sentences file contains no non-blank lines."));
            return;
        }

        sentences_file = file;
        sentences = list.steal ();
        pad_width = int.max (2, sentences.length.to_string ().length);

        // Default the output directory to a sibling folder named after the
        // sentences file with the extension stripped, e.g. for
        // "/x/Dictionnaire.txt" recordings land in "/x/Dictionnaire/".
        // Create it on demand. A user-chosen folder (via the menu) is reset
        // here so re-opening a different file derives a fresh default.
        string stem = file.get_basename ();
        int dot = stem.last_index_of_char ('.');
        if (dot > 0) {
            stem = stem.substring (0, dot);
        }
        output_dir = file.get_parent ().get_child (stem);
        if (!output_dir.query_exists ()) {
            try {
                output_dir.make_directory_with_parents ();
            } catch (Error e) {
                warning ("Could not create output directory %s: %s",
                         output_dir.get_path (), e.message);
                show_error (_("Could not create output directory: %s")
                              .printf (e.message));
                return;
            }
        }

        scan_recorded ();
        pick_resume_index ();
        regenerate_manifest ();
        body_stack.visible_child_name = "working";
        refresh_ui ();

        // Sentences just loaded — workflow starts on Record.
        last_action = LastAction.INITIAL;
        focus_button (record_button);
    }

    private void pick_resume_index () {
        for (int i = 0; i < sentences.length; i++) {
            if (!recorded[i]) {
                index = i;
                return;
            }
        }
        index = 0;
    }

    private void scan_recorded () {
        recorded = new bool[sentences.length];
        for (int i = 0; i < sentences.length; i++) {
            recorded[i] = File.new_for_path (audio_path (i)).query_exists ();
        }
    }

    private string audio_filename (int i) {
        // "audio_" + zero-padded index + ".wav"
        return "audio_%0*d.wav".printf (pad_width, i);
    }

    private string audio_path (int i) {
        return Path.build_filename (output_dir.get_path (), audio_filename (i));
    }

    private string manifest_path () {
        return Path.build_filename (output_dir.get_path (), manifest_name);
    }

    private void regenerate_manifest () {
        if (output_dir == null || sentences.length == 0) {
            return;
        }
        var sb = new StringBuilder ();
        for (int i = 0; i < sentences.length; i++) {
            if (!recorded[i]) {
                continue;
            }
            string s = sentences[i]
                .replace ("\t", " ")
                .replace ("\r", " ")
                .replace ("\n", " ");
            sb.append (audio_filename (i));
            sb.append_c ('\t');
            sb.append (s);
            sb.append_c ('\n');
        }

        string final_path = manifest_path ();
        string tmp_path = final_path + ".tmp";
        try {
            // Atomic write: write to .tmp then rename over the target.
            FileUtils.set_contents (tmp_path, sb.str);
            var tmp_file = File.new_for_path (tmp_path);
            var dst_file = File.new_for_path (final_path);
            tmp_file.move (dst_file, FileCopyFlags.OVERWRITE, null, null);
        } catch (Error e) {
            warning ("Could not write manifest: %s", e.message);
        }
    }

    // -------------------------------------------------------- Navigation

    private void go_to (int new_index) {
        if (sentences.length == 0 || mode == Mode.RECORDING) {
            return;
        }
        if (new_index < 0 || new_index >= sentences.length) {
            return;
        }
        if (mode == Mode.PLAYING) {
            player.stop ();
        }
        index = new_index;
        refresh_ui ();
    }

    // ----------------------------------------------- Focus-driven clicks

    // Rule: pressing Previous after any non-Previous action selects Play
    //       (you went back to verify what was there). Pressing Previous
    //       after Previous keeps you on Previous (navigating backward).
    private void on_prev_clicked () {
        bool was_prev = (last_action == LastAction.PREVIOUS);
        go_to (index - 1);
        last_action = LastAction.PREVIOUS;
        focus_button (was_prev ? prev_button : play_button);
    }

    // Rule: pressing Next after Stop selects Record (continue recording the
    //       newly-selected sentence). Otherwise stay on Next.
    private void on_next_clicked () {
        bool after_stop = (last_action == LastAction.STOP);
        go_to (index + 1);
        last_action = LastAction.NEXT;
        focus_button (after_stop ? record_button : next_button);
    }

    // -------------------------------------------------- Record / play

    private void on_record_clicked () {
        if (sentences.length == 0 || output_dir == null) {
            return;
        }
        if (mode == Mode.PLAYING) {
            player.stop ();
        }
        if (mode == Mode.RECORDING) {
            // Toggle off. recorder.stop() finalises synchronously and
            // emits stopped(true), which fires on_recorder_stopped (where
            // the focus moves to Next per the workflow rule).
            recorder.stop ();
            return;
        }
        if (mode != Mode.IDLE) {
            return;
        }
        string path = audio_path (index);
        if (recorder.start (path)) {
            mode = Mode.RECORDING;
            last_action = LastAction.RECORD;
            refresh_ui ();
            // Focus stays on the same button — it just became Stop.
            focus_button (record_button);
        } else {
            show_error (_("Failed to start recording."));
        }
    }

    private void on_recorder_stopped (bool success) {
        if (!success) {
            show_error (_("Recording failed; the file may be incomplete."));
        }
        // Recorder writes the WAV and calls Normalize.wav_inplace itself
        // before emitting this signal — we just refresh the disk state.
        if (sentences.length > 0 && output_dir != null) {
            string path = audio_path (index);
            recorded[index] = File.new_for_path (path).query_exists ();
            regenerate_manifest ();
        }
        mode = Mode.IDLE;
        last_action = LastAction.STOP;
        refresh_ui ();
        // Rule: after Stop, jump focus to Next so the workflow continues
        // record → stop → next → record → stop → next …
        focus_button (next_button);
    }

    private void on_play_clicked () {
        if (sentences.length == 0 || output_dir == null) {
            return;
        }
        if (mode == Mode.PLAYING) {
            player.stop ();
            last_action = LastAction.PLAY;
            focus_button (play_button);
            return;
        }
        if (mode != Mode.IDLE || !recorded[index]) {
            return;
        }
        string uri = File.new_for_path (audio_path (index)).get_uri ();
        if (player.play (uri)) {
            mode = Mode.PLAYING;
            last_action = LastAction.PLAY;
            refresh_ui ();
            focus_button (play_button);
        } else {
            show_error (_("Failed to start playback."));
        }
    }

    private void on_player_stopped () {
        mode = Mode.IDLE;
        refresh_ui ();
        // Keep focus where the user last semantically acted (Play). The
        // last_action was already set to PLAY when playback was kicked off
        // or stopped; nothing more to do.
    }

    // -------------------------------------------------------- File dialogs

    private async void choose_sentences_file () {
        var dlg = new Gtk.FileDialog ();
        dlg.title = _("Open sentences file");
        var filter = new Gtk.FileFilter ();
        filter.name = _("Text files");
        filter.add_mime_type ("text/plain");
        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (filter);
        dlg.filters = filters;
        try {
            var file = yield dlg.open (this, null);
            if (file != null) {
                load_sentences (file);
            }
        } catch (Error e) {
            // Dismissed or failed — leave the current state alone.
        }
    }

    private async void choose_output_folder () {
        var dlg = new Gtk.FileDialog ();
        dlg.title = _("Select output folder");
        try {
            var dir = yield dlg.select_folder (this, null);
            if (dir != null) {
                output_dir = dir;
                if (sentences.length > 0) {
                    scan_recorded ();
                    regenerate_manifest ();
                    refresh_ui ();
                }
            }
        } catch (Error e) {
            // Dismissed.
        }
    }

    // ---------------------------------------------------------------- UI

    private void refresh_ui () {
        if (sentences.length == 0) {
            window_title.subtitle = "";
            body_stack.visible_child_name = "empty";
            return;
        }
        body_stack.visible_child_name = "working";

        int done = 0;
        foreach (bool b in recorded) {
            if (b) done++;
        }
        window_title.subtitle =
            _("%d / %d, recorded: %d").printf (index + 1, sentences.length, done);

        sentence_label.label = sentences[index];

        status_indicator.label = recorded[index]
            ? _("● recorded as %s").printf (audio_filename (index))
            : _("○ not recorded (%s)").printf (audio_filename (index));

        // Buttons
        prev_button.sensitive = (index > 0) && (mode != Mode.RECORDING);
        next_button.sensitive = (index < sentences.length - 1) && (mode != Mode.RECORDING);

        var rec_content = (Adw.ButtonContent) record_button.child;
        if (mode == Mode.RECORDING) {
            rec_content.icon_name = "media-playback-stop-symbolic";
            rec_content.label = _("Stop");
            record_button.remove_css_class ("suggested-action");
            record_button.add_css_class ("destructive-action");
        } else {
            rec_content.icon_name = "media-record-symbolic";
            rec_content.label = _("Record");
            record_button.remove_css_class ("destructive-action");
            record_button.add_css_class ("suggested-action");
        }
        record_button.sensitive = mic_available && (mode != Mode.PLAYING);

        var play_content = (Adw.ButtonContent) play_button.child;
        if (mode == Mode.PLAYING) {
            play_content.icon_name = "media-playback-stop-symbolic";
            play_content.label = _("Stop");
        } else {
            play_content.icon_name = "media-playback-start-symbolic";
            play_content.label = _("Play");
        }
        play_button.sensitive = recorded[index] && (mode != Mode.RECORDING);
    }

    private void show_error (string text) {
        var dlg = new Adw.AlertDialog (_("Dictée"), text);
        dlg.add_response ("ok", _("OK"));
        dlg.default_response = "ok";
        dlg.present (this);
    }
}
