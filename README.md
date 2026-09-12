<!--
SPDX-FileCopyrightText: © 2020 The River Developers
SPDX-FileCopyrightText: © 2026 codethare
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
  <img src="logo/logo_text_adaptive_color.svg" width="600em">
</div>

## Overview

River is a non-monolithic Wayland compositor. Unlike other Wayland compositors,
river does not combine the compositor and window manager into one program.
Instead, users can choose any window manager implementing the
[river-window-management-v1] protocol.

Read my blog post, [Separating the Wayland Compositor and Window Manager](https://isaacfreund.com/blog/river-window-management/),
for an in-depth explanation.

There is a [list of compatible window managers] on our [wiki](https://codeberg.org/river/wiki).

> *If you are looking for the old dynamic tiling version of river, see
[river-classic](https://codeberg.org/river/river-classic).*

## Fork

This repository is a fork of [river](https://codeberg.org/river/river) that adds
compositor-side touchpad gesture bindings: **3-finger and 4-finger swipes are
consumed by the compositor** and turned into key press/release events instead of
being forwarded to apps as pointer gestures. Direction is resolved from the
accumulated swipe delta (honoring each touchpad's natural scroll sense) and
mapped to a reserved keysym:

| fingers | up | down | left | right |
|---------|----|------|------|-------|
| 3       | F1 | F2   | F3   | F4    |
| 4       | F5 | F6   | F7   | F8    |

Because the synthesized keys go through river's existing keybinding stack, any
window manager (or riverctl binding) can bind them like ordinary keysyms. Holds
are sustained presses: 3 fingers press `BTN_SIDE` (0x113), 4 fingers press F10.
Four-finger pinch-in/out fire F12/F11.

The mapping defaults to the table above and can be overridden in
`$XDG_CONFIG_HOME/river/gestures.conf` (or `~/.config/river/gestures.conf`),
which is read at startup and re-read whenever river receives SIGHUP:

```
# gestures.conf
enabled = true
3up = F1
3left = F3
3right = button:0x116
4right = F8
hold3 = button:0x113
hold4 = F10
pinch3in = none
pinch4in = F12
pinch4out = F11
```

Keys are `enabled`, `swipe_threshold`, `pinch_threshold`,
`<3|4><up|down|left|right>`, `hold<3|4>` and `pinch<3|4><in|out>`. Any binding
takes an xkbcommon keysym name (case insensitive), a mouse button as
`button:<evdev code>`, or `none` to unmap, so a gesture can fire either a window
manager key binding (keysym) or one of its pointer bindings (mouse button); the
two thresholds take numbers. Malformed lines are logged and skipped, and a
missing file leaves the defaults in place. A commented sample listing every key
with its default is
shipped in `doc/gestures.conf`; see
`river/gesture_config.zig` for the parser and `tasks/plan-gesture-radius.md` for
the design rationale.

Window borders are drawn with rounded outer corners (radius up to 10px,
clamped per window so the square content corners stay inside the arc) using
scene rects for the edges and small anti-aliased corner textures. The radius is
the `border_radius` key of the same config file, and the clamp ties it to the
border width: 3px caps it at 11, 4px at 15 and 6px at 22, so a larger radius
needs a wider border. See `SPEC-rounded-window-borders.md` for the design
rationale.

## Links

- [Protocol Docs](https://isaacfreund.com/docs/wayland/)
- [tinyrwm](https://codeberg.org/river/tinyrwm) example window manager
- [Wiki](https://codeberg.org/river/wiki)
- IRC: [#river](https://web.libera.chat/?channels=#river) on irc.libera.chat ([logs](https://libera.catirclogs.org/river))
- [Zulip](https://river-compositor.zulipchat.com) (new)
- [Issue Tracker](https://codeberg.org/river/river/issues)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Features

River defers all window management policy to a separate window manager
implementing the [river-window-management-v1] protocol. This includes window
position/size, pointer/keyboard bindings, focus management, window decorations,
desktop shell graphics, and more.

River itself provides frame perfect rendering, good performance, support for
many Wayland protocol extensions, robust Xwayland support, the ability to
hot-swap window managers, and more.

The [river-window-management-v1] protocol and other river protocol extensions
are stable.  We do not break window managers.

## Motivation

Why split the window manager to a separate process?

- Significantly lower the barrier to entry for writing a Wayland window manager.
- Allow implementing Wayland window managers in high-level garbage collected
  languages without impacting compositor performance and latency.
- Allow hot-swapping between window managers without restarting the compositor
  and all Wayland programs.
- Promote diversity and experimentation in window manager design.

## Building

Note: If you are packaging river for distribution, see [PACKAGING.md](PACKAGING.md).

To compile river first ensure that you have the following dependencies
installed. The "development" versions are required if applicable to your
distribution.

- [zig](https://ziglang.org/download/) 0.16
- wayland
- wayland-protocols
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20
- xkbcommon 1.12 or newer
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:
```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```
To enable Xwayland support pass the `-Dxwayland` option as well.
Run `zig build -h` to see a list of all options.

## Usage

River can either be run nested in an X11/Wayland session or directly
from a tty using KMS/DRM. Simply run the `river` command.

On startup river will run an executable file at `$XDG_CONFIG_HOME/river/init`
if such an executable exists. If `$XDG_CONFIG_HOME` is not set,
`~/.config/river/init` will be used instead.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs.

See also:

- The `river(1)` man page
- The [wiki FAQ](https://codeberg.org/river/wiki)
- The [list of compatible window managers]
- The [list of useful companion software]

## Strict No LLM / No AI Policy

Use of generative AI/LLMs is strictly forbidden for all contributions to river.

This includes bug reports and comments on the issue tracker.

## Hacking

See [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the code base.

See [CONTRIBUTING.md](CONTRIBUTING.md) for information on submitting patches.

## Donate

If my work on river adds value to your life please consider setting up a
recurring donation through [liberapay]. This is the best way to make river's
development sustainable in the long term.

You can also support me with a one-time or monthly donation on [github sponsors]
or [ko-fi] though I prefer liberapay as it is run by a non-profit.

Thank you for your support!

## Funding

River is funded in part through the [NGI0 Commons Fund](https://nlnet.nl/commonsfund),
a fund established by NLnet with financial support from the European
Commission's [Next Generation Internet](https://ngi.eu/) programme.

Learn more at the [NLnet project page](https://nlnet.nl/project/River-protocol/).

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information.

In overview:

- River's source code is released under the GPL-3.0-only license.
- River's Wayland protocols are released under the MIT license.
- River's logo and documentation are released under the CC-BY-SA-4.0 license.

[river-window-management-v1]: https://isaacfreund.com/docs/wayland/river-window-management-v1
[liberapay]: https://liberapay.com/ifreund
[github sponsors]: https://github.com/sponsors/ifreund
[ko-fi]: https://ko-fi.com/ifreund
[list of compatible window managers]: https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md
[list of useful companion software]: https://codeberg.org/river/wiki/src/branch/main/pages/useful-software.md
