# Dictée

> **dictée** _f_ (plural dictées)
> dictée [\dik.te\] _féminin_
> French, dictation, the process of speaking for someone else to write down the words

A small Linux desktop app (GTK 4 + libadwaita, in Vala) to record an audio
dataset for training or fine-tuning speech-recognition models. Dictée walks
through a UTF-8 list of sentences, records each one from the microphone,
and produces matching WAV files plus a tab-separated transcript manifest.

## Audio format produced

Every recording is written as **WAV, 16-bit signed PCM, mono, 16 000 Hz**
(`audio/x-raw,format=S16LE,rate=16000,channels=1`). The format is fixed —
the GStreamer pipeline caps the source to those exact values via
`audioconvert` and `audioresample` regardless of the microphone's native
configuration.

After each recording the WAV is post-processed in place:

1. The first **550 ms** are trimmed to skip the microphone-startup
   transient (preamp settling, USB-mic boot) and the last **150 ms** are
   trimmed to drop the Stop-button release click.
2. The DC offset is removed so the signal is centred on zero.
3. Samples are peak-normalised to **-1 dBFS** for clip-to-clip loudness
   consistency without touching dynamics.
4. A 15 ms linear fade-in/out is applied to kill any residual
   playback-start/end discontinuity.

The trim lengths, target dBFS and fade length are constants at the top
of `src/normalize.vala` if you want to retune.

## Sentences file

A plain-text UTF-8 file with one sentence per line:

```
The quick brown fox jumps over the lazy dog.
Portez ce vieux whisky au juge blond qui fume.
…
```

Blank lines are ignored (they do not consume an index). Trailing whitespace
on each line is stripped.

## Output layout

For a sentences file `foo.txt` of N lines, by default Dictée creates a
sibling folder `foo/` next to it (named after the file with the extension
stripped) and writes:

```
foo/audio_00.wav      # padded to max(2, digits-in-N)
foo/audio_01.wav
…
foo/audio_<N-1>.wav
foo/trans.txt         # audio_NN.wav<TAB>sentence per recorded line
```

The folder is created on demand. You can override it from the menu;
opening a different sentences file re-derives the default.

**The `audio_*.wav` files together with `trans.txt` form the dataset —
audio plus paired transcript — ready to feed into a speech-recognition
training pipeline.**

## Resume behavior

On launch, Dictée scans the output directory and opens at the first
sentence whose `audio_NN.wav` does not yet exist. If every sentence has
been recorded already, it opens at index 0 so you can review or re-record.

The manifest is treated as a generated artifact: it is rewritten from
scratch after every successful recording (and once at launch) by scanning
the on-disk WAV files. A truncated or stale `trans.txt` self-heals on next
launch.

## Keyboard shortcuts

- **Space** — start / stop recording
- **←** / **→** — previous / next sentence (disabled while recording)
- **P** — play the current recording

## Build and run locally (Meson)

System packages needed (names are Debian/Ubuntu-ish; adjust for your
distro): `meson`, `ninja-build`, `valac`, `libgtk-4-dev`,
`libadwaita-1-dev`, `libgstreamer1.0-dev`,
`gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`,
`gstreamer1.0-pulseaudio` and/or `gstreamer1.0-pipewire`.

```sh
meson setup build
meson compile -C build
./build/src/dictee path/to/sentences.txt
```

## Build and install the Flatpak

```sh
flatpak install --user flathub org.gnome.Platform//49 org.gnome.Sdk//49
flatpak-builder --user --install --force-clean \
    build-flatpak fr.benjaminbellamy.dictee.yml
flatpak run fr.benjaminbellamy.dictee path/to/sentences.txt
```

The Flatpak finish-args grant:

- `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc` — display
- `--socket=pulseaudio` — microphone capture and playback via PipeWire's
  PulseAudio compatibility layer
- `--filesystem=home` — needed because the app reads the sentences file
  and writes the WAV/manifest files outside its sandbox. A stricter setup
  could rely on the XDG file portal instead and drop the broad home
  permission; this app keeps it simple.

The recorder tries `pipewiresrc` first and falls back to `pulsesrc`
whenever the first source can't enter PLAYING — whether because the plugin
is missing or because the sandbox can only reach the PulseAudio socket
(the default with `--socket=pulseaudio`). The rest of the pipeline is
unchanged either way.

## Verifying the audio format

After recording one or more lines (assuming `sentences.txt` next to the
output folder `sentences/`):

```sh
file sentences/audio_00.wav
# → RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 16000 Hz

soxi sentences/audio_00.wav           # if sox is installed
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
