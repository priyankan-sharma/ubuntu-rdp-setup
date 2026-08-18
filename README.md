# ubuntu-rdp-setup

**Turn a bare Ubuntu 24.04 LTS server into an RDP-accessible desktop with Google Chrome — and keep it working.**

One script. Run it once. It updates the system, installs a desktop, installs and configures XRDP,
installs Chrome, creates your login interactively, locks down port 3389, and installs a **zombie-session
reaper daemon** so XRDP never black-screens on you again.

Current version: **1.4.0**

---

## Quick start

On the fresh server:

```bash
wget -O setup.sh https://raw.githubusercontent.com/priyankan-sharma/ubuntu-rdp-setup/main/ubuntu-rdp-setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

Then connect with any RDP client:

- **Windows:** `mstsc.exe` → `your.server.ip:3389`
- **macOS:** Microsoft Remote Desktop
- **Linux:** Remmina / FreeRDP

> **Do not pipe the script into bash** (`curl ... | bash`). It prompts for a password, and piping
> makes stdin unavailable — the script detects this and refuses to run, but download-then-run is the
> only supported path.

---

## What it installs

| Stage | What happens |
|---|---|
| 00 | Preflight: root check, OS check, disk check, apt-lock wait, logging to `/var/log/xrdp-setup.log` |
| 01 | `apt update` + full `dist-upgrade` + autoremove |
| 02 | Detects vCPU/RAM/disk and **recommends a desktop based on your specs** |
| 03 | **Interactively prompts** for the RDP username and password |
| 04 | Installs XFCE, MATE, or GNOME Flashback (Xorg — never Wayland), plus fonts for all 14 Indian scripts, Noto and emoji |
| 05 | Installs `xrdp` + `xorgxrdp` |
| 06 | The fail-proof XRDP config — `xrdp.ini`/`sesman.ini` patched in place, plus `startwm.sh`, polkit, sysctl, systemd drop-ins |
| 07 | Google Chrome from the official apt repo, plus a VPS-tuned launcher wrapper |
| 08 | **The zombie-session reaper** — systemd timer (60 s) + boot-time cleanup unit |
| 09 | UFW (SSH + RDP open, everything else denied), fail2ban jail for XRDP brute force |
| 10 | Health checks + a summary banner with your connection details |

### Desktop recommendation matrix

The script inspects the server and pre-selects a default; press Enter to accept, or pick another.

| Detected specs | Recommended | Why |
|---|---|---|
| ≤ 2 vCPU **or** ≤ 4 GB RAM | **XFCE** | Lightest, fastest over RDP, the most XRDP-proven stack |
| 3–4 vCPU, 6–8 GB RAM | **MATE** | Nicer looking, still Xorg-native and light |
| ≥ 4 vCPU **and** ≥ 12 GB RAM | **GNOME Flashback** | GNOME look and apps on Xorg + Metacity |

Stock GNOME Shell is deliberately **not** offered. It defaults to Wayland, and mutter over `xorgxrdp`
is the single largest cause of black screens and session crashes.

---

## The zombie-session problem (and how this fixes it)

**The symptom.** You connect over RDP, then your client dies without logging out — network drop, laptop
lid, client crash, you closed the window. Next time you connect you get a **black screen**, or the RDP
window **closes two seconds after you type your password**.

**The cause.** `xrdp-sesman` leaves behind an orphaned `Xorg` still owning display `:10`, orphaned
`xrdp-chansrv` / `xrdp-sessvc` processes, an orphaned per-session `dbus-daemon`, and stale
`/tmp/.X11-unix/X10` sockets, `/tmp/.X10-lock` files, `~/.Xauthority` cookies and `~/.cache/sessions`
saved state. The next login collides with all of it.

**The fix — four independent layers**, so no single failure can break RDP:

| Layer | Mechanism | What it catches |
|---|---|---|
| **L1** | `sesman.ini`: `Policy=UBDI`, `KillDisconnected=true`, `DisconnectedTimeLimit=60` | sesman tears the session down itself 60 s after a clean disconnect, and a new connection never inherits a half-dead session |
| **L2** | `startwm.sh` unsets `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `SESSION_MANAGER`; forces X11 backends | The "window closes right after login" bug |
| **L3** | `xrdp-session-reaper` on a 60 s systemd timer | Hard drops where sesman never notices: kills the whole process tree and deletes every piece of debris |
| **L4** | `xrdp-boot-cleanup.service`, ordered `Before=xrdp.service` | Any crash or hard reboot — at boot all debris is stale by definition, so it is wiped before xrdp starts |

Plus TCP keepalive tuning (`120/20/3` instead of the 2-hour default) so the kernel notices a vanished
client in ~3 minutes rather than ~2 hours, and `Restart=always` drop-ins on `xrdp` and `xrdp-sesman`.

### How the reaper decides what to kill

1. Enumerate candidate displays from running `Xorg`/`Xvnc` processes and `/tmp/.X11-unix/X*` sockets —
   only displays ≥ 10, so `:0` is never touched.
