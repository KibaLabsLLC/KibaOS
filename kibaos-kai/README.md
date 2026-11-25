# kibaos-kai

The Kiba voice assistant (kAI) as part of the KibaDE shell.

kAI is a local, offline assistant: say "Hey Kiba", then ask. llama.cpp answers,
whisper.cpp listens and Piper speaks. In KibaDE the shell draws it and a small
daemon runs it.

| Part | What |
|------|------|
| `kibavoiced` | Headless daemon (Qt Core + DBus). Owns the microphone, the wake phrase, the model and the voice. Owns `org.kibaos.Kiba` on the session bus. |
| `org.kibaos.Kiba1.xml` | The D-Bus contract between the daemon and the shell. |
| `kibavoice` | kAI's engine CLI, run by the daemon as a child process (`src/kibavoice.cpp`). |

## How it fits

    mic -> kibavoiced -(org.kibaos.Kiba1)-> Ash: status icon + card
                |
                +-> kibavoice (llama.cpp / whisper-cli / Piper)

The daemon is bus-activatable (`org.kibaos.Kiba.service`), so Ash asking for
its state at login is what starts it. The icon appears while the daemon runs.
The card opens by itself, without taking focus, when "Hey Kiba" is heard and
tucks away a few seconds after the answer. Clicking the icon opens it and keeps
it open. Clicking the orb talks (idle) or stops (speaking).

`Level` is streamed only while the card is visible, so an idle desktop carries
no audio-level traffic.

## Build

    cmake -S . -B build -G Ninja -DKIBAVOICE_ENGINE=OFF    # daemon only
    cmake --build build

`-DKIBAVOICE_ENGINE=ON` also builds `kibavoice` and `whisper-cli`; their CMake
fetches llama.cpp and whisper.cpp, so it needs network access. The package
(`PKGBUILD`) builds the daemon only and depends on a `kibavoice` package.

## Try the daemon without the shell

    kibavoiced &
    gdbus call --session --dest org.kibaos.Kiba --object-path /org/kibaos/Kiba \
      --method org.kibaos.Kiba1.Ask "what time is it"
    gdbus monitor --session --dest org.kibaos.Kiba
    kibavoiced --quit

## Licence

kAI is GPL-3.0-or-later (see `LICENSE`), and `kibavoiced` is derived from it.
The rest of KibaDE is BSD-3-Clause; the patch adds only new files and wiring.
