# Controller Control

Map game controller button combos to desktop shortcuts and commands, as an
Omarchy shell plugin.

Press `L + R` to take a screenshot. Press `START` to open the Omarchy menu.
Hold `SELECT + START` to lock the screen. Any chord, any action.

Works with any controller Linux already recognises — Xbox, DualShock and
DualSense, 8BitDo, Switch Pro, and generic USB or Bluetooth pads. If it shows
up in `/dev/input`, this can bind it. Nothing is hardcoded to a particular
model: the defaults match any gamepad, and the button names come from the
kernel rather than from a per-device database.

![The bindings panel, showing L and R held on the controller](docs/screenshot.png)

The panel lists what every combo does and what it sends. The pills beside the
switch are the buttons being held right now, so the pad answers while your
hands are on it.

## Why it exists

Omarchy already has 200+ keybindings. This does not try to replace them: a
binding can simply *type* an existing shortcut, so `A -> SUPER+RETURN` opens a
terminal through the keybinding you already have. Nothing is duplicated.

## Install

```bash
omarchy plugin add https://github.com/perminder-klair/omarchy-controller-control.git --enable
```

From a local checkout instead:

```bash
./tools/install-plugin.sh
omarchy plugin enable co.klair.controller-control
```

`tools/install-plugin.sh` is a developer convenience for working on the plugin
from a git checkout: it copies the tree into
`~/.config/omarchy/plugins/co.klair.controller-control`, runs
`omarchy plugin validate`, and asks the shell to rescan. It is never run by
`omarchy plugin add`, and installing from the marketplace does not execute it.

There is nothing to compile and nothing to `pip install` — the engine is pure
Python standard library, which is also why the plugin needs no install hook.

### Requirements

**External dependencies: none.** The engine is pure Python 3 standard library
— no pip packages, no compilation, no install hook. It uses `python3`, which
Omarchy already ships.

Two permissions, both stock on an Omarchy install:

- Your user must be in the `input` group to read `/dev/input`. Check with `id`.
- `/dev/uinput` must be writable, for `keys` actions.

`controller-control doctor` verifies both and tells you what is missing.

## Pairing a controller

Any pad that pairs with Linux works. Over Bluetooth:

```bash
bluetoothctl
> scan on
> pair <MAC>
> trust <MAC>      # so it reconnects on its own next time
> connect <MAC>
```

Then confirm the kernel sees it:

```bash
controller-control devices
```

**Xbox Wireless Controller** pairs and works out of the box on a stock
Omarchy install. **DualSense / DualShock 4** likewise. Wired USB pads need no
pairing at all — plug them in and they appear.

### 8BitDo pads

8BitDo controllers boot into whichever mode they were last used in, and the
mode decides whether Linux sees them at all. Hold the combination while
powering on:

| Hold on power-on | Mode | Linux over Bluetooth |
|---|---|---|
| `START + B` | D-input | works |
| `START + X` | X-input | intended for the 2.4G dongle / Windows |
| `START + A` | macOS | works |
| `START + Y` | Switch | works |