2. For each display, look at the X server's **parent process**:
   - parent is a live `xrdp-sesman` → **LIVE**, never touched
   - parent is PID 1 (reparented to init) → **ORPHAN**, candidate for reaping
   - no X server at all → **EMPTY**, clean the debris
3. An orphan must stay orphaned for a **120 s grace period** across consecutive sweeps before it is
   reaped, so the reaper never races sesman's own teardown.
4. Then: `SIGTERM` the tree → wait 5 s → `SIGKILL` survivors → delete the debris.
5. Self-heal: if nothing is listening on 3389, or `xrdp`/`xrdp-sesman` is failed, restart them.

> **Why not detect disconnected clients?** v1.0.0 tried, by mapping ESTABLISHED connections on 3389 to
> displays. On Ubuntu 24.04 that mapping does not exist — the xrdp connection process has no display in
> its cmdline, no children, and no `DISPLAY` in its environment — so every live session looked
> clientless and got killed. Disconnect handling belongs to sesman (`KillDisconnected=true`), which is
> the mechanism designed for it. The reaper is deliberately conservative and treats anything it does not
> recognise as live.

Safety rules baked in: never `:0` or any display below 10, never PID 1, and never a process that is not
owned by a real user (uid ≥ 1000) or the `xrdp` service user.

### Operating the reaper

Snapshot every display and the reaper's verdict for it (read-only, changes nothing):

```bash
sudo xrdp-session-reaper --status
```

```bash
sudo xrdp-session-reaper --dry-run --verbose
```

```bash
tail -f /var/log/xrdp-reaper.log
```

```bash
systemctl status xrdp-session-reaper.timer
```

Options: `--status`, `--dry-run`, `--verbose`, `--cleanup-only`, `--grace=N`, `--version`, `--help`.

---

## Script flags

| Flag | Effect |
|---|---|
| `--dry-run` | Print every action, change nothing |
| `--de=xfce\|mate\|gnome` | Skip the desktop prompt |
| `--skip-upgrade` | Skip stage 01 (much faster re-runs) |
| `--force` | Ignore the state file, re-run every stage |
| `--version` / `--help` | Self-explanatory |

The script is **idempotent**: completed stages are recorded in `/var/lib/xrdp-setup/state`, every config
file is backed up to `<file>.bak.<epoch>` before being touched, and re-running is always safe. Stages 06
(XRDP config) and 08 (reaper) are always re-applied, so a re-run repairs a broken configuration.

---

## Hosting it on a free endpoint

### Option A — GitHub raw (recommended)

1. Create a **public** repo, e.g. `ubuntu-rdp-setup`.
2. Commit `ubuntu-rdp-setup.sh` with **LF line endings** — a CRLF file fails on Linux with
   `bad interpreter: /usr/bin/env bash^M`. Add a `.gitattributes`:

   ```
   *.sh text eol=lf
   ```

3. Your endpoint is:

   ```
   https://raw.githubusercontent.com/priyankan-sharma/ubuntu-rdp-setup/main/ubuntu-rdp-setup.sh
   ```

4. **Pin to a tag** so a future push can never change what your servers run:

   ```bash
   git tag v1.4.0 && git push origin v1.4.0
   ```

   ```
   https://raw.githubusercontent.com/priyankan-sharma/ubuntu-rdp-setup/v1.4.0/ubuntu-rdp-setup.sh
   ```

Free, versioned, permanent, no account beyond GitHub, no rate limits that matter for this use.

### Option B — jsDelivr CDN in front of the same repo

Same file, cached at the edge, better for servers far from GitHub:

```
https://cdn.jsdelivr.net/gh/priyankan-sharma/ubuntu-rdp-setup@v1.4.0/ubuntu-rdp-setup.sh
```

### Option C — a real API endpoint (Cloudflare Workers, free tier)

If you want a short, custom URL like `https://setup.yourname.workers.dev`:

1. Create a free Cloudflare account → Workers & Pages → Create Worker.
2. Replace the worker code with a fetch-and-proxy of your GitHub raw URL:

   ```js
   export default {
     async fetch() {
       const upstream = "https://raw.githubusercontent.com/priyankan-sharma/ubuntu-rdp-setup/v1.4.0/ubuntu-rdp-setup.sh";
       const r = await fetch(upstream, { cf: { cacheTtl: 300 } });
       return new Response(r.body, {
         headers: { "content-type": "text/x-shellscript; charset=utf-8" }
       });
     }
   };
   ```

3. Deploy. Free tier is 100,000 requests/day — vastly more than you need.

### Option D — GitHub Gist

Fastest to set up, but Gist raw URLs contain a revision hash that changes on every edit, so the URL is
not stable. Fine for a one-off, poor for something you re-use.

### Option E — no-account hosts (no login, no signup at all)

If you do not want to create an account anywhere, these accept an anonymous upload and hand you back a
plain URL that `wget` can fetch.

**catbox.moe — the best of these.** No account, no expiry, files stay up indefinitely, 200 MB limit.

```bash
curl -F "reqtype=fileupload" -F "fileToUpload=@ubuntu-rdp-setup.sh" https://catbox.moe/user/api.php
```

It prints a URL like `https://files.catbox.moe/ab12cd.sh`. Use that directly:

