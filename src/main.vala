/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>
 */

public class DicteeApp : Adw.Application {

    public DicteeApp () {
        Object (
            application_id: "fr.benjaminbellamy.dictee",
            flags: ApplicationFlags.HANDLES_OPEN
        );
    }

    protected override void activate () {
        var win = get_active_window () as DicteeWindow;
        if (win == null) {
            win = new DicteeWindow (this);
        }
        win.present ();
    }

    protected override void open (File[] files, string hint) {
        var win = get_active_window () as DicteeWindow;
        if (win == null) {
            win = new DicteeWindow (this);
        }
        if (files.length > 0) {
            win.load_sentences (files[0]);
        }
        win.present ();
    }

    public static int main (string[] argv) {
        // Initialise GStreamer before any pipeline is touched.
        Gst.init (ref argv);
        return new DicteeApp ().run (argv);
    }
}
