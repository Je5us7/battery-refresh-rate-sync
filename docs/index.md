# Documentation

`refresh-rate-sync` switches the monitor refresh rate between *plugged in*
(max Hz) and *on battery* (60 Hz), using a udev trigger and short-lived
`systemd --oneshot` services.

| Document | What is in it |
| -------- | ------------- |
| [architecture.md](architecture.md) | The trigger chain, why idle cost is zero, what each file does |
| [configuration.md](configuration.md) | Every option in `/etc/refresh-rate-sync.conf`, with examples |
| [compatibility.md](compatibility.md) | Desktops, backends, command lines used, edge cases |
| [installing.md](installing.md) | Installer options, one-liner install, packaging, other distros |
| [troubleshooting.md](troubleshooting.md) | Nothing happens / no notification / wrong rate / how to debug |
| [development.md](development.md) | Data flow, the normalized mode list, adding a new backend |

Quick links:

* Source and issue tracker: <https://github.com/OWNER/refresh-rate-sync>
* Everything you need to run it: `./install.sh` (it asks for root itself)
* Live log of what it does: `journalctl -t refresh-rate-sync -f`