```bash
wget -O setup.sh https://files.catbox.moe/ab12cd.sh && chmod +x setup.sh && sudo ./setup.sh
```

**0x0.st — second choice.** No account. Retention scales inversely with file size; a ~70 KB script keeps
roughly a year.

```bash
curl -F "file=@ubuntu-rdp-setup.sh" https://0x0.st
```

**bashupload.com — quick and dirty**, no account, but only ~3 days of retention.

```bash
curl -T ubuntu-rdp-setup.sh https://bashupload.com
```

**Trade-offs you are accepting with all three:** no versioning, no history, and no way to update the file
in place — every edit produces a *new* URL, so you must re-copy it. There is also no guarantee of
availability. Record the checksum when you upload, and verify it on the server before running:

```bash
sha256sum ubuntu-rdp-setup.sh
```

GitHub raw (Option A) needs one free account and gives you tags, history and a URL that never changes —
worth the two minutes if you plan to run this on more than one server.

### Verify what you downloaded

Publish the checksum alongside the script:

```bash
sha256sum ubuntu-rdp-setup.sh
```

Then on the server, before running:

```bash
sha256sum setup.sh
```

---

## Post-install

**First connection** shows a certificate warning — that is the self-signed TLS certificate the script
generated. Accept it. To remove the warning entirely, replace `/etc/xrdp/cert.pem` and
`/etc/xrdp/key.pem` with a real certificate (`chown root:ssl-cert`, `chmod 640` on the key) and restart
`xrdp`.

**Security.** Port 3389 is opened to any source address by design — you connect from changing
addresses (roaming laptop, tethering, CGNAT), so an allow-list would lock you out more often than it
would stop an attacker. What protects you instead:

1. **A strong password on the desktop account.** This is now the primary control. 3389 on a public IP is
   scanned within minutes of the box coming up.
2. **fail2ban** — 5 failed logins in 10 minutes earns a 1-hour ban. Check it with
   `sudo fail2ban-client status xrdp-sesman-custom`.
3. **TLS** on the RDP transport (stage 06).

If you ever do want to pin it to one address:

```bash
sudo ufw delete allow 3389/tcp && sudo ufw allow from YOUR.IP to any port 3389 proto tcp
```

Or skip exposure entirely and tunnel over SSH — `ssh -L 3389:localhost:3389 user@server`, then point
your RDP client at `localhost:3389`.

**Where things live**

| Path | What |
|---|---|
| `/var/log/xrdp-setup.log` | Everything the installer did |
| `/var/log/xrdp-reaper.log` | Every reaper sweep and action |
| `/var/log/xrdp-sesman.log` | XRDP session manager (auth failures land here) |
| `/var/lib/xrdp-setup/state` | Completed stages, for idempotent re-runs |
| `/usr/local/sbin/xrdp-session-reaper` | The reaper itself, fully commented |
| `/usr/local/bin/google-chrome-rdp` | Chrome wrapper tuned for a headless VPS |

---

> **Never hand-write `/etc/xrdp/xrdp.ini`.** Since v1.2.0 the script patches it key by key and leaves
> the `ls_*` login-screen geometry block, bitmap and font references untouched. Replacing the file
> wholesale produces a login screen that paints its background and nothing else.

## Troubleshooting

| Symptom | Check |
|---|---|
| Black screen after login | `sudo xrdp-session-reaper --verbose` then reconnect; check `/var/log/xrdp-reaper.log` |
| Window closes right after login | `cat ~/.xsession-errors`; confirm `/etc/xrdp/startwm.sh` unsets `DBUS_SESSION_BUS_ADDRESS` |
| Cannot connect at all | `sudo ss -lntp \| grep 3389`, `sudo ufw status`, `sudo systemctl status xrdp` |
| Banned by your own fail2ban | `sudo fail2ban-client set xrdp-sesman-custom unbanip YOUR.IP` |
| Text shows as empty boxes (tofu) | Missing fonts. `fc-list :lang=hi \| wc -l` should be > 0; if it is 0, `sudo apt install -y fonts-indic fonts-noto-core fonts-noto-color-emoji && sudo fc-cache -f`, then restart Chrome |
| Chinese/Japanese/Korean shows as tofu | Not installed by default (~250 MB): `sudo apt install -y fonts-noto-cjk && sudo fc-cache -f` |
| Chrome will not start | Run `google-chrome-rdp` from a terminal in the session and read the error |
| Login screen is a solid colour with no username box | A pre-1.2.0 bug: `xrdp.ini` was hand-written and lost the `ls_*` login-screen geometry block. Re-run the script (it self-repairs), or `sudo cp /etc/xrdp/xrdp.ini.bak.* /etc/xrdp/xrdp.ini && sudo systemctl restart xrdp` |
| Desktop dies ~2 min after login, browser closes | A pre-1.3.0 reaper bug — it killed live sessions. Upgrade to v1.3.0, then confirm with `sudo xrdp-session-reaper --status` (must say LIVE) |
| Everything is broken | Re-run `sudo ./setup.sh --force --skip-upgrade` — it repairs the config in place |

---

## License

MIT.
