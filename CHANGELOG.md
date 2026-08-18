# Changelog

All notable changes to `ubuntu-rdp-setup.sh`. This file mirrors the `CHANGELOG`
comment block in the script header — keep both in sync when releasing.

Format: [Keep a Changelog](https://keepachangelog.com/). Versioning: [SemVer](https://semver.org/).

## [1.3.0] - 2026-08-19

### Fixed
- **CRITICAL: the reaper was killing live desktop sessions.** Reaper 1.0.0
  determined whether a client was attached by correlating ESTABLISHED TCP
  connections on port 3389 back to an X display, through the connection
  process cmdline, its children, and its environment. Measured on a live,
  actively-used session on Ubuntu 24.04 / xrdp 0.9.24, all three sources are
  empty: the connection process has cmdline `/usr/sbin/xrdp`, no children, no
  `DISPLAY` in environ, and no fds referencing X sockets. `attached_displays()`
  therefore always returned an empty set, every live session was classified as
  a zombie, and the reaper killed working desktops 120 seconds after login --
  taking the browser and unsaved work with it.

### Changed
- Reaper 1.1.0 determines liveness from the **process tree** instead. A live
  session has its `Xorg` parented to a per-session `xrdp-sesman`; a genuinely
  orphaned one is reparented to PID 1. Verified against a live session: the new
  logic reports `LIVE xpid=55486 parent=xrdp-sesman(55484)` where the old logic
  reported "no client".
- **Design rule:** the reaper no longer tries to out-guess sesman about who is
  connected. Disconnect handling belongs to sesman via `KillDisconnected=true` +
  `DisconnectedTimeLimit=60`. The reaper now handles only what sesman cannot:
  orphaned processes, on-disk debris, and a dead listener. It is deliberately
  conservative -- an unknown parent process is treated as live, because a missed
  zombie costs one manual cleanup while a wrongly-killed session costs the user
  their work.
- `startwm.sh` no longer deletes `~/.cache/sessions` on every login. It prevented
  a rare stale-session black screen at the cost of making desktop session
  restore permanently impossible. That cleanup now runs only at boot, from
  `xrdp-boot-cleanup.service`, where no session can be live.
- Dropped the pointless `GNOME_SHELL_SESSION_MODE` export from `~/.xsessionrc`.

### Added
- `xrdp-session-reaper --status`: a read-only snapshot printing every display
  and its verdict (LIVE / ORPHAN / EMPTY) with the parent process that justified
  it. Run this to confirm the reaper agrees with reality before trusting it.

## [1.2.0] - 2026-08-19

### Fixed
- **Login screen rendered as a solid coloured rectangle with no username or
  password box.** Versions 1.0.0-1.1.0 wrote `/etc/xrdp/xrdp.ini` from scratch
  and defined only two `ls_*` keys (`ls_title`, `ls_top_window_bg_color`). xrdp
  draws its login window from a *complete* block of `ls_*` geometry keys
  (`ls_width`, `ls_height`, `ls_label_x`, `ls_input_x`, `ls_btn_ok_*`,
  `ls_logo_filename`, and more). A partial set sends xrdp down the
  custom-login-screen code path with zero widget geometry: the background paints
  and the widgets do not. The hand-written file also silently dropped the
  bitmap and font resource references under `/usr/share/xrdp`.

### Changed
- `xrdp.ini` and `sesman.ini` are now **patched in place**, key by key, via a new
  `ini_set()` helper (awk-based, plain string matching, no dynamic regexes). It
  replaces existing or commented-out entries in place and preserves every other
  line, comment and blank line. Verified idempotent.
- Added `restore_distro_ini()`: detects a hand-written config left by 1.0.0 or
  1.1.0 and restores the pristine file from the oldest timestamped backup, or
  extracts it from the `xrdp` `.deb` if no backup survives.
- Removed all login-screen cosmetic customization. The distro login screen is
  left completely untouched.

### Added
- Two verification checks in stage 10 that fail if `ls_logo_filename` or
  `ls_width` is missing from `xrdp.ini` — a regression guard for exactly this
  bug.

### Upgrading
Re-run the script; it repairs `xrdp.ini` automatically. To fix by hand instead:
`sudo cp /etc/xrdp/xrdp.ini.bak.* /etc/xrdp/xrdp.ini && sudo systemctl restart xrdp`

## [1.1.0] - 2026-08-18

### Changed
- **Removed the source-IP restriction prompt in stage 09.** Port 3389 is now
  opened to any address. Rationale: the operator connects from changing
  addresses (roaming laptop, mobile tethering, CGNAT), so a UFW allow-list locks
  them out more often than it stops an attacker. Brute-force defence is the
  fail2ban jail; the transport is TLS. UFW still defaults to deny-incoming, so
  only 22 and 3389 are reachable.
- Stage 09 now warns explicitly that 3389 is internet-facing and that the
  account password is the primary control. The manual lock-down commands are
  documented inline in the script and in the README.

## [1.0.0] - 2026-08-18

### Added
- Initial release. Ubuntu 24.04 LTS (noble), amd64 and arm64.
- 11-stage installer (00 preflight through 10 verify), each stage an
  independently re-runnable shell function.
- **Spec-driven desktop recommendation**: inspects vCPU/RAM/disk and pre-selects
  XFCE (<=2 vCPU or <=4 GB), MATE (3-4 vCPU, 6-8 GB) or GNOME Flashback
  (>=4 vCPU and >=12 GB). Stock GNOME Shell is deliberately not offered
  (Wayland/mutter over xorgxrdp is the top black-screen cause).
- **Interactive-only credential creation.** No env-var or flag bypass, by
  design: this box is internet-facing on 3389 and a password passed as an
  argument lands in the shell history, the process table and the logs.
- **Zombie-session reaper** (`/usr/local/sbin/xrdp-session-reaper`), the core
  feature — four defence layers:
  - L1 `sesman.ini`: `Policy=UBDI`, `KillDisconnected=true`,
    `DisconnectedTimeLimit=60`, `IdleTimeLimit=0`.
  - L2 `startwm.sh`: unsets `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`,
    `SESSION_MANAGER`; forces X11 backends; clears stale saved sessions.
  - L3 `xrdp-session-reaper.timer`: 60 s sweeps that detect clientless displays
    (via ESTABLISHED sockets on 3389 mapped to displays), apply a 120 s grace
    period, then SIGTERM/SIGKILL the session tree and delete the debris.
  - L4 `xrdp-boot-cleanup.service`: oneshot wipe ordered `Before=xrdp.service`,
    so any crash or hard reboot still yields a working first login.
- Reaper self-heal: restarts `xrdp`/`xrdp-sesman` if 3389 stops listening or
  either unit enters a failed state.
- TLS for XRDP: self-signed 10-year cert, `security_layer=tls`,
  `crypt_level=high`, TLSv1.2/1.3, correct `root:ssl-cert 640` ownership.
- TCP keepalive tuning (120/20/3) so vanished clients are detected in ~3 min
  instead of ~2 h.
- `Restart=always` systemd drop-ins for `xrdp` and `xrdp-sesman`.
- Polkit rule suppressing the colord/packagekit auth dialogs that pop up on
  every XRDP login.
- `Xwrapper.config` set to `allowed_users=anybody` (required: XRDP users are
  never on a physical VT).
- Google Chrome from the official apt repo via a `signed-by` keyring (apt-key is
  removed in 24.04), plus `/usr/local/bin/google-chrome-rdp` setting
  `--password-store=basic --disable-gpu --disable-dev-shm-usage
  --ozone-platform=x11`, and an enterprise policy JSON that removes the
  first-run noise. Falls back to Chromium on non-amd64.
- Security stage: UFW (deny incoming by default, SSH + RDP allowed), plus a
  fail2ban filter and jail for `xrdp-sesman` auth failures
  (5 failures / 10 min -> 1 h ban).
- Verification stage: 11 health checks, a dry-run reaper sweep, and a summary
  banner with the public IP, username, desktop and operator commands.
- Idempotency: stage state in `/var/lib/xrdp-setup/state`, timestamped backups
  of every config file touched, `--force` to re-run everything. Stages 06 and 08
  always re-apply so a re-run repairs a broken config.
- Robustness: `set -Eeuo pipefail` with a trap naming the failing stage and
  line; apt lock wait loop (unattended-upgrades on first boot); 3x apt retry
  with `dpkg --configure -a` recovery; full audit log at
  `/var/log/xrdp-setup.log`; logrotate for both logs.
- Flags: `--dry-run`, `--de=`, `--skip-upgrade`, `--force`, `--version`,
  `--help`.
- Display managers pulled in as dependencies are disabled and the boot target
  is set to `multi-user`, saving RAM and avoiding VT contention with XRDP.