In D-input these pads report the d-pad on the **left stick axes** rather than
the hat, so set `device.dpad_source` to `"stick"` — see
[D-pad source](#d-pad-source).

## Usage

The bar widget shows a controller glyph — solid when a pad is connected, dim
when not, and it pulses whenever a binding fires (red when one fails; the
tooltip then says why). Click it to open the bindings panel; middle-click
toggles the pad off and on without opening anything.

The panel header carries the master switch, along with the buttons you are
holding right now, so you can watch the pad answer while your hands are on it.
Below it are two tabs. **Bindings** is the everyday view: your bindings, then
the form to add or change one. **Advanced** holds the controller mode,
profiles, the stick-as-mouse settings and the Hyprland overlap check.

To add a binding: press **Record combo**, then press the buttons on the
controller. Firing is muted while recording, so capturing a combo cannot also
run whatever that combo is currently bound to. Then type the keys or command,
and save. **Repeat** and **Hold** set those options.

To change one, click it: it loads into the form, flags and all. Recording a
combo that is already bound does the same, so saving replaces it rather than
quietly dropping its `repeat` or `hold`. Anything that goes wrong — a binding
that failed to run, a config that will not load — shows at the top of the
panel until you dismiss it.

The panel works from the keyboard too. On the Bindings tab, up and down pick a
binding, Enter edits it and `x` removes it. On either tab, `r` records a combo,
`t` flips the master switch, left and right switch between the tabs, and Esc
leaves a text field or closes the panel.

For an ordinary window with touchscreen-keyboard access, choose **Open window**
in the panel, or run:

```bash
omarchy-shell controller openWindow
omarchy-shell controller closeWindow
```

The service lazily owns one editor shared by the popup and window. Switching
views preserves the draft and active recording; closing cancels recording.
The window also works without a bar widget. Focused fields and buttons scroll
into view in a short window. Tab moves between controls in the window; popup Tab switches bar panels. Esc leaves a text
field, cancels recording, then closes, one step at a time. Disabling mapping
leaves the editor usable.

In Keys mode, **Pick one of your shortcuts or a key** fills the Keys field
from a single searchable list: your current Hyprland shortcuts first, then 119
standard keys (letters, digits, navigation, punctuation, F1–F24, modifiers and
keypad keys). A shortcut fills the whole chord; a key picked after a trailing
`+` keeps the modifiers you typed. An empty or automatically filled
description follows the pick, while one you wrote stays. Picking never runs or
saves anything: saving still needs a recorded combo and **Save binding**.

Both lists load the first time the picker opens, never when the editor opens,
and the reload button refreshes the shortcuts. They come from
`hyprctl -j binds` in the active session; with several sessions, set
`HYPRLAND_INSTANCE_SIGNATURE` before launching the shell. Only global keyboard
shortcuts with ordinary modifiers are listed: mouse, raw keycode, submap and
device-specific bindings, and the press half of a press/release pair such as
push-to-talk, are left out. If the shortcuts can't be read, the keys and manual
entry still work.

The virtual keyboard replays physical key positions, named for US layouts, so
`A` may type q on AZERTY, and aliases such as `PLUS` can need Shift. Check a
picked shortcut on your layout before relying on it.

Everything is also available from the CLI:

```bash
controller-control doctor          # check permissions, config, and the pad
controller-control devices         # what the kernel sees
controller-control monitor         # print button tokens as you press them
controller-control learn           # record one combo and print its token
controller-control conflicts --json # read advisory overlap context
controller-control list            # show configured bindings
controller-control shortcuts       # replayable live shortcuts as JSON
controller-control keyboard-keys   # standard keyboard keys as JSON
controller-control bind "L + R" --keys SUPER+RETURN --description Terminal
controller-control bind START --exec 'omarchy menu'
controller-control unbind "L + R"
controller-control test "L + R"    # run a binding's action now
controller-control disable         # stop everything firing, keeping bindings
controller-control enable
controller-control toggle
controller-control pause           # transient mute, not written to the config
controller-control pause --resume
```

The binary lives inside the plugin folder; add it to your `PATH` with:

```bash
export PATH="$HOME/.config/omarchy/plugins/co.klair.controller-control/bin:$PATH"
```

## Uninstall

```bash
omarchy plugin disable co.klair.controller-control
omarchy plugin remove co.klair.controller-control
```

Disabling stops the daemon and takes the widget off the bar; removing deletes
the plugin folder. Neither touches your bindings, which live outside the
plugin at `~/.config/controller-control/`. Delete that directory too if you
want it gone completely:

```bash
rm -rf ~/.config/controller-control
```

Nothing else is left behind: no system files, no services, no udev rules, and
the only runtime artefact is a pid file under `$XDG_RUNTIME_DIR` that goes
when the daemon stops.

### What it writes

Only its own files, and only when you ask:

| Path | When |
|---|---|
| `~/.config/controller-control/config.json` | when you add, remove or toggle a binding |
| `~/.config/controller-control/.config.json.lock` | beside it, so two edits cannot overwrite each other |
| `$XDG_RUNTIME_DIR/controller-control.pid` | while the daemon is running |

It does not modify your Hyprland config, your keybindings, or any other
application's settings. Adding the widget to the bar is done by
`omarchy plugin enable`, which is Omarchy's own command and only runs when you
invoke it.

## Button names

Buttons are named by the Linux/evdev convention, which follows the Xbox
layout: `A` is the south face button, `B` east, `X` north, `Y` west. This is
what an Xbox, DualSense or generic pad reports, and it is why the tokens are
named this way rather than after any one manufacturer. Also
available: `L`, `R`, `L2`, `R2`, `SELECT`, `START`, `MODE`, `THUMBL`,
`THUMBR`, `DPAD_UP/DOWN/LEFT/RIGHT`, and stick directions such as
`LSTICK_LEFT`.

Controllers that report a dedicated Linux `BTN_BACK` use `BACK_BUTTON`.
This is independent of gamepad `SELECT` (`BTN_SELECT`). The existing `BACK`
configuration alias still means `SELECT`, so saved bindings keep their meaning;
use `BACK_BUTTON` to bind or remap the dedicated input. This names events on
devices the plugin already selects; it does not enable mouse or media-only
input devices.

Nintendo-layout pads (8BitDo, Switch Pro) put A on the right and B on the
bottom — the opposite of where evdev expects them. Whether that matters
depends on the firmware: an 8BitDo Zero 2 in D-input is **label-faithful**, so
it sends the code for `A` when you press the button printed "A" and nothing
needs swapping. Other pads and other modes are not guaranteed to do this.

So: don't reason about it, measure it. `controller-control learn` (or the
panel's **Record combo**) reports exactly what your pad sends. If your pad
turns out to be position-faithful instead, set `device.layout` to `"nintendo"`
to relabel the face buttons in the UI so they match the plastic.

D-pads arrive as a hat axis and analog triggers as an axis; both are
translated into ordinary button tokens for you. A pad that reports a trigger
both ways holds `L2` until both let go, so easing off the analog side while
the button is still down does not fire it again.

Generic joysticks name their first buttons `TRIGGER` and `TRIGGER_HAPPY1`.
Older builds called them `JOYSTICK` and `TRIGGER_HAPPY`, and a config that
uses those names still works.

### D-pad source

Nearly every controller reports its d-pad on the hat axis, which arrives as
`DPAD_UP/DOWN/LEFT/RIGHT`. Some — 8BitDo pads in D-input mode — send it on the
left stick axes instead, where it arrives as `LSTICK_*`.

Capability sniffing cannot tell these apart: an 8BitDo Zero 2 advertises a hat
it never uses *and* declares its d-pad axes with an analog 0–255 range, so its
descriptor looks exactly like a pad with a real stick. Rather than guess wrong,
this is a setting:

```json
"device": { "dpad_source": "stick" }
```

That renames the stick events to `DPAD_*`, so the ordinary d-pad bindings work
unchanged. It is safe on such pads because they have no separate analog stick
to lose.

The default is `"hat"`, and **nothing in the shipped defaults binds an analog
stick** — on a pad that has one, nudging it to change the volume or move window
focus would be a nasty surprise.

To find out which yours uses, run `controller-control monitor` and press the
d-pad.

### Aliases

Any token can be renamed, which is the escape hatch for a pad that reports
something unusual:

```json
"device": { "aliases": { "THUMBL": "SELECT", "L2": "L" } }
```

## Configuration

`~/.config/controller-control/config.json`:

```json
{
  "version": 1,
  "enabled": true,
  "device": {
    "match": [],
    "exclusive": false,
    "layout": "auto",
    "dpad_source": "hat",
    "aliases": {}
  },
  "settings": {
    "combo_window_ms": 45,
    "hold_ms": 450,
    "repeat_delay_ms": 400,
    "repeat_interval_ms": 110
  },
  "bindings": [
    { "combo": "START", "keys": "SUPER+SPACE", "description": "Omarchy menu" },
    { "combo": "L + R", "exec": "omarchy capture screenshot" },
    { "combo": "DPAD_UP", "keys": "VOLUMEUP", "repeat": true },
    { "combo": "SELECT + START", "keys": "SUPER+CTRL+L", "hold": true }
  ]
}
```

**Bindings** take either `keys` (typed on a virtual keyboard, so Hyprland
handles it exactly like a real shortcut) or `exec` (a shell command). Options:

- `repeat` — fire again while held, for volume and brightness.
- `hold` — only fire after a long press, for anything destructive.
- `enabled: false` — keep a binding around without it firing.

Key names are case-insensitive. Alongside Linux `KEY_*` names, the parser
accepts these aliases (including those supported before the recent additions):

| Use | Accepted names |
|---|---|
| Super | `SUPER`, `META`, `WIN`, `CMD`, `MOD` |
| Other modifiers | `CTRL`, `CONTROL`, `ALT`, `OPT`, `SHIFT` |
| Enter and navigation | `RETURN`, `CR`, `ESCAPE`, `DEL`, `PGUP`, `PGDN`, `RETURN_KP` |
| Print and punctuation | `PRINT`, `PRTSC`, `PRINTSCREEN`, `PERIOD`, `PLUS`, `bracketleft`, `bracketright` |
| Volume | `XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute`, `XF86AudioMicMute` |
| Playback | `XF86AudioPlay`, `XF86AudioPause`, `XF86AudioNext`, `XF86AudioPrev` |
| Display brightness | `XF86MonBrightnessUp`, `XF86MonBrightnessDown` |
| Keyboard lighting | `XF86KbdBrightnessDown`, `XF86KbdBrightnessUp`, `XF86KbdLightOnOff` |
| Other system keys | `XF86Calculator`, `XF86Eject`, `XF86PowerOff` |
| Touchpad | `XF86TouchpadOff`, `XF86TouchpadOn`, `XF86TouchpadToggle` |

These aliases send Linux key codes, not characters. `bracketleft` and
`bracketright` select the physical `LEFTBRACE` and `RIGHTBRACE` keys; the active
keyboard layout determines the resulting symbols and compositor bindings.
Omarchy's own bracket bindings use `code:34` / `code:35`; that raw XKB keycode
syntax is still unsupported. The bracket aliases help hand-written controller
configs rather than accepting those bindings verbatim.

The touchpad aliases emit Linux codes 530–532 (XKB evdev keycodes 538–540).
Those codes have touchpad symbols only in recent xkeyboard-config versions;
on older keymaps the parser can accept a binding that has no effect.

`XF86PowerOff` emits `KEY_POWER` (116), even as part of a controller chord.
With logind's `HandlePowerKey=poweroff`, it can shut the machine down. Omarchy
sets this to `ignore`; check your system's policy before using this key.

**`settings`** are checked when the file loads. Each must be a number, and
values that would make the daemon spin a core — a zero `repeat_interval_ms`
or `rescan_interval_s` — are refused with a message saying which. A config
that will not load leaves the running daemon on its last good one.

**`enabled`** is the master switch. Turning it off keeps every binding and
keeps the pad connected — nothing fires until it goes back on. It is what the
panel toggle and `controller-control disable` write.

**`device.match`** is a list of case-insensitive substrings matched against
the device name. It defaults to empty, which matches any gamepad — narrow it
when you own several pads and only want one of them driving the desktop. A
keyboard-shaped device (an 8BitDo in keyboard mode) is only picked up when you
name it explicitly, so an empty list can never latch onto your real keyboard.
Virtual keyboards from remote-desktop and input tools often claim every key
code there is, joystick buttons included; one with the letter keys and no
axes counts as a keyboard, not a pad. The daemon's own virtual keyboard is
never matched.

**`device.exclusive`** grabs the pad so nothing else — games, Steam, the
browser — sees it. Off by default, so a controller can drive your desktop and
still work in games.

The daemon reloads on `SIGHUP`, which is what the panel, the CLI and
`omarchy-shell controller reload` use, so edits apply without dropping the
Bluetooth connection. It also notices the file changing, so a hand edit
applies within `rescan_interval_s` (two seconds by default). Aliases, the
d-pad source and the analog thresholds apply to a connected pad at once.

## Optional Game and OS modes

Existing installations keep the original behavior until modes are explicitly
enabled. Inspect the saved selection without changing settings:

```bash
controller-control mode --json
controller-control mode game       # enable modes; ordinary controller passthrough
controller-control mode os         # enable modes; exclusive desktop control
controller-control mode disable    # restore the original device.exclusive policy
controller-control mode enable     # restore the saved Game/OS selection (Game initially)
```

Opt-in settings live in `"modes": {"enabled": true, "active": "game"}`. Config
files without this section retain their original serialization. A mode command
saves atomically and asks the running daemon to reload; its JSON describes saved
configuration, not proof that a controller has acquired ownership.

Game mode releases exclusive ownership and runs no desktop actions. Games read
the original controller directly; the plugin creates no replacement controller.
OS mode waits for all selected controllers to be neutral before acquiring
exclusive grabs. If another program owns a controller, desktop output stays
blocked and acquisition retries automatically. Turning the master switch off
releases OS grabs; re-enabling waits for neutral before taking ownership again.
The separate transient capture pause can retain an existing OS grab.

Startup, reconnect, configuration/profile reload, pause/resume and input queue overflow
reset pending chords and close virtual output. Held controls must return to
neutral before actions resume. Snapshot failures keep output blocked. Sticks
must return within 15% of center, triggers within 5% of rest, and hats/buttons
to rest. Current keys are read through `EVIOCGKEY` and axis ranges/values are
queried again; cached hotplug metadata cannot establish neutral state. Those
strict axis thresholds protect grab acquisition only. Once grabbed, logical
button release gates output so sub-threshold drift does not mute controls.
`SYN_DROPPED` discards history through the next `SYN_REPORT` before a fresh
snapshot. With multiple controllers, a shared neutral barrier and reference
counting prevent one controller's release from clearing another's held token.

Daemon events expose `modes_enabled`, `input_mode`, `input_ready`, `input_status`,
`requested_exclusive` and `effective_exclusive`. Status distinguishes legacy,
passthrough, disconnected, disabled, paused, waiting for a grab, waiting for
neutral, and ready. These fields report current effective ownership separately
from the saved requested mode. Per-device state includes snapshot readiness and
an error when a safe snapshot is unavailable.

The mode, recovery and CLI tests use mocked descriptors, snapshots, grabs and
action runners. They do not establish physical hardware, suspend/resume or
sustained-use acceptance, and must not be confused with isolated live input
integration testing.

## Existing compositor mappings

The read-only context helper reports Hyprland bindings that may overlap an
input token:

```bash
controller-control conflicts --json
```

Run it in the active Hyprland session. It returns
JSON with `available`, `bindings` and `error`. Each binding includes a mapper
`token`, numeric evdev `code`, original `key`, `description`, modifier bitmask,
`submap` and `kind: "compositor"`. XKB keycodes are converted with the evdev
plus-eight offset; `mouse:` codes are already evdev codes. Raw mouse Back is
reported as `BACK_BUTTON`, preserving the legacy config alias `BACK → SELECT`.

Choose **Check Hyprland shortcuts** on the Advanced tab, or the reload button,
to read this advisory context. Merely opening the editor does not query it. It shows
only mappings matching a selected draft input or a saved controller input,
applying `device.aliases` once just as the input decoder does. A label such as
`A → B` preserves both the raw compositor identity and the recorded mapper
identity. Modifier names and submaps remain visible. Loading, an unavailable
read and a successful empty result have distinct messages; refresh does not
execute a binding or change controller settings.

These entries describe potential overlap, not confirmed duplicate actions.
Modifiers, submaps, input grabs and application behavior affect whether an
external action fires. Named key aliases are best-effort physical key matches;
the active keyboard layout can change the identity of a symbol binding. Native
application mouse behavior is not enumerated. An unavailable read is reported
separately from a successful read containing no bindings. The helper never
selects a different session, changes compositor mappings or writes mapper
settings.

### Named OS mapping profiles

Profiles keep several sets of OS button mappings and pointer settings. They do
not change the global mode, device matching, exclusive setting, master switch or
chord timing. Game Mode remains passthrough; selecting an OS profile while in
Game Mode only changes which mappings will be ready when you return to OS Mode.

The **Profiles** section of the Advanced tab chooses an existing profile. Enter a name
and choose **Create profile** to keep a separate copy and select it, or **Rename
current** to change its name. Finish or Clear a binding draft first, and Apply
or Reset unsaved pointer settings. Game Mode shows a read-only passthrough
summary with the remembered OS profile. **Delete profile** offers a target
selector and separate **Confirm delete** / **Cancel** controls. For the active
target, choose its replacement. Inactive deletion keeps the current profile.

```bash
controller-control profile list --json
controller-control profile create Travel  # clone current mappings and select Travel
controller-control profile use Current
controller-control profile rename Travel Couch
controller-control profile delete Couch  # remove an inactive profile
controller-control profile delete Current --switch-to Travel  # active replacement
```

Existing configs remain in their original single-profile structure until a
successful explicit profile operation. Listing profiles shows an implicit
`Current` without writing or migrating anything. Creating the first new profile
keeps the original mappings in `Current` and selects a separate clone. Names
are trimmed, case sensitive, limited to 64 characters and cannot contain control
characters. Deleting the active profile requires an explicit replacement; the
last remaining profile cannot be deleted.

Profile operations save one config atomically, then notify the daemon to reload.
Adding or removing a binding edits the active profile. Its `bindings` and
`pointer` remain at the top level for compatibility, alongside:

```json
"profiles": {
  "active": "Travel",
  "mirror_of": "Travel",
  "items": {
    "Current": {"bindings": [], "pointer": {}},
    "Travel": {"bindings": [], "pointer": {}}
  }
}
```

Top-level bindings and pointer settings remain compatibility mirrors of the
active profile. Saved files record `profiles.mirror_of` to identify their owner.
Changing only `profiles.active` is rejected if that owner differs, and old files
without ownership are rejected when the mirrors disagree with the selected
snapshot. This prevents another profile from being overwritten on the next save.
Use `controller-control profile use NAME` to switch atomically. All inactive
profiles are validated too.

## How chords are resolved

- Bindings fire on **press**. A chord that has fired never fires one of its
  parts on release, so letting go of `L + R` cannot also trigger `R`.
- When the buttons held could still grow into a longer binding, the decision
  waits `combo_window_ms`. When no longer binding could match, it fires
  instantly — single presses have no added latency.
- A quick tap still counts: let go of `L` before that window closes and `L`
  fires as you release it.
- A press only looks at bindings that use the button just pressed, so holding
  one button — the d-pad repeating volume, say — never stops another firing.
- A binding that has fired is latched until one of its own buttons is
  released, so holding a chord does not retrigger it.
- With two pads connected, a button is held until both let go, and one pad
  coming or going leaves a chord in progress on the other alone.

This means `A` and `A + B` can coexist: tapping `A` fires `A`, and pressing
both fires only `A + B`.

## IPC

```bash
omarchy-shell controller status    # JSON: running, connected, enabled, paused, …
omarchy-shell controller reload    # re-read the config
omarchy-shell controller restart   # bounce the daemon
omarchy-shell controller disable   # master switch off
omarchy-shell controller enable
omarchy-shell controller toggle
```

The daemon publishes its pid to `$XDG_RUNTIME_DIR/controller-control.pid` so
the CLI can signal a daemon the shell started. It is verified against `/proc`
before anything is sent to it — a pid file can go stale and the number be
recycled, and signalling the wrong process is the kind of mistake that stays
invisible until it does damage.

## Architecture

```
omarchy-shell (Quickshell)
├── Service.qml      runs the daemon, parses its JSON event stream, IPC
├── BarWidget.qml    connection glyph, pulses on fire
├── Panel.qml        popup/window ownership
└── EditorContent.qml shared bindings editor with press-to-record capture
        │
        └── bin/controller-control daemon
                └── engine/   pure-stdlib evdev reader + chord recogniser
```

The daemon reads `/dev/input/event*` directly and emits one JSON object per
line, which is what the QML layer consumes — including the whole binding list
after every load, so the panel never reads the config file or runs anything
to open. `keys` actions are typed on a uinput virtual keyboard, so the
compositor treats them as a real keyboard.

The shell holds the daemon's stdin open (`daemon --exit-with-stdin`), and the
daemon exits when it closes. A shell that crashes therefore cannot leave a
daemon behind to fire every press twice beside the next one. If the daemon
itself keeps failing, restarts back off from three seconds to a minute.

Device inspection is cached per device node: opening an input node blocks for
around 20ms in the kernel, so re-inspecting every node to spot a hotplug would
stall the daemon's timers. Listing the nodes is a sub-millisecond glob, and
only genuinely new nodes are opened.

## Tests

Parser, Back identity/config, chord, config, device-decoding and action
checks do not open input devices:

```bash
python3 -m unittest discover -s tests -p test_key_aliases.py -v
python3 -m unittest discover -s tests -p test_back_button.py -v
python3 -m unittest discover -s tests -p test_combos.py -v
python3 -m unittest discover -s tests -p test_config.py -v
python3 -m unittest discover -s tests -p test_devices.py -v
python3 -m unittest discover -s tests -p test_actions.py -v
python3 -m unittest discover -s tests -p test_profile_integration.py -v
python3 -m unittest discover -s tests -p test_profiles.py -v
python3 -m unittest discover -s tests -p test_pointer_integration.py -v
python3 -m unittest discover -s tests -p test_native_modes.py -v
python3 -m unittest discover -s tests -p test_catalog.py -v
python3 -m unittest discover -s tests -p test_keyboard_catalog.py -v
python3 -m unittest discover -s tests -p test_conflicts.py -v
```

The isolated editor check uses the installed Omarchy UI kit and Quickshell
offscreen, with a fake CLI/service, temporary home/runtime and no session bus.
It opens no input devices and does not start the daemon. Only the Wayland
layer-shell wrapper is replaced; the form, window and controls are real:

```bash
python3 tests/check_editor.py
```

The end-to-end tests create real virtual controllers visible to other
applications. Run them only where generated input cannot reach desktop
applications. The daemon's `--dry-run` suppresses mapped output actions only;
it does not isolate the synthetic controller's input.

```bash
python3 -m unittest discover -s tests -v
```

The end-to-end suite drives the real daemon with
synthetic gamepads to cover chords, hotplug, disconnect, repeat, hold, two
pads at once, hand edits to the config, and recovery from events the kernel
dropped. Dedicated Back coverage includes legacy binding save/reload,
independent actions/chords, and a second evdev reader on a nonexclusive
device. These fixtures need write access to `/dev/uinput` and read access to
generated `/dev/input/event*` nodes (for example, membership in `input`). The
dedicated Back fixture can be classified as a mouse; access granted
only to joystick devices is insufficient.


## Optional OS pointer and scrolling

`engine.pointer` is a separate, disabled-by-default backend for the native mode
integration. Importing it or validating settings never opens an input device.
`PointerController` takes validated `PointerSettings` (or a settings object) and
an optional output sink. The caller must run `tick(now, axes, held,
blocked_tokens=(), allowed=False)` on idle timer ticks as well as input events.
`now` is monotonic seconds; `axes` maps raw ABS_X/Y (0/1) and ABS_RX/RY (3/4) to
values in -1..1; `held` contains the current aliased button tokens.

`allowed` must combine OS Mode, the master switch, connection readiness and
capture/pause policy. Game Mode passes `allowed=False`, which releases drags,
clears fractional motion and releases dragging. The prepared mouse is retained
across ordinary transitions and destroyed on shutdown or output failure.
Call `reset()` after changing device, aliases, profiles or pointer settings.
Activation ignores buttons already held until release and requires each stick
to return within its dead zone. This prevents clicks and jumps during a mode
change. A scheduling stall contributes at most 50 milliseconds of motion.

The settings are `enabled` (false), `pointer_stick` (`left`), `scroll_stick`
(`right`), `speed` (900 pixels/second, 1–4000), `scroll_speed` (8 steps/second,
1–60), `dead_zone` (0.18), `scroll_dead_zone` (0.35), `invert_scroll` (false) and
`buttons` (`{"A":"left","B":"right"}`). Stick selectors also accept `none`;
the two active roles cannot share a stick. Dead zones must be at least zero and
less than 0.95. Button names use normal aliases and support custom single-token
alias targets; actions are only `left` and `right`, and an empty map is valid.

Saved bindings take precedence. Supply all claimed final button tokens in
`blocked_tokens`. Also include raw `LSTICK_*`/`RSTICK_*` directions whose aliases
are claimed: any saved direction reserves its entire physical stick. The caller
must preserve that raw provenance when aliases or a stick-backed d-pad rename
those directions. Blocking a held click releases it; unblocking still requires
a fresh press. Releasing a reserved stick requires neutral before motion.

Movement uses radial dead zones, quadratic acceleration and fractional distance
accumulation. Diagonal speed is capped to the configured speed. Horizontal
scrolling is positive to the right; downward stick movement sends negative
vertical wheel steps. Inversion reverses both wheel directions.

`VirtualPointer` lazily creates a mouse-only uinput device with relative X/Y,
vertical/horizontal wheels and left/right buttons. It attempts held-button
release before destruction, including output errors. Dry-run integration must
explicitly inject `NullPointer`; a CLI dry-run flag alone is not isolation.
The pure backend fixtures mock every uinput syscall:

```bash
python3 -m unittest discover -s tests -p test_pointer.py -v
```

They exercise motion timing, dead zones, scrolling, saved-binding priority,
activation guards, drag cleanup and Linux event packing without creating input
devices. Physical pointer feel and actual compositor delivery need isolated
integration and later device acceptance.


The editor's **Pointer and scrolling** section keeps changes as a draft. Enable
it, choose different pointer/scroll sticks (or None), adjust speed and dead-zone
percentages, and set one controller token for each click. **Apply settings**
saves the draft; **Reset edits** restores the last confirmed values. Existing
additional click assignments are preserved. Saved controller shortcuts continue
to override overlapping pointer buttons and stick directions.

Changing fields does not enable output. Pointer controls require native mode
switching and OS Mode; Game Mode shows an inactive summary. The editor explains
when multiple connected controllers require a narrower selection or pointer
output fails. It preserves unsaved settings across refreshes and serializes
mode, binding and pointer writes. The isolated editor fixture checks those
controls, Apply/Reset, error retention and simultaneous-write guards without
starting a daemon or creating an input device.

Overlap rows use the current face-button labels and skip disabled saved mappings.
When the daemon reports an actual exclusive grab, the overlap message explains
that physical events are owned by the plugin. Missing identities in Hyprland
0.56.2 are counted rather than presented as an all-clear.

The daemon’s `bindings` event includes saved `modes`; the form follows that
snapshot, including edits made through another CLI/IPC client. Game capture is
not gated by small stick drift. Strict physical centering protects acquisition
of an exclusive grab; after acquisition, the OS output barrier waits for logical
buttons to be released. Waiting reports include held input/axis values.
Bindings-only edits apply settings in place without reopening pad descriptors or
destroying the prepared keyboard. Fast retries run only while an enabled,
unpaused OS controller is connected and waiting for a grab; config stat checks
keep the normal rescan frequency. In native mode, disconnecting any participant
resets the shared chord and requires all remaining pads to release held input.

Default clicks use L2/R2 because the shipped A/B mappings already claim those
recorded tokens. Saved mappings win; mouse-button reservations use recorded
aliases, while raw stick reservations cover the corresponding whole stick.
Idle neutral pointer settings do not request 60 Hz polling. Frame ticks run for
active motion, fractional output or a pending nonblocking device settle. A zero
dead zone still accepts the normalized one-count center quantization of a
16-bit axis. Pointer-only edits retain controller and virtual mouse objects,
and release failures are reported without terminating the input daemon.
The `bindings` event includes canonical saved `pointer` settings, which keeps
other CLI/client edits visible without separate getter processes.

The `bindings` event also includes `profiles: {active, names}`; the editor uses
that authoritative daemon snapshot and does not poll profile getters. Recording
is blocked during queued binding or settings writes. Profile names allow joined
emoji while rejecting control characters; `bindings: null` follows the existing
legacy default-binding policy. This change also preserves unknown top-level
config fields and rejects duplicate JSON keys, preventing ambiguous profile
objects or forward-compatible fields from being silently discarded.

Searchable picker popups reserve scroll space in the editor and size their
result viewport to the window, including short windows. The installed shared
UI control supplies search, result clipping and keyboard behavior.

## License

MIT
