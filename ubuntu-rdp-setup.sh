#!/usr/bin/env bash
# =============================================================================
#  ubuntu-rdp-setup.sh
#  One-shot installer: Ubuntu 24.04 LTS server  ->  RDP-accessible desktop
#                                                   with Google Chrome.
# =============================================================================
#  SCRIPT_VERSION : 1.5.0
#  TARGET OS      : Ubuntu 24.04 LTS (noble), amd64 or arm64
#  TARGET HW      : VPS, 1-4 vCPU / 1-16 GB RAM
#  LICENSE        : MIT
# =============================================================================
#
#  ## READ THIS FIRST (human or AI agent)
#
#  WHAT THIS DOES, IN ORDER:
#    00 preflight      - sanity checks, logging, resume state
#    01 update         - full apt update + dist-upgrade
#    02 detect specs   - inspect CPU/RAM/disk, recommend a desktop environment
#    03 create user    - INTERACTIVE prompt for the RDP login + password
#    04 install DE     - XFCE / MATE / GNOME-Flashback (Xorg, never Wayland)
#    05 install xrdp   - xrdp + xorgxrdp
#    06 configure xrdp - the "fail-proof" configuration (see NOTES below)
#    07 install chrome - Google apt repo + a launcher wrapper
#    08 reaper         - the zombie-session garbage collector (THE core feature)
#    09 security       - UFW + TLS cert + fail2ban
#    10 verify         - health checks and a summary banner
#
#  WHY THE REAPER EXISTS (the whole reason this script is not 20 lines):
#    Stock xrdp on Ubuntu is NOT resilient to abrupt disconnects. When an RDP
#    client dies without logging out (network drop, client crash, VM window
#    closed, laptop lid), xrdp-sesman leaves behind:
#       - an orphaned Xorg/Xvnc process still owning display :10, :11, ...
#       - orphaned xrdp-chansrv / xrdp-sessvc processes
#       - an orphaned per-session dbus-daemon
#       - stale /tmp/.X11-unix/X<N> sockets and /tmp/.X<N>-lock files
#       - stale ~/.Xauthority cookies and ~/.cache/sessions saved state
#    On the NEXT login the new session collides with that debris and the user
#    gets either a BLACK SCREEN or an RDP window that closes 2-5 seconds after
#    authenticating. This is the single most-reported xrdp problem.
#
#    Fix strategy used here (defence in depth, four independent layers):
#      L1  sesman policy   -> Policy=UBDI + KillDisconnected, so sesman itself
#                             refuses to hand a half-dead session to a new client
#      L2  startwm.sh      -> unset DBUS_SESSION_BUS_ADDRESS / XDG_RUNTIME_DIR
#                             before starting the DE (fixes instant-close)
#      L3  reaper timer    -> every 60s, find sessions with no attached TCP
#                             client, kill the whole process tree, delete the
#                             debris, and restart xrdp if the port is dead
#      L4  boot cleanup    -> a oneshot unit ordered Before=xrdp.service wipes
#                             all debris at boot, so a reboot ALWAYS works
#
#  IDEMPOTENCY: safe to re-run. Every stage checks state first; every config
#  file is backed up to <file>.bak.<epoch> before being touched; completed
#  stages are recorded in /var/lib/xrdp-setup/state.
#
#  NON-DESTRUCTIVE: never deletes users, never touches partitions, always shows
#  firewall changes before applying them.
#
#  DO NOT PIPE THIS TO BASH. It is interactive (it asks for a password).
#  Correct usage:
#      wget -O setup.sh <URL> && chmod +x setup.sh && sudo ./setup.sh
#
#  FLAGS:
#      --dry-run              print what would happen, change nothing
#      --de=xfce|mate|gnome   skip the DE prompt
#      --timezone=ZONE        IANA zone to set (default Asia/Kolkata);
#                             use --timezone=keep to leave it untouched
#      --skip-upgrade         skip stage 01 (faster re-runs)
#      --force                ignore the state file, re-run every stage
#      --version              print version and exit
#      --help                 print usage and exit
#
# =============================================================================
#  CHANGELOG
# -----------------------------------------------------------------------------
#  1.5.0  FIX: "Untrusted application launcher" prompt on the Chrome icon.
#         XFCE 4.18 (Ubuntu 24.04) does not trust a .desktop file just because
#         it is executable - it also requires a gio metadata attribute,
#         metadata::xfce-exe-checksum, holding the file's SHA-256. Observed on a
#         real install: file was 0755 and user-owned, prompt still appeared.
#         New trust_desktop_file() sets the exec bit, the XFCE checksum and the
#         GNOME metadata::trusted flag. Added gvfs (which backs gio metadata) to
#         the package list and a verification check.
#
#  1.4.0  FIX: Indian-language text rendered as empty boxes ("tofu").
#         A server image ships Latin fonts only - measured on a fresh install,
#         fc-list :lang=hi returned 0, so google.com's own language footer was
#         unreadable. Stage 04 now installs fonts-indic (all 14 Indian scripts),
#         fonts-noto-core and fonts-noto-color-emoji, then rebuilds the font
#         cache. Adds ~200 MB. Three verification checks added.
#
#  1.3.0  CRITICAL FIX: the reaper was killing LIVE desktop sessions.
#         Also: system timezone is now set to Asia/Kolkata by default (VPS
#         images ship as UTC) and NTP is enabled. Override with
#         --timezone=<zone> or --timezone=keep.
#         Cause: reaper 1.0.0 decided "is a client attached?" by correlating
#         ESTABLISHED TCP connections on 3389 back to an X display via the
#         connection process cmdline, its children, and its environ. Measured on
#         a live session, ALL THREE are empty - the xrdp connection process has
#         cmdline "/usr/sbin/xrdp", no children, and no DISPLAY. So every live
#         session looked clientless and was killed 120s after login, taking the
#         browser and any unsaved work with it.
#         Fix: reaper 1.1.0 uses the process tree instead. A live session has its
#         Xorg parented to a per-session xrdp-sesman; an orphan is reparented to
#         PID 1. Disconnect handling is now left entirely to sesman
#         (KillDisconnected=true), which is the mechanism designed for it. The
#         reaper only handles what sesman cannot: orphaned processes, on-disk
#         debris, and a dead listener. Added --status for a no-op snapshot.
#         Also: startwm.sh no longer deletes ~/.cache/sessions on every login
#         (that cleanup moved to boot only), and the pointless
#         GNOME_SHELL_SESSION_MODE export was dropped from ~/.xsessionrc.
#
#  1.2.0  FIX: blue/blank login screen with no username-password box.
#         Cause: 1.0.0-1.1.0 wrote /etc/xrdp/xrdp.ini from scratch and defined
#         only two ls_* keys (ls_title, ls_top_window_bg_color). xrdp draws its
#         login window from a COMPLETE block of ls_* geometry keys; a partial
#         set makes it take the custom-login-screen path with zero widget
#         geometry, so the background paints but no widgets do. The hand-written
#         file also dropped the bitmap/font resource references.
#         Fix: xrdp.ini and sesman.ini are now PATCHED IN PLACE key by key via
#         an ini_set() helper, never replaced. Added restore_distro_ini(), which
#         detects a hand-written file from an older version and restores the
#         pristine one from the oldest backup or straight out of the .deb.
#         Added two verification checks that fail if the distro login-screen
#         block is missing.
#         UPGRADING from 1.0.0/1.1.0: just re-run the script; it repairs
#         xrdp.ini automatically. Or restore by hand:
#           sudo cp /etc/xrdp/xrdp.ini.bak.* /etc/xrdp/xrdp.ini
#           sudo systemctl restart xrdp
#
#  1.1.0  Firewall simplification.
#         - Removed the "restrict RDP to a source IP/CIDR" prompt; port 3389 is
#           now opened to any address. Rationale: the operator connects from
#           changing addresses (roaming laptop, tethering, CGNAT), so an
#           allow-list locks them out more often than it stops an attacker.
#           Brute force is covered by the fail2ban jail; transport is TLS.
#           To lock it down manually later:
#             sudo ufw delete allow 3389/tcp
#             sudo ufw allow from <YOUR.IP> to any port 3389 proto tcp
#
#  1.0.0  Initial release.
#         - Ubuntu 24.04 support; XFCE/MATE/GNOME-Flashback selection driven by
#           detected hardware specs.
#         - Interactive-only credential creation (no env-var bypass, by design).
#         - xrdp-session-reaper daemon (systemd timer, 60s) + boot cleanup unit.
#         - TLS for xrdp, UFW rule with optional source-IP restriction,
#           fail2ban jail for xrdp-sesman auth failures.
#         - Google Chrome via the official apt repo, plus a wrapper that sets
#           --password-store=basic (no keyring exists on a headless server, and
#           the keyring prompt is a known cause of "Chrome will not start" over
#           RDP).
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.5.0"
readonly STATE_DIR="/var/lib/xrdp-setup"
readonly STATE_FILE="${STATE_DIR}/state"
readonly LOG_FILE="/var/log/xrdp-setup.log"
readonly BACKUP_SUFFIX=".bak.$(date +%s)"
readonly RDP_PORT=3389
readonly REAPER_BIN="/usr/local/sbin/xrdp-session-reaper"

# ---- runtime flags ----------------------------------------------------------
DRY_RUN=0
FORCE=0
SKIP_UPGRADE=0
DE_CHOICE=""          # xfce | mate | gnome  (empty => prompt)
# WHY Asia/Kolkata: these servers are operated from India, and a VPS image
# defaults to UTC. Logs, cron, file timestamps and the desktop clock all being
# 5h30m off local time is a constant low-grade nuisance. Override with
# --timezone=<IANA zone>, or "--timezone=keep" to leave the image as-is.
TIMEZONE="Asia/Kolkata"

# ---- collected during the run ----------------------------------------------
RDP_USER=""
CPU_CORES=0
RAM_MB=0
DISK_GB=0
SERVER_IP=""

# =============================================================================
#  SECTION 1 - output helpers
#  WHY: consistent, greppable logging that also lands in $LOG_FILE, so a
#  support request or an AI agent can reconstruct exactly what happened.
# =============================================================================
C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GRN=$'\033[1;32m'
C_YLW=$'\033[1;33m'
C_BLU=$'\033[1;34m'
C_CYN=$'\033[1;36m'
C_BLD=$'\033[1m'

_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
_log()  { printf '%s [%s] %s\n' "$(_ts)" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true; }

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RESET" "$*"; _log INFO "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RESET" "$*"; _log OK   "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RESET" "$*"; _log WARN "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log ERR "$*"; }
step()  { printf '\n%s%s==> %s%s\n' "$C_BLD" "$C_CYN" "$*" "$C_RESET"; _log STEP "$*"; }

die() { err "$*"; err "Full log: $LOG_FILE"; exit 1; }

# WHY: a trap that names the failing line + stage turns "it broke" into an
# actionable bug report.
CURRENT_STAGE="startup"
on_err() {
  local exit_code=$? line=${1:-?}
  err "FAILED in stage '${CURRENT_STAGE}' at line ${line} (exit ${exit_code})"
  err "Log file: ${LOG_FILE}"
  err "Re-run the script to resume; completed stages are skipped."
  exit "$exit_code"
}
trap 'on_err $LINENO' ERR

# run(): the single choke point for every state-changing command, so --dry-run
# is honoured everywhere without sprinkling if-statements through the script.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[dry-run]%s %s\n' "$C_YLW" "$C_RESET" "$*"
    return 0
  fi
  _log CMD "$*"
  "$@"
}

# write_file <path> [mode]  -- content on stdin. Backs up any existing file.
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[dry-run]%s would write %s (mode %s)\n' "$C_YLW" "$C_RESET" "$path" "$mode"
    cat >/dev/null
    return 0
  fi
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$path" ]]; then
    if cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
    cp -a "$path" "${path}${BACKUP_SUFFIX}"
    _log BACKUP "${path} -> ${path}${BACKUP_SUFFIX}"
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  _log WROTE "$path"
}

# ---- resume state -----------------------------------------------------------
stage_done()      { [[ $FORCE -eq 0 ]] && grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_stage_done() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  mkdir -p "$STATE_DIR"
  grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >>"$STATE_FILE"
}

# =============================================================================
#  SECTION 2 - apt helpers
#  WHY: cloud images run unattended-upgrades on first boot, which holds the dpkg
#  lock for several minutes. Without a wait loop this script dies on its first
#  apt call on every fresh VPS. Retries cover transient mirror failures.
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # never show the "restart services?" TUI
export NEEDRESTART_SUSPEND=1

wait_for_apt() {
  local waited=0 max=900
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
              /var/cache/apt/archives/lock >/dev/null 2>&1; do
    [[ $waited -eq 0 ]] && warn "apt/dpkg is locked (probably unattended-upgrades). Waiting..."
    sleep 5; waited=$((waited + 5))
    [[ $waited -ge $max ]] && die "apt lock still held after ${max}s. Reboot and re-run."
  done
  [[ $waited -gt 0 ]] && ok "apt lock released after ${waited}s"
  return 0
}

apt_retry() {
  local attempt=1 max=3
  while true; do
    wait_for_apt
    if run apt-get "$@"; then return 0; fi
    if [[ $attempt -ge $max ]]; then
      err "apt-get $* failed after ${max} attempts"
      return 1
    fi
    warn "apt-get $* failed (attempt ${attempt}/${max}); recovering and retrying..."
    run dpkg --configure -a || true
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
}

apt_install() { apt_retry install -y "$@" || die "Failed to install: $*"; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }

# =============================================================================
#  SECTION 3 - interactive prompt helpers
#  All prompts read from /dev/tty, never stdin, so the script still works if
#  stdin happens to be redirected.
# =============================================================================
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s?%s %s [%s]: ' "$C_CYN" "$C_RESET" "$prompt" "$default")" reply </dev/tty
    echo "${reply:-$default}"
  else
    read -r -p "$(printf '%s?%s %s: ' "$C_CYN" "$C_RESET" "$prompt")" reply </dev/tty
    echo "$reply"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}" reply hint
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "$(printf '%s?%s %s [%s]: ' "$C_CYN" "$C_RESET" "$prompt" "$hint")" reply </dev/tty
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

require_tty() {
  # WHY: credentials are prompted for interactively BY DESIGN (no env-var
  # bypass). If there were no terminal the prompts would read EOF and silently
  # create an account with an empty password. Fail loudly instead.
  [[ -e /dev/tty ]] || die "No controlling terminal. Do NOT pipe this script into bash; download it, then run it."
}

# =============================================================================
#  STAGE 00 - PREFLIGHT
# =============================================================================
stage_00_preflight() {
  CURRENT_STAGE="00-preflight"
  step "Stage 00/10 - Preflight checks"

  [[ $EUID -eq 0 ]] || die "This script must run as root. Use: sudo ./$(basename "$0")"
  require_tty

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE" && chmod 0640 "$LOG_FILE"
  _log START "=== ${SCRIPT_VERSION} started, args: $* ==="

  # OS check. We only claim support for 24.04; warn (do not block) elsewhere so
  # the script stays usable on 22.04/25.04 at the operator's own risk.
  local os_id os_ver
  os_id="$(. /etc/os-release && echo "${ID:-unknown}")"
  os_ver="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
  info "Detected OS: ${os_id} ${os_ver}  kernel $(uname -r)  arch $(dpkg --print-architecture)"
  if [[ "$os_id" != "ubuntu" ]]; then
    warn "This script targets Ubuntu. Detected '${os_id}'."
    ask_yn "Continue anyway?" n || die "Aborted by user."
  elif [[ "$os_ver" != "24.04" ]]; then
    warn "This script is tested on Ubuntu 24.04 LTS; you are on ${os_ver}."
    ask_yn "Continue anyway?" y || die "Aborted by user."
  fi

  # Connectivity: fail early with a clear message rather than mid-apt.
  if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 \
     && ! getent hosts security.ubuntu.com >/dev/null 2>&1; then
    warn "DNS lookup for the Ubuntu archive failed. Check /etc/resolv.conf."
    ask_yn "Continue anyway?" n || die "Aborted by user."
  fi

  # Disk space: a desktop + Chrome needs roughly 4-5 GB.
  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  info "Free space on /: $((free_mb / 1024)) GB"
  if [[ $free_mb -lt 6000 ]]; then
    warn "Less than 6 GB free on /. A desktop + Chrome needs about 5 GB."
    ask_yn "Continue anyway?" n || die "Aborted by user."
  fi

  # Tools used later by this script and by the reaper.
  info "Ensuring base tooling is present..."
  apt_retry update -o Acquire::Retries=3 >/dev/null 2>&1 || true
  apt_install ca-certificates curl wget gnupg lsb-release procps psmisc \
              iproute2 net-tools sudo openssl

  ok "Preflight complete"
  mark_stage_done "00-preflight"
}

# =============================================================================
#  STAGE 01 - FULL SYSTEM UPDATE
#  WHY first: installing a desktop on top of a half-updated noble image pulls
#  mismatched mesa/xorg ABI versions, which is itself a black-screen cause.
# =============================================================================
stage_01_update() {
  CURRENT_STAGE="01-update"
  step "Stage 01/10 - Updating and upgrading all packages"

  if [[ $SKIP_UPGRADE -eq 1 ]]; then
    warn "--skip-upgrade given; skipping dist-upgrade (timezone is still applied)"
  else

  info "apt-get update ..."
  apt_retry update || die "apt-get update failed"

  info "apt-get dist-upgrade (this can take several minutes on a fresh image) ..."
  apt_retry -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            dist-upgrade -y || die "dist-upgrade failed"

  info "Removing obsolete packages ..."
  apt_retry autoremove -y  || true
  apt_retry autoclean -y   || true
  fi   # end of the --skip-upgrade guard

  # ---------------------------------------------------------------------------
  # Timezone + time sync.
  #  WHY here: it must happen before anything writes timestamped logs, and before
  #  the desktop is installed, so the clock the user sees is right from the very
  #  first login. A VPS image ships as UTC; these servers are run from India.
  #  WHY NTP too: a VPS clock drifts, and a skewed clock breaks TLS certificate
  #  validation in the browser - which looks like "random HTTPS errors", not like
  #  a clock problem.
  # ---------------------------------------------------------------------------
  if [[ "$TIMEZONE" == "keep" ]]; then
    info "Leaving the system timezone as-is (--timezone=keep)"
  else
    if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
      warn "Unknown timezone '${TIMEZONE}'; leaving the system clock alone."
      warn "List valid zones with: timedatectl list-timezones"
    else
      local current_tz
      current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
      if [[ "$current_tz" == "$TIMEZONE" ]]; then
        info "Timezone already ${TIMEZONE}"
      else
        info "Setting timezone: ${current_tz} -> ${TIMEZONE}"
        run timedatectl set-timezone "$TIMEZONE" \
          || warn "timedatectl failed; timezone unchanged"
      fi
    fi
    # Keep the clock accurate. systemd-timesyncd ships with Ubuntu Server.
    run timedatectl set-ntp true 2>/dev/null || true
    info "Clock now: $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
  fi

  # A kernel/libc upgrade may want a reboot. Note it; do not force one, because
  # rebooting mid-script would lose the operator's terminal.
  if [[ -f /var/run/reboot-required ]]; then
    warn "The upgrade flagged a reboot as required. Reboot AFTER this script finishes."
  fi

  ok "System fully updated"
  mark_stage_done "01-update"
}

# =============================================================================
#  STAGE 02 - HARDWARE DETECTION AND DESKTOP RECOMMENDATION
#
#  WHY: the desktop environment is the biggest single factor in whether XRDP is
#  smooth or miserable on a small VPS, and in whether it works at all.
#
#  Recommendation matrix:
#    <= 2 vCPU or <= 4 GB RAM  -> XFCE  (lightest, most XRDP-proven)
#    3-4 vCPU and 6-8 GB RAM   -> MATE  (heavier, nicer, still Xorg-native)
#    >= 4 vCPU and >= 12 GB    -> GNOME Flashback (GNOME look, Xorg + Metacity)
#
#  We deliberately never offer stock GNOME Shell: it defaults to Wayland, and
#  mutter under Xorg-over-XRDP is the number-one cause of black screens and
#  session crashes. GNOME Flashback gives the GNOME look and apps on a plain
#  Xorg + Metacity stack that XRDP handles reliably.
# =============================================================================
stage_02_detect_specs() {
  CURRENT_STAGE="02-detect-specs"
  step "Stage 02/10 - Detecting server specifications"

  CPU_CORES=$(nproc)
  RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  DISK_GB=$(df -PBG / | awk 'NR==2 {gsub("G","",$2); print $2}')

  printf '\n'
  printf '    %-14s %s\n' "vCPU cores:" "$CPU_CORES"
  printf '    %-14s %s MB (%.1f GB)\n' "Memory:" "$RAM_MB" "$(awk -v m="$RAM_MB" 'BEGIN{print m/1024}')"
  printf '    %-14s %s GB total on /\n' "Disk:" "$DISK_GB"
  printf '\n'

  local recommended reason
  if [[ $CPU_CORES -le 2 || $RAM_MB -le 4096 ]]; then
    recommended="xfce"
    reason="modest specs - XFCE is the lightest and most XRDP-proven desktop"
  elif [[ $CPU_CORES -ge 4 && $RAM_MB -ge 12288 ]]; then
    recommended="gnome"
    reason="plenty of headroom - GNOME Flashback gives the GNOME look on a safe Xorg stack"
  else
    recommended="mate"
    reason="mid-range specs - MATE is a good balance of looks and weight"
  fi
  info "Recommended desktop: ${C_BLD}${recommended^^}${C_RESET} (${reason})"

  if [[ -n "$DE_CHOICE" ]]; then
    info "Desktop forced by --de=${DE_CHOICE}"
  else
    printf '\n  1) XFCE            - lightest, fastest over RDP, most reliable\n'
    printf   '  2) MATE            - GNOME2-style, mid-weight, Xorg-native\n'
    printf   '  3) GNOME Flashback - GNOME look and apps, Xorg + Metacity (no Wayland)\n\n'
    local default_num
    case "$recommended" in xfce) default_num=1 ;; mate) default_num=2 ;; gnome) default_num=3 ;; esac
    while true; do
      local pick; pick="$(ask "Choose a desktop (1-3)" "$default_num")"
      case "$pick" in
        1) DE_CHOICE="xfce";  break ;;
        2) DE_CHOICE="mate";  break ;;
        3) DE_CHOICE="gnome"; break ;;
        *) warn "Enter 1, 2 or 3." ;;
      esac
    done
  fi

  ok "Desktop environment selected: ${DE_CHOICE^^}"
  [[ $DRY_RUN -eq 0 ]] && echo "$DE_CHOICE" > "${STATE_DIR}/desktop"
  mark_stage_done "02-detect-specs"
}

# =============================================================================
#  STAGE 03 - CREATE THE RDP LOGIN (INTERACTIVE ONLY)
#
#  WHY interactive only: an env-var or flag would put the password into the
#  shell history, the process table and /var/log, on a box whose whole purpose
#  is to be reachable from the internet on port 3389. There is deliberately no
#  non-interactive path.
# =============================================================================
stage_03_create_user() {
  CURRENT_STAGE="03-create-user"
  step "Stage 03/10 - Creating the RDP login account"

  printf '\n  This account is what you will type into the Remote Desktop client.\n'
  printf '  It is a normal Linux user with sudo rights.\n\n'

  # ---- username ----
  while true; do
    RDP_USER="$(ask "Desktop username")"
    if [[ -z "$RDP_USER" ]]; then
      warn "Username cannot be empty."
    elif [[ ! "$RDP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      warn "Invalid username. Use lowercase letters, digits, '-' and '_', starting with a letter."
    elif [[ "$RDP_USER" == "root" ]]; then
      # WHY: xrdp refuses root logins by default and unblocking it is a bad idea
      # on an internet-facing 3389.
      warn "Do not use 'root' for RDP. Choose a normal username."
    elif id -u "$RDP_USER" >/dev/null 2>&1; then
      info "User '${RDP_USER}' already exists."
      if ask_yn "Use the existing account and reset its password?" y; then break; fi
    else
      break
    fi
  done

  # ---- password ----
  local pw1 pw2
  while true; do
    read -r -s -p "$(printf '%s?%s Password for %s: ' "$C_CYN" "$C_RESET" "$RDP_USER")" pw1 </dev/tty; printf '\n'
    read -r -s -p "$(printf '%s?%s Confirm password: ' "$C_CYN" "$C_RESET")" pw2 </dev/tty; printf '\n'
    if [[ "$pw1" != "$pw2" ]]; then
      warn "Passwords do not match. Try again."
    elif [[ ${#pw1} -lt 8 ]]; then
      warn "Password must be at least 8 characters."
    elif [[ ! "$pw1" =~ [A-Za-z] || ! "$pw1" =~ [0-9] ]]; then
      warn "Password must contain at least one letter and one digit."
      ask_yn "Use it anyway (NOT recommended on a public IP)?" n && break
    else
      break
    fi
  done

  if ! id -u "$RDP_USER" >/dev/null 2>&1; then
    info "Creating user '${RDP_USER}' ..."
    run useradd -m -s /bin/bash -c "XRDP desktop user" "$RDP_USER"
  fi

  # chpasswd via stdin: the password never appears in the process table.
  if [[ $DRY_RUN -eq 0 ]]; then
    printf '%s:%s\n' "$RDP_USER" "$pw1" | chpasswd || die "Failed to set password"
  else
    printf '%s[dry-run]%s would set password for %s\n' "$C_YLW" "$C_RESET" "$RDP_USER"
  fi
  unset pw1 pw2

  # Groups:
  #   sudo      - so the desktop user can administer the box
  #   ssl-cert  - xrdp reads /etc/xrdp/key.pem, which is ssl-cert group readable
  #   audio,video,plugdev - normal desktop device access
  run usermod -aG sudo "$RDP_USER"
  for g in ssl-cert audio video plugdev; do
    getent group "$g" >/dev/null 2>&1 && run usermod -aG "$g" "$RDP_USER" || true
  done

  [[ $DRY_RUN -eq 0 ]] && echo "$RDP_USER" > "${STATE_DIR}/rdp_user"
  ok "RDP account ready: ${RDP_USER}"
  mark_stage_done "03-create-user"
}

# =============================================================================
#  STAGE 04 - INSTALL THE DESKTOP ENVIRONMENT
#
#  Notes for future maintainers:
#   - dbus-x11 is REQUIRED. Without it dbus-launch is missing and the session
#     dies instantly after login (one of the classic "window closes" causes).
#   - We install with --no-install-recommends deliberately excluded for the DE
#     metapackages, because the recommends carry the panels/menus you actually
#     want; but we do NOT install the *-desktop task metapackages, which drag in
#     printing stacks, LibreOffice and a display manager we do not need.
#   - No display manager (gdm3/lightdm) is installed. XRDP starts sessions
#     itself; a running DM competes for the VT and wastes ~200 MB.
# =============================================================================
stage_04_install_de() {
  CURRENT_STAGE="04-install-de"
  step "Stage 04/10 - Installing the ${DE_CHOICE^^} desktop"

  # Common bits every DE needs under XRDP.
  local common=(xorg xserver-xorg-core dbus-x11 x11-xserver-utils x11-utils
                policykit-1-gnome desktop-file-utils xdg-utils fontconfig
                gvfs gvfs-backends)

  # ---------------------------------------------------------------------------
  # Fonts.
  #  WHY this is not optional: a server image carries Latin fonts only. Without
  #  the rest, any page containing Indic, CJK or emoji text renders as rows of
  #  empty boxes ("tofu") - google.com's own language footer does exactly that.
  #  Measured on a fresh 24.04 + XFCE install: fc-list :lang=hi returned 0.
  #    fonts-indic           all 14 Indian scripts (Devanagari, Bengali, Tamil,
  #                          Telugu, Kannada, Malayalam, Gujarati, Gurmukhi,
  #                          Odia, Assamese and friends) - about 200 MB
  #    fonts-noto-core       broad Unicode coverage for everything else
  #    fonts-noto-color-emoji  emoji, which are everywhere on the modern web
  #  CJK is deliberately excluded (fonts-noto-cjk is ~250 MB); add it by hand if
  #  you browse Chinese/Japanese/Korean sites.
  # ---------------------------------------------------------------------------
  local fonts=(fonts-dejavu-core fonts-dejavu-extra fonts-liberation
               fonts-indic fonts-noto-core fonts-noto-color-emoji)

  local pkgs=()
  case "$DE_CHOICE" in
    xfce)
      pkgs=(xfce4 xfce4-goodies xfce4-terminal thunar-archive-plugin
            mousepad ristretto)
      ;;
    mate)
      pkgs=(mate-desktop-environment mate-terminal caja-open-terminal
            mate-tweak)
      ;;
    gnome)
      # gnome-session-flashback = GNOME apps and look on Xorg + Metacity.
      # WHY not gnome-shell: it defaults to Wayland, and mutter over xorgxrdp is
      # the single biggest source of black screens and session crashes.
      pkgs=(gnome-session-flashback gnome-terminal gnome-panel metacity
            nautilus gnome-control-center gnome-tweaks)
      ;;
    *) die "Unknown desktop '${DE_CHOICE}'" ;;
  esac

  info "Installing X11 base ..."
  apt_install "${common[@]}"

  info "Installing fonts (Latin + all Indian scripts + Noto + emoji) ..."
  apt_install "${fonts[@]}"
  # fontconfig only sees new fonts after its cache is rebuilt.
  run fc-cache -f >/dev/null 2>&1 || true

  info "Installing ${DE_CHOICE^^} (this is the long one) ..."
  apt_install "${pkgs[@]}"

  # WHY: if a display manager sneaked in as a dependency, disable it. A DM
  # holding VT7 and an Xorg instance conflicts with xrdp session startup.
  for dm in gdm3 lightdm sddm; do
    if systemctl list-unit-files "${dm}.service" >/dev/null 2>&1 \
       && systemctl is-enabled "${dm}.service" >/dev/null 2>&1; then
      warn "Disabling display manager '${dm}' (not needed; conflicts with xrdp)"
      run systemctl disable --now "${dm}.service" || true
    fi
  done

  # Boot to multi-user (no graphical target) - saves RAM, avoids VT contention.
  run systemctl set-default multi-user.target

  ok "${DE_CHOICE^^} installed"
  mark_stage_done "04-install-de"
}

# =============================================================================
#  STAGE 05 - INSTALL XRDP
# =============================================================================
stage_05_install_xrdp() {
  CURRENT_STAGE="05-install-xrdp"
  step "Stage 05/10 - Installing XRDP"

  # xorgxrdp is the Xorg driver module. WITHOUT it, xrdp falls back to Xvnc,
  # which is slower, and its session teardown is exactly where zombie sessions
  # come from. Installing it is not optional for a reliable setup.
  apt_install xrdp xorgxrdp

  run systemctl enable xrdp
  run systemctl enable xrdp-sesman

  # The xrdp service user must be able to read the TLS key.
  run adduser xrdp ssl-cert || true

  ok "XRDP installed"
  mark_stage_done "05-install-xrdp"
}

# =============================================================================
#  STAGE 06 - THE FAIL-PROOF XRDP CONFIGURATION
#
#  This stage is where most of the reliability comes from. Every setting below
#  has a one-line reason; do not change them without reading the reason.
# =============================================================================
stage_06_configure_xrdp() {
  CURRENT_STAGE="06-configure-xrdp"
  step "Stage 06/10 - Configuring XRDP for reliability"

  # ---------------------------------------------------------------------------
  # 6.1  TLS certificate
  #      xrdp ships with a self-signed cert, but on many images the key is
  #      unreadable by the xrdp user, which makes security_layer=tls fail and
  #      silently fall back. Generate our own, owned correctly.
  # ---------------------------------------------------------------------------
  local cert=/etc/xrdp/cert.pem key=/etc/xrdp/key.pem
  if [[ ! -s "$cert" || ! -s "$key" || $FORCE -eq 1 ]]; then
    info "Generating a self-signed TLS certificate for XRDP (10 years) ..."
    run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$key" -out "$cert" \
        -subj "/C=US/ST=NA/L=NA/O=xrdp/OU=xrdp/CN=$(hostname -f 2>/dev/null || hostname)"
  fi
  run chown root:ssl-cert "$key" "$cert"
  run chmod 640 "$key"
  run chmod 644 "$cert"

  # ---------------------------------------------------------------------------
  # 6.2  xrdp.ini and sesman.ini - PATCHED IN PLACE, NEVER REPLACED
  #
  #  HARD-WON LESSON (v1.2.0). Version 1.1.0 wrote a complete xrdp.ini from
  #  scratch. That produced a login screen showing ONLY the background colour
  #  with no username/password box - the "blue screen" bug.
  #
  #  Why: xrdp draws its login window from a COMPLETE block of ls_* geometry
  #  keys in [Globals] - ls_width, ls_height, ls_label_x, ls_input_x,
  #  ls_btn_ok_x/y/width/height, ls_logo_filename and roughly a dozen more.
  #  Define some of them and xrdp takes the custom-login-screen code path with
  #  zero widget geometry: the background paints, the widgets do not. The stock
  #  Ubuntu file ships the whole block, and it also references bitmap and font
  #  resources under /usr/share/xrdp that a hand-written file silently drops.
  #
  #  So: patch the distro file key by key and leave everything else alone. Never
  #  hand-roll xrdp.ini. The same rule applies to sesman.ini.
  # ---------------------------------------------------------------------------

  # If a previous version installed a hand-written file, put the distro one back
  # before patching, otherwise we would be patching the broken file.
  restore_distro_ini() {
    local target="$1" oldest
    grep -q 'managed by ubuntu-rdp-setup.sh' "$target" 2>/dev/null || return 0
    warn "$(basename "$target") was hand-written by an older version; restoring the distro copy"
    # Oldest backup == the pristine one taken on the very first run.
    oldest="$(ls -1t "${target}".bak.* 2>/dev/null | tail -1 || true)"
    if [[ -n "$oldest" && -s "$oldest" ]] \
       && ! grep -q 'managed by ubuntu-rdp-setup.sh' "$oldest"; then
      run cp -f "$oldest" "$target"
      ok "restored $(basename "$target") from $(basename "$oldest")"
      return 0
    fi
    # No usable backup: extract the file straight out of the .deb.
    warn "no pristine backup found; extracting $(basename "$target") from the xrdp package"
    if [[ $DRY_RUN -eq 0 ]]; then
      local tmpd; tmpd="$(mktemp -d)"
      ( cd "$tmpd" \
        && apt-get download xrdp >/dev/null 2>&1 \
        && dpkg-deb --fsys-tarfile xrdp_*.deb \
             | tar -xO "./etc/xrdp/$(basename "$target")" > "${tmpd}/ini" 2>/dev/null ) || true
      if [[ -s "${tmpd}/ini" ]]; then
        cp -f "${tmpd}/ini" "$target"
        ok "extracted a pristine $(basename "$target") from the package"
      else
        err "Could not obtain a pristine $(basename "$target")."
        err "Fix by hand:  sudo apt-get install --reinstall -o Dpkg::Options::=--force-confmiss xrdp"
      fi
      rm -rf "$tmpd"
    fi
  }

  # ini_set <file> <section> <key> <value>
  # Sets key=value inside [section], replacing an existing (or commented-out)
  # entry in place and preserving every other line, comment and blank line.
  ini_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp rc=0
    [[ -f "$file" ]] || { warn "ini_set: ${file} does not exist"; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '%s[dry-run]%s %s [%s] %s=%s\n' "$C_YLW" "$C_RESET" "$(basename "$file")" "$section" "$key" "$value"
      return 0
    fi
    tmp="$(mktemp)"
    # No dynamic regexes here: section and key are compared as plain strings,
    # so a key or section containing regex metacharacters cannot break the edit.
    awk -v sec="$section" -v k="$key" -v v="$value" '
      function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
      BEGIN { insec = 0; done = 0; seen = 0 }
      {
        line = trim($0)
        # ---- section header ----
        if (substr(line, 1, 1) == "[") {
          if (insec && !done) { print k "=" v; done = 1 }
          insec = (line == "[" sec "]")
          if (insec) seen = 1
          print; next
        }
        # ---- candidate key line, possibly commented out ----
        if (insec) {
          bare = line
          sub(/^[#;][ \t]*/, "", bare)          # tolerate ;key= and #key=
          eq = index(bare, "=")
          if (eq > 0 && trim(substr(bare, 1, eq - 1)) == k) {
            if (!done) { print k "=" v; done = 1 }
            next
          }
        }
        print
      }
      END {
        if (insec && !done) print k "=" v
        else if (!seen) exit 3
      }
    ' "$file" > "$tmp" || rc=$?
    if [[ $rc -eq 3 ]]; then
      warn "ini_set: section [${section}] not found in ${file}; ${key} not set"
      rm -f "$tmp"; return 0
    fi
    if ! cmp -s "$tmp" "$file"; then
      [[ -f "${file}${BACKUP_SUFFIX}" ]] || cp -a "$file" "${file}${BACKUP_SUFFIX}"
      cat "$tmp" > "$file"
      _log INI "${file} [${section}] ${key}=${value}"
    fi
    rm -f "$tmp"
  }

  restore_distro_ini /etc/xrdp/xrdp.ini
  restore_distro_ini /etc/xrdp/sesman.ini

  info "Patching /etc/xrdp/xrdp.ini ..."
  # TLS only: "negotiate" lets old clients drop to the broken standard-RDP
  # crypto path, which some Windows builds then refuse outright.
  ini_set /etc/xrdp/xrdp.ini Globals security_layer  tls
  ini_set /etc/xrdp/xrdp.ini Globals crypt_level     high
  ini_set /etc/xrdp/xrdp.ini Globals certificate     /etc/xrdp/cert.pem
  ini_set /etc/xrdp/xrdp.ini Globals key_file        /etc/xrdp/key.pem
  ini_set /etc/xrdp/xrdp.ini Globals ssl_protocols   "TLSv1.2, TLSv1.3"
  # 24bpp is the sweet spot for browsing: 32bpp roughly doubles bandwidth for no
  # visible gain over a WAN.
  ini_set /etc/xrdp/xrdp.ini Globals max_bpp         24
  ini_set /etc/xrdp/xrdp.ini Globals new_cursors     true
  # tcp_nodelay  -> kills the 40ms Nagle stutter on mouse/keyboard input.
  # tcp_keepalive-> makes the kernel notice a dead client instead of leaving a
  #                 half-open socket that keeps a zombie session "alive".
  ini_set /etc/xrdp/xrdp.ini Globals tcp_nodelay     true
  ini_set /etc/xrdp/xrdp.ini Globals tcp_keepalive   true
  # NOTE: deliberately NOT touched - ls_*, hidelogwindow, bitmap/font paths,
  # and the [Xorg]/[Xvnc] session blocks. See the lesson at the top of 6.2.

  # ---------------------------------------------------------------------------
  # 6.3  sesman.ini - the anti-zombie policy layer (L1)
  # ---------------------------------------------------------------------------
  info "Patching /etc/xrdp/sesman.ini ..."
  # Policy=UBDI -> a session is keyed on User + Bpp + Display + IP address.
  #   With the default policy, reconnecting from a different client or IP can
  #   attach you to a session whose X server is already half-dead - exactly the
  #   black-screen symptom. UBDI makes a genuinely new connection get a
  #   genuinely new session, and the reaper then cleans up the old one.
  ini_set /etc/xrdp/sesman.ini Sessions Policy                 UBDI
  # sesman tears a session down itself 60s after the client vanishes. This is
  # the fast path; the reaper is the backstop for hard drops sesman misses.
  ini_set /etc/xrdp/sesman.ini Sessions KillDisconnected       true
  ini_set /etc/xrdp/sesman.ini Sessions DisconnectedTimeLimit  60
  # 0 = never kill an idle-but-connected session. You do not want your browser
  # session killed because you went to lunch.
  ini_set /etc/xrdp/sesman.ini Sessions IdleTimeLimit          0
  ini_set /etc/xrdp/sesman.ini Sessions MaxSessions            10
  ini_set /etc/xrdp/sesman.ini Security AllowRootLogin         false
  ini_set /etc/xrdp/sesman.ini Security MaxLoginRetry          4

  # ---------------------------------------------------------------------------
  # 6.4  startwm.sh - the anti-instant-close layer (L2)
  #
  #  THE classic bug: xrdp starts the session with DBUS_SESSION_BUS_ADDRESS and
  #  XDG_RUNTIME_DIR inherited from a *previous or system* context. The DE then
  #  tries to talk to a bus that is not there, fails, and exits - which the RDP
  #  client shows as "window closes right after login". Unsetting both before
  #  handing over to /etc/X11/Xsession fixes it permanently.
  # ---------------------------------------------------------------------------
  write_file /etc/xrdp/startwm.sh 0755 <<'STARTWM'
#!/bin/sh
# /etc/xrdp/startwm.sh  -- managed by ubuntu-rdp-setup.sh
# Layer 2 of the anti-zombie / anti-instant-close strategy.

# 1. Kill inherited D-Bus / runtime-dir state. Without this the desktop tries to
#    reuse a dead session bus and exits within seconds of login.
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
unset SESSION_MANAGER

# 2. Force X11. Some GNOME components probe these and misbehave under xrdp.
XDG_SESSION_TYPE=x11
GDK_BACKEND=x11
QT_QPA_PLATFORM=xcb
CLUTTER_BACKEND=x11
export XDG_SESSION_TYPE GDK_BACKEND QT_QPA_PLATFORM CLUTTER_BACKEND

# 3. Disable GNOME/GTK compositing shortcuts that need a GPU we do not have.
LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_ALWAYS_SOFTWARE

# 4. Keep ~/.xsession-errors from growing without bound - a multi-GB one can
#    fill / and take the whole box down.
if [ -f "$HOME/.xsession-errors" ] && [ "$(stat -c %s "$HOME/.xsession-errors" 2>/dev/null || echo 0)" -gt 10485760 ]; then
  : > "$HOME/.xsession-errors"
fi

# 5. NOTE (v1.3.0): this used to "rm -rf $HOME/.cache/sessions" on every login.
#    That does prevent a stale saved session from black-screening a login, but it
#    also means the desktop can NEVER restore a saved session, on every single
#    login, forever - too high a price for a rare failure. The cleanup now runs
#    only at boot, from xrdp-boot-cleanup.service, where no session can be live.

# 6. Standard Debian/Ubuntu session startup. ~/.xsessionrc (written by the
#    installer) selects the desktop.
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE LC_ALL 2>/dev/null || true
fi

test -x /etc/X11/Xsession && exec /etc/X11/Xsession
exec /bin/sh /etc/X11/Xsession
STARTWM

  # reconnectwm.sh: runs on session reattach. Resets the screen so a reconnect
  # never shows the stale framebuffer of the previous client geometry.
  write_file /etc/xrdp/reconnectwm.sh 0755 <<'RECONNECTWM'
#!/bin/sh
# /etc/xrdp/reconnectwm.sh  -- managed by ubuntu-rdp-setup.sh
# Runs when an existing session is reattached. Nudges the WM to repaint so the
# client does not inherit a stale/black framebuffer from the previous geometry.
[ -n "$DISPLAY" ] || exit 0
xrandr --auto >/dev/null 2>&1 || true
xrefresh >/dev/null 2>&1 || true
exit 0
RECONNECTWM

  # ---------------------------------------------------------------------------
  # 6.5  Per-user session selection (~/.xsessionrc)
  #      WHY here and not a system default: /etc/X11/Xsession.d ordering varies
  #      between DEs, and a per-user file is unambiguous and easy to inspect.
  # ---------------------------------------------------------------------------
  local home; home="$(getent passwd "$RDP_USER" | cut -d: -f6)"
  local session_cmd
  case "$DE_CHOICE" in
    xfce)  session_cmd="startxfce4" ;;
    mate)  session_cmd="mate-session" ;;
    gnome) session_cmd="gnome-session --session=gnome-flashback-metacity" ;;
  esac

  if [[ $DRY_RUN -eq 0 ]]; then
    cat > "${home}/.xsessionrc" <<XSESSIONRC
# ~/.xsessionrc -- managed by ubuntu-rdp-setup.sh
# Selects the desktop that XRDP starts for this user.
export XDG_SESSION_DESKTOP=${DE_CHOICE}
export XDG_CURRENT_DESKTOP=${DE_CHOICE^^}
export XDG_SESSION_TYPE=x11
XSESSIONRC
    cat > "${home}/.xsession" <<XSESSION
#!/bin/sh
# ~/.xsession -- managed by ubuntu-rdp-setup.sh
exec ${session_cmd}
XSESSION
    chmod 0644 "${home}/.xsessionrc"
    chmod 0755 "${home}/.xsession"
    chown "${RDP_USER}:${RDP_USER}" "${home}/.xsessionrc" "${home}/.xsession"
  fi
  info "Session command for ${RDP_USER}: ${session_cmd}"

  # ---------------------------------------------------------------------------
  # 6.6  Xwrapper - let a non-console user start Xorg
  #      Without allowed_users=anybody, xorgxrdp cannot start Xorg for a user who
  #      is not on a physical VT, and every login black-screens.
  # ---------------------------------------------------------------------------
  write_file /etc/X11/Xwrapper.config 0644 <<'XWRAPPER'
# /etc/X11/Xwrapper.config -- managed by ubuntu-rdp-setup.sh
# XRDP users are never on a physical VT, so Xorg must be startable by anybody.
allowed_users=anybody
needs_root_rights=yes
XWRAPPER

  # ---------------------------------------------------------------------------
  # 6.7  Polkit - stop the authentication pop-ups
  #      A fresh XFCE/GNOME session over RDP throws "Authentication required to
  #      create a color managed device" and package-kit prompts at every login.
  #      They are harmless but they steal focus and confuse users; on GNOME a
  #      modal polkit dialog with no keyboard grab can look like a hung desktop.
  # ---------------------------------------------------------------------------
  write_file /etc/polkit-1/rules.d/49-xrdp-no-password.rules 0644 <<'POLKIT'
/* /etc/polkit-1/rules.d/49-xrdp-no-password.rules
 * Managed by ubuntu-rdp-setup.sh
 * Suppresses the colord / packagekit authentication dialogs that otherwise pop
 * up on every XRDP login. Scoped to local (RDP counts as local) active sessions
 * for users in the sudo group only.
 */
polkit.addRule(function(action, subject) {
    if ((action.id.indexOf("org.freedesktop.color-manager.") === 0 ||
         action.id.indexOf("org.freedesktop.packagekit.") === 0) &&
        subject.local && subject.active && subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
POLKIT

  # ---------------------------------------------------------------------------
  # 6.8  Kernel TCP tuning - detect dead RDP clients quickly.
  #      Default keepalive is 2 hours; a client that vanishes leaves an
  #      ESTABLISHED socket for that long, and the session looks "connected" to
  #      sesman the whole time. 120s/20s/3 detects it in about three minutes.
  # ---------------------------------------------------------------------------
  write_file /etc/sysctl.d/99-xrdp-keepalive.conf 0644 <<'SYSCTL'
# /etc/sysctl.d/99-xrdp-keepalive.conf -- managed by ubuntu-rdp-setup.sh
# Detect vanished RDP clients in ~3 minutes instead of ~2 hours, so that
# half-open sockets stop keeping zombie sessions alive.
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3
SYSCTL
  run sysctl --system >/dev/null

  # ---------------------------------------------------------------------------
  # 6.9  systemd drop-in - make xrdp itself self-healing
  # ---------------------------------------------------------------------------
  write_file /etc/systemd/system/xrdp.service.d/override.conf 0644 <<'XRDPOVERRIDE'
# Managed by ubuntu-rdp-setup.sh
# Layer 4a: xrdp must come back on its own if it ever dies, and it must not
# start before the boot-time cleanup has removed stale sockets.
[Unit]
After=xrdp-boot-cleanup.service
Wants=xrdp-boot-cleanup.service

[Service]
Restart=always
RestartSec=5
XRDPOVERRIDE

  write_file /etc/systemd/system/xrdp-sesman.service.d/override.conf 0644 <<'SESMANOVERRIDE'
# Managed by ubuntu-rdp-setup.sh
[Service]
Restart=always
RestartSec=5
SESMANOVERRIDE

  run systemctl daemon-reload
  ok "XRDP configured"
  mark_stage_done "06-configure-xrdp"
}

# =============================================================================
#  STAGE 07 - GOOGLE CHROME
#
#  WHY a wrapper script: on a headless server there is no GNOME keyring, and
#  Chrome's default password store probes it, hangs, and on some builds refuses
#  to start at all over RDP. --password-store=basic removes the probe.
#  --disable-gpu / --disable-dev-shm-usage matter because a VPS has no GPU and a
#  small /dev/shm, which otherwise produces blank tabs and renderer crashes.
# =============================================================================
# -----------------------------------------------------------------------------
# trust_desktop_file <path-to-.desktop>
#
#  WHY THIS EXISTS: dropping a .desktop file on the desktop is not enough. Every
#  modern desktop refuses to launch one it does not trust, and shows
#      "Untrusted application launcher - the desktop file is in an insecure
#       location and not marked as executable"
#  on every single double-click. Making it executable does NOT silence this on
#  XFCE 4.18+ (the version in Ubuntu 24.04): xfdesktop additionally requires a
#  gio metadata attribute, metadata::xfce-exe-checksum, holding the SHA-256 of
#  the file. Observed on a real install: the file was already 0755 and
#  user-owned, and the prompt still appeared, because that attribute was unset.
#
#  So all three things are needed:
#    1. the executable bit
#    2. metadata::xfce-exe-checksum = sha256 of the file   (XFCE)
#    3. metadata::trusted = true                           (GNOME/Nautilus)
#
#  gio writes to ~/.local/share/gvfs-metadata, so it must run AS the user. It
#  works without a live session as long as XDG_RUNTIME_DIR points somewhere the
#  user can write. Failure here is cosmetic, never fatal.
# -----------------------------------------------------------------------------
trust_desktop_file() {
  local file="$1" sum uid
  [[ -f "$file" ]] || return 0
  [[ $DRY_RUN -eq 1 ]] && { printf '%s[dry-run]%s would trust %s\n' "$C_YLW" "$C_RESET" "$file"; return 0; }

  chmod 0755 "$file" 2>/dev/null || true
  chown "${RDP_USER}:${RDP_USER}" "$file" 2>/dev/null || true

  command -v gio >/dev/null 2>&1 || { warn "gio not found; ${file##*/} may prompt on first launch"; return 0; }

  sum="$(sha256sum "$file" | cut -d" " -f1)"
  uid="$(id -u "$RDP_USER")"
  install -d -o "$RDP_USER" -g "$RDP_USER" -m 0700 "/run/user/${uid}" 2>/dev/null || true

  sudo -u "$RDP_USER" XDG_RUNTIME_DIR="/run/user/${uid}" \
       gio set -t string "$file" metadata::xfce-exe-checksum "$sum" 2>/dev/null \
    || warn "could not set metadata::xfce-exe-checksum on ${file##*/}"
  sudo -u "$RDP_USER" XDG_RUNTIME_DIR="/run/user/${uid}" \
       gio set -t string "$file" metadata::trusted true 2>/dev/null || true

  _log TRUST "${file} sha256=${sum}"
}

stage_07_install_chrome() {
  CURRENT_STAGE="07-install-chrome"
  step "Stage 07/10 - Installing Google Chrome"

  local arch; arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    warn "Google Chrome ships for amd64 only; this box is ${arch}."
    info "Installing Chromium instead."
    apt_install chromium-browser || apt_install chromium || warn "No Chromium package available."
    mark_stage_done "07-install-chrome"
    return 0
  fi

  # Modern keyring approach; apt-key is deprecated and removed in 24.04.
  local keyring=/etc/apt/keyrings/google-chrome.gpg
  if [[ ! -s "$keyring" || $FORCE -eq 1 ]]; then
    info "Adding Google's signing key ..."
    run install -d -m 0755 /etc/apt/keyrings
    if [[ $DRY_RUN -eq 0 ]]; then
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor --yes -o "$keyring" \
        || die "Could not fetch Google's signing key"
      chmod 0644 "$keyring"
    fi
  fi

  write_file /etc/apt/sources.list.d/google-chrome.list 0644 <<'CHROMELIST'
# Managed by ubuntu-rdp-setup.sh
deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main
CHROMELIST

  apt_retry update || die "apt-get update failed after adding the Chrome repo"
  apt_install google-chrome-stable

  # Wrapper. Placed in /usr/local/bin, which precedes /usr/bin in PATH, so both
  # the terminal and the .desktop launcher (rewritten below) pick it up.
  write_file /usr/local/bin/google-chrome-rdp 0755 <<'CHROMEWRAP'
#!/bin/sh
# /usr/local/bin/google-chrome-rdp -- managed by ubuntu-rdp-setup.sh
# Chrome launcher tuned for a headless VPS reached over XRDP.
#   --password-store=basic    no GNOME keyring exists here; the keyring probe
#                             hangs or blocks startup entirely over RDP
#   --disable-gpu             there is no GPU; GPU init produces blank tabs
#   --disable-software-rasterizer / --disable-dev-shm-usage
#                             /dev/shm on a VPS is small -> renderer crashes
#   --disable-features=...    Chrome's Wayland/Vulkan probes are pointless here
exec /usr/bin/google-chrome-stable \
  --password-store=basic \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-dev-shm-usage \
  --disable-features=UseOzonePlatform,VizDisplayCompositor \
  --ozone-platform=x11 \
  "$@"
CHROMEWRAP

  # Point the desktop launcher at the wrapper so clicking the icon uses it too.
  if [[ $DRY_RUN -eq 0 && -f /usr/share/applications/google-chrome.desktop ]]; then
    cp -a /usr/share/applications/google-chrome.desktop \
          "/usr/share/applications/google-chrome.desktop${BACKUP_SUFFIX}" 2>/dev/null || true
    sed -i 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/google-chrome-rdp|' \
        /usr/share/applications/google-chrome.desktop
    sed -i 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/local/bin/google-chrome-rdp|' \
        /usr/share/applications/google-chrome.desktop 2>/dev/null || true
  fi

  # Enterprise policy: turn off the first-run noise so the first RDP login lands
  # straight on a usable browser.
  write_file /etc/opt/chrome/policies/managed/rdp-defaults.json 0644 <<'CHROMEPOLICY'
{
  "_comment": "Managed by ubuntu-rdp-setup.sh - first-run experience for an RDP workstation",
  "PromotionalTabsEnabled": false,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BackgroundModeEnabled": false,
  "PasswordManagerEnabled": true,
  "BrowserSignin": 1
}
CHROMEPOLICY

  # Make Chrome the default browser for the desktop user.
  if [[ $DRY_RUN -eq 0 ]]; then
    local home; home="$(getent passwd "$RDP_USER" | cut -d: -f6)"
    mkdir -p "${home}/.config"
    cat > "${home}/.config/mimeapps.list" <<'MIMEAPPS'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
text/html=google-chrome.desktop
MIMEAPPS
    chown -R "${RDP_USER}:${RDP_USER}" "${home}/.config"
    # Desktop shortcut, so the icon is visible the moment they log in.
    mkdir -p "${home}/Desktop"
    if [[ -f /usr/share/applications/google-chrome.desktop ]]; then
      cp /usr/share/applications/google-chrome.desktop "${home}/Desktop/" || true
      chown "${RDP_USER}:${RDP_USER}" "${home}/Desktop/google-chrome.desktop" || true
      trust_desktop_file "${home}/Desktop/google-chrome.desktop"
    fi
    chown "${RDP_USER}:${RDP_USER}" "${home}/Desktop"
  fi

  ok "Google Chrome installed (launch via the desktop icon or 'google-chrome-rdp')"
  mark_stage_done "07-install-chrome"
}

# =============================================================================
#  STAGE 08 - THE ZOMBIE-SESSION REAPER  (layers 3 and 4)
#
#  This is the heart of the script. Read the header comment inside the generated
#  reaper for the full algorithm.
# =============================================================================
stage_08_reaper() {
  CURRENT_STAGE="08-reaper"
  step "Stage 08/10 - Installing the XRDP zombie-session reaper"

  write_file "$REAPER_BIN" 0755 <<'REAPER'
#!/usr/bin/env bash
# =============================================================================
#  /usr/local/sbin/xrdp-session-reaper
#  Managed by ubuntu-rdp-setup.sh  --  reaper version 1.1.0
# =============================================================================
#
#  PURPOSE
#    Garbage-collect XRDP sessions that are genuinely orphaned, plus the on-disk
#    debris they leave behind. Without this, the next login gets a black screen
#    or an RDP window that closes seconds after authenticating.
#
#  ---------------------------------------------------------------------------
#  HARD-WON LESSON (reaper 1.1.0) - READ BEFORE CHANGING THE DETECTION LOGIC
#  ---------------------------------------------------------------------------
#  Reaper 1.0.0 tried to decide whether a client was attached by correlating
#  ESTABLISHED TCP connections on port 3389 back to an X display, via the
#  connection process cmdline, its children, and its environment.
#
#  ALL THREE OF THOSE SOURCES ARE EMPTY. Measured on Ubuntu 24.04, xrdp 0.9.24,
#  on a live, actively-used session:
#      pid 55464: cmdline "/usr/sbin/xrdp"   <- no display anywhere
#                 children: (none)
#                 DISPLAY in environ: NONE
#                 fds referencing X sockets: 0
#  So attached_displays() always returned an empty set, EVERY live session
#  looked clientless, and the reaper killed working desktops 120 seconds after
#  login - taking the user's browser and unsaved work with it. That is far worse
#  than the problem the reaper exists to solve.
#
#  THE CORRECT SIGNAL is the process tree. A live session looks like this:
#      52171     1  /usr/sbin/xrdp-sesman         <- master sesman
#      55484 52171  /usr/sbin/xrdp-sesman         <- per-session leader
#      55486 55484  /usr/lib/xorg/Xorg :10 ...    <- child of the leader
#      55491 55484  /usr/sbin/xrdp-chansrv        <- child of the leader
#  While a session is alive, sesman keeps a per-session process as the parent of
#  that display's Xorg. If that parent dies without cleaning up, Xorg is
#  reparented to PID 1 - and THAT is an orphan worth reaping.
#
#  DESIGN RULE ADOPTED IN 1.1.0: the reaper does not try to out-guess sesman
#  about who is connected. Disconnect handling belongs to sesman, which already
#  does it via KillDisconnected=true + DisconnectedTimeLimit=60 in sesman.ini.
#  The reaper handles only what sesman cannot: processes it has lost track of,
#  leftover debris, and a dead listener. It is deliberately conservative - a
#  missed zombie costs one manual cleanup, a wrongly-killed session costs the
#  user their work.
#
#  ALGORITHM (one pass; the timer runs it every 60 seconds)
#    1. Enumerate candidate displays >= X11DisplayOffset (10) from running
#       Xorg/Xvnc processes and /tmp/.X11-unix sockets. :0 is never touched.
#    2. For each display, find its X server process and look at the PARENT:
#         - parent is a live xrdp-sesman/xrdp-sessvc  -> LIVE, never touched
#         - parent is PID 1 (orphaned)                -> candidate zombie
#         - no X server process at all                -> debris only, clean it
#    3. Grace period: an orphan must stay orphaned for GRACE_SECONDS (default
#       120) across consecutive sweeps before it is reaped. This avoids racing
#       sesman during its own teardown, and avoids reaping a session that is
#       mid-startup.
#    4. Reap: SIGTERM the session process tree, wait, SIGKILL survivors.
#    5. Clean the debris that actually causes the black screen: X11 sockets,
#       X locks, xrdp chansrv sockets, oversized ~/.xsession-errors, corrupt
#       ~/.Xauthority.
#    6. Self-heal: if nothing is listening on 3389, or xrdp/xrdp-sesman is in a
#       failed state, restart them.
#
#  SAFETY RULES (do not weaken these)
#    - Never touch display :0 or any display below X11DisplayOffset.
#    - Never kill an X server whose parent is a live sesman process.
#    - Never kill PID 1, or any process not owned by a normal user (uid >= 1000)
#      or the xrdp service user.
#    - Every destructive action is logged to /var/log/xrdp-reaper.log.
#
#  FLAGS
#    --dry-run       report what would be killed/removed; change nothing
#    --verbose       log LIVE sessions too, not just actions
#    --cleanup-only  only remove orphaned debris; used by the boot cleanup unit
#    --grace=N       override the grace period in seconds (default 120)
#    --status        print a one-shot view of every display and its verdict
# =============================================================================

set -uo pipefail   # NOT -e: a single failed probe must never abort a sweep.

REAPER_VERSION="1.1.0"
LOG=/var/log/xrdp-reaper.log
STATE=/run/xrdp-reaper
GRACE_SECONDS=120
DISPLAY_OFFSET=10
DRY=0
VERBOSE=0
CLEANUP_ONLY=0
STATUS_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY=1 ;;
    --verbose)      VERBOSE=1 ;;
    --cleanup-only) CLEANUP_ONLY=1 ;;
    --status)       STATUS_ONLY=1 ;;
    --grace=*)      GRACE_SECONDS="${arg#*=}" ;;
    --version)      echo "xrdp-session-reaper ${REAPER_VERSION}"; exit 0 ;;
    -h|--help)      sed -n '2,90p' "$0"; exit 0 ;;
    *)              echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG"; }
act() {
  local desc="$1"; shift
  if [[ $DRY -eq 1 ]]; then log DRYRUN "$desc"; return 0; fi
  log ACTION "$desc"
  "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# discover_displays -- candidate display numbers, one per line
# ---------------------------------------------------------------------------
discover_displays() {
  {
    ps -eo args= 2>/dev/null \
      | grep -Eo '(^|/)(Xorg|Xvnc)[[:space:]]+:[0-9]+' \
      | grep -Eo ':[0-9]+' | tr -d ':'
    for s in /tmp/.X11-unix/X*; do
      [[ -e "$s" ]] || continue
      echo "${s##*/X}"
    done
  } 2>/dev/null | grep -E '^[0-9]+$' | sort -un | awk -v off="$DISPLAY_OFFSET" '$1 >= off'
}

# ---------------------------------------------------------------------------
# xserver_pid_for_display <display>  -- prints the X server PID, or nothing
# ---------------------------------------------------------------------------
xserver_pid_for_display() {
  local d="$1" pid args
  for pid in $(ps -eo pid= 2>/dev/null); do
    args="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
    case "$args" in
      *"Xorg :${d} "*|*"Xvnc :${d} "*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# display_verdict <display>  -- prints LIVE | ORPHAN | EMPTY  (+ detail)
#
# THIS IS THE FUNCTION THAT GOT IT WRONG IN 1.0.0. It now looks only at the
# process tree, which is the one signal that is actually present.
# ---------------------------------------------------------------------------
display_verdict() {
  local d="$1" xpid ppid pcomm
  xpid="$(xserver_pid_for_display "$d")"
  if [[ -z "$xpid" ]]; then
    echo "EMPTY no-x-server"
    return 0
  fi
  ppid="$(awk '{print $4}' "/proc/${xpid}/stat" 2>/dev/null)"
  if [[ -z "$ppid" ]]; then
    echo "EMPTY x-server-vanished"
    return 0
  fi
  if [[ "$ppid" -le 1 ]]; then
    echo "ORPHAN xpid=${xpid} reparented-to-init"
    return 0
  fi
  pcomm="$(cat "/proc/${ppid}/comm" 2>/dev/null || echo unknown)"
  case "$pcomm" in
    xrdp-sesman|xrdp-sessvc|sesman)
      echo "LIVE xpid=${xpid} parent=${pcomm}(${ppid})" ;;
    *)
      # Unknown parent. Be conservative: treat as live and say so loudly, rather
      # than risk killing a working desktop on a layout we have not seen.
      echo "LIVE xpid=${xpid} parent=${pcomm}(${ppid}) UNRECOGNISED-PARENT" ;;
  esac
}

# ---------------------------------------------------------------------------
# pids_for_display -- every process belonging to a display (used only to reap)
# ---------------------------------------------------------------------------
pids_for_display() {
  local d="$1" pid uid xrdp_uid args
  xrdp_uid="$(id -u xrdp 2>/dev/null || echo -1)"
  for pid in $(ps -eo pid= 2>/dev/null); do
    [[ -z "$pid" || ! -d "/proc/$pid" ]] && continue
    [[ "$pid" -le 1 ]] && continue
    if ! tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
         | grep -qE "^DISPLAY=:${d}(\.0)?$"; then
      args="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
      case "$args" in
        *"Xorg :${d} "*|*"Xvnc :${d} "*) ;;
        *) continue ;;
      esac
    fi
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
    [[ -z "$uid" ]] && continue
    if [[ "$uid" -ge 1000 ]] || [[ "$uid" == "$xrdp_uid" ]]; then
      echo "$pid"
    fi
  done | sort -un
}

clean_display_debris() {
  local d="$1" f
  act "rm stale X11 socket /tmp/.X11-unix/X${d}"  rm -f "/tmp/.X11-unix/X${d}"
  act "rm stale X lock /tmp/.X${d}-lock"          rm -f "/tmp/.X${d}-lock"
  for f in /tmp/.xrdp/xrdp_chansrv_socket_${d}* \
           /tmp/.xrdp/xrdp_display_${d}* \
           /tmp/.xrdp/xrdp_chansrv_audio_*_socket_${d}* ; do
    [[ -e "$f" ]] && act "rm stale xrdp socket $f" rm -f "$f"
  done
  rm -f "${STATE}/${d}.since" 2>/dev/null
}

clean_user_debris() {
  local user home uid
  while IFS=: read -r user _ uid _ _ home _; do
    [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
    [[ -d "$home" ]] || continue
    if [[ -f "${home}/.xsession-errors" ]] \
       && [[ "$(stat -c %s "${home}/.xsession-errors" 2>/dev/null || echo 0)" -gt 10485760 ]]; then
      act "truncate ${home}/.xsession-errors" truncate -s 0 "${home}/.xsession-errors"
    fi
    if [[ -f "${home}/.Xauthority" ]] \
       && [[ "$(stat -c %s "${home}/.Xauthority" 2>/dev/null || echo 0)" -gt 32768 ]]; then
      act "reset ${home}/.Xauthority" rm -f "${home}/.Xauthority"
    fi
  done < /etc/passwd
}

# Only clean saved-session state for displays with no X server: doing it while a
# session is running would delete the live session's own state.
clean_orphan_sockets() {
  local s d
  for s in /tmp/.X11-unix/X*; do
    [[ -e "$s" ]] || continue
    d="${s##*/X}"
    [[ "$d" =~ ^[0-9]+$ ]] || continue
    [[ "$d" -lt "$DISPLAY_OFFSET" ]] && continue
    if [[ -z "$(xserver_pid_for_display "$d")" ]]; then
      log INFO "orphan socket for :${d} (no X server) - cleaning"
      clean_display_debris "$d"
    fi
  done
}

reap_display() {
  local d="$1" pids pid
  pids="$(pids_for_display "$d" | tr '\n' ' ')"
  if [[ -z "${pids// /}" ]]; then
    log INFO "display :${d} has no processes; cleaning debris only"
    clean_display_debris "$d"
    return 0
  fi
  log WARN "ORPHANED display :${d} (X server reparented to init) held for >${GRACE_SECONDS}s. Reaping: ${pids}"
  if [[ $DRY -eq 1 ]]; then
    log DRYRUN "would SIGTERM then SIGKILL: ${pids}"
    return 0
  fi
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null; done
  sleep 5
  for pid in $pids; do
    [[ -d "/proc/$pid" ]] && { log ACTION "SIGKILL ${pid}"; kill -KILL "$pid" 2>/dev/null; }
  done
  sleep 1
  clean_display_debris "$d"
  log OK "display :${d} reaped"
}

self_heal() {
  local restart=0 unit
  if ! ss -lntH 2>/dev/null | grep -q ':3389 '; then
    log ERROR "nothing is listening on 3389"; restart=1
  fi
  for unit in xrdp xrdp-sesman; do
    if systemctl is-failed --quiet "$unit" 2>/dev/null; then
      log ERROR "${unit}.service is in a failed state"; restart=1
    fi
  done
  if [[ $restart -eq 1 ]]; then
    act "restart xrdp-sesman and xrdp" systemctl restart xrdp-sesman xrdp
    sleep 3
    if ss -lntH 2>/dev/null | grep -q ':3389 '; then
      log OK "xrdp restarted; 3389 is listening again"
    else
      log ERROR "xrdp restart did not restore the listener - manual attention needed"
    fi
  fi
}

# ---------------------------------------------------------------------------
# --status : human-readable snapshot, changes nothing. Use this to confirm the
#            reaper agrees with reality before trusting it.
# ---------------------------------------------------------------------------
if [[ $STATUS_ONLY -eq 1 ]]; then
  printf 'xrdp-session-reaper %s - status\n\n' "$REAPER_VERSION"
  printf '%-9s %s\n' "DISPLAY" "VERDICT"
  found=0
  for d in $(discover_displays); do
    found=1
    printf '%-9s %s\n' ":${d}" "$(display_verdict "$d")"
  done
  [[ $found -eq 0 ]] && printf '(no displays >= :%s)\n' "$DISPLAY_OFFSET"
  printf '\nlistening on 3389: '
  ss -lntH 2>/dev/null | grep -q ':3389 ' && printf 'yes\n' || printf 'NO\n'
  exit 0
fi

if [[ $CLEANUP_ONLY -eq 1 ]]; then
  log START "boot cleanup (reaper ${REAPER_VERSION}, --cleanup-only)"
  for s in /tmp/.X11-unix/X*; do
    [[ -e "$s" ]] || continue
    d="${s##*/X}"
    [[ "$d" =~ ^[0-9]+$ ]] && [[ "$d" -ge "$DISPLAY_OFFSET" ]] && clean_display_debris "$d"
  done
  act "clear stale /tmp/.xrdp sockets" find /tmp/.xrdp -type s -delete
  rm -f /tmp/.X1*-lock 2>/dev/null
  clean_user_debris
  # Safe only at boot, when no session can be running.
  for home in /home/*; do
    [[ -d "${home}/.cache/sessions" ]] && act "clear ${home}/.cache/sessions" rm -rf "${home}/.cache/sessions"
  done
  rm -rf "${STATE:?}"/* 2>/dev/null
  log OK "boot cleanup finished"
  exit 0
fi

log START "sweep (reaper ${REAPER_VERSION}, grace=${GRACE_SECONDS}s, dry=${DRY})"
NOW=$(date +%s)

for d in $(discover_displays); do
  verdict="$(display_verdict "$d")"
  state="${verdict%% *}"
  case "$state" in
    LIVE)
      rm -f "${STATE}/${d}.since" 2>/dev/null
      [[ $VERBOSE -eq 1 ]] && log INFO "display :${d} LIVE - ${verdict#* }"
      ;;
    EMPTY)
      log INFO "display :${d} has no X server (${verdict#* }); cleaning debris"
      clean_display_debris "$d"
      ;;
    ORPHAN)
      since_file="${STATE}/${d}.since"
      if [[ ! -f "$since_file" ]]; then
        echo "$NOW" > "$since_file"
        log INFO "display :${d} ORPHANED (${verdict#* }); starting ${GRACE_SECONDS}s grace timer"
        continue
      fi
      since="$(cat "$since_file" 2>/dev/null || echo "$NOW")"
      elapsed=$(( NOW - since ))
      if [[ $elapsed -lt $GRACE_SECONDS ]]; then
        log INFO "display :${d} orphaned for ${elapsed}s (grace ${GRACE_SECONDS}s)"
        continue
      fi
      reap_display "$d"
      ;;
  esac
done

clean_orphan_sockets
clean_user_debris
self_heal

log END "sweep finished"
exit 0
REAPER

  # ---- systemd: the periodic sweep (layer 3) ----
  write_file /etc/systemd/system/xrdp-session-reaper.service 0644 <<'REAPERSVC'
# Managed by ubuntu-rdp-setup.sh
# Layer 3: periodic garbage collection of dead XRDP sessions.
[Unit]
Description=XRDP zombie session reaper (sweep)
Documentation=file:/usr/local/sbin/xrdp-session-reaper
After=xrdp.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xrdp-session-reaper
# A sweep that hangs must not block the next one forever.
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
REAPERSVC

  write_file /etc/systemd/system/xrdp-session-reaper.timer 0644 <<'REAPERTIMER'
# Managed by ubuntu-rdp-setup.sh
[Unit]
Description=Run the XRDP zombie session reaper every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=xrdp-session-reaper.service

[Install]
WantedBy=timers.target
REAPERTIMER

  # ---- systemd: the boot-time wipe (layer 4) ----
  write_file /etc/systemd/system/xrdp-boot-cleanup.service 0644 <<'BOOTCLEAN'
# Managed by ubuntu-rdp-setup.sh
# Layer 4: at boot, nothing legitimate is running, so every X socket, lock and
# xrdp socket left on disk is by definition stale. Wipe them BEFORE xrdp starts
# so the first login after any crash or hard reboot always works.
[Unit]
Description=Clean stale XRDP session debris before xrdp starts
DefaultDependencies=no
After=local-fs.target
Before=xrdp.service xrdp-sesman.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xrdp-session-reaper --cleanup-only
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
BOOTCLEAN

  # ---- log rotation, so the reaper log cannot fill the disk ----
  write_file /etc/logrotate.d/xrdp-reaper 0644 <<'LOGROTATE'
# Managed by ubuntu-rdp-setup.sh
/var/log/xrdp-reaper.log /var/log/xrdp-setup.log {
    weekly
    rotate 4
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LOGROTATE

  run touch /var/log/xrdp-reaper.log
  run chmod 0640 /var/log/xrdp-reaper.log
  run systemctl daemon-reload
  run systemctl enable xrdp-boot-cleanup.service
  run systemctl enable --now xrdp-session-reaper.timer

  ok "Reaper installed: sweeps every 60s, plus a boot-time cleanup"
  info "Inspect it with: journalctl -u xrdp-session-reaper -f   |   tail -f /var/log/xrdp-reaper.log"
  mark_stage_done "08-reaper"
}

# =============================================================================
#  STAGE 09 - SECURITY
#
#  Port 3389 on a public IP is scanned within minutes of the box coming up.
#  Three cheap mitigations, in order of value:
#    1. restrict the source IP in UFW (by far the strongest)
#    2. fail2ban on xrdp-sesman auth failures
#    3. TLS, already configured in stage 06
# =============================================================================
stage_09_security() {
  CURRENT_STAGE="09-security"
  step "Stage 09/10 - Firewall and brute-force protection"

  apt_install ufw fail2ban

  # ---- UFW ----
  # DESIGN DECISION (v1.1.0): RDP is opened to any source address.
  # The operator connects from changing/unknown IPs (roaming laptop, mobile
  # tethering, CGNAT), so a source-IP allow-list would lock them out more often
  # than it would stop an attacker. Brute force is handled by the fail2ban jail
  # below, and the transport is TLS (stage 06). To lock 3389 down to a single
  # address later, do it by hand:
  #     sudo ufw delete allow 3389/tcp
  #     sudo ufw allow from <YOUR.IP> to any port 3389 proto tcp
  info "Firewall rules that will be applied:"
  printf '    allow 22/tcp   from any    (SSH - keeping you locked out would be rude)\n'
  printf '    allow %s/tcp from any    (RDP)\n' "$RDP_PORT"
  printf '    default deny incoming, allow outgoing\n\n'
  warn "Port ${RDP_PORT} will be reachable from the internet. fail2ban is your"
  warn "brute-force defence, so keep a strong password on the desktop account."
  printf '\n'

  if ask_yn "Apply these firewall rules now?" y; then
    run ufw --force reset >/dev/null 2>&1 || true
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow 22/tcp comment 'SSH'
    run ufw allow "${RDP_PORT}/tcp" comment 'XRDP'
    run ufw --force enable
    ok "UFW enabled (SSH + RDP open, everything else denied)"
  else
    warn "Firewall not changed. Make sure port ${RDP_PORT} is reachable via your provider's security group."
  fi

  # ---- fail2ban ----
  # xrdp-sesman logs failed logins to /var/log/xrdp-sesman.log in a format the
  # stock jail does not know about, so we ship our own filter.
  write_file /etc/fail2ban/filter.d/xrdp-sesman-custom.conf 0644 <<'F2BFILTER'
# Managed by ubuntu-rdp-setup.sh
# Matches xrdp-sesman authentication failures.
[Definition]
failregex = ^.*\[ERROR\].*login failed for user .* from <HOST>.*$
            ^.*\[INFO \].*login failed for display .*, user .* from <HOST>.*$
            ^.*AUTHFAIL.*client_ip=<HOST>.*$
            ^.*\[ERROR\].*: authentication failed.*IP: <HOST>.*$
ignoreregex =
F2BFILTER

  write_file /etc/fail2ban/jail.d/xrdp.local 0644 <<F2BJAIL
# Managed by ubuntu-rdp-setup.sh
# Ban a source after 5 failed RDP logins in 10 minutes, for 1 hour.
[xrdp-sesman-custom]
enabled  = true
port     = ${RDP_PORT}
protocol = tcp
filter   = xrdp-sesman-custom
logpath  = /var/log/xrdp-sesman.log
backend  = auto
maxretry = 5
findtime = 600
bantime  = 3600
F2BJAIL

  run systemctl enable fail2ban
  run systemctl restart fail2ban || warn "fail2ban failed to restart; check 'journalctl -u fail2ban'"

  ok "Security configured (UFW + fail2ban + TLS)"
  mark_stage_done "09-security"
}

# =============================================================================
#  STAGE 10 - VERIFY AND REPORT
# =============================================================================
stage_10_verify() {
  CURRENT_STAGE="10-verify"
  step "Stage 10/10 - Verifying the installation"

  run systemctl restart xrdp-sesman || true
  run systemctl restart xrdp || true
  sleep 3

  local failures=0
  check() { # check <label> <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf '    %s[ OK ]%s %s\n' "$C_GRN" "$C_RESET" "$label"
    else
      printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$label"
      failures=$((failures + 1))
    fi
  }

  printf '\n'
  check "xrdp.service is active"                   systemctl is-active --quiet xrdp
  check "xrdp-sesman.service is active"            systemctl is-active --quiet xrdp-sesman
  check "xrdp.service is enabled at boot"          systemctl is-enabled --quiet xrdp
  check "xrdp-session-reaper.timer is active"      systemctl is-active --quiet xrdp-session-reaper.timer
  check "xrdp-boot-cleanup.service is enabled"     systemctl is-enabled --quiet xrdp-boot-cleanup.service
  check "port ${RDP_PORT} is listening"            bash -c "ss -lntH | grep -q ':${RDP_PORT} '"
  check "reaper binary is executable"              test -x "$REAPER_BIN"
  check "TLS certificate is readable by xrdp"      sudo -u xrdp test -r /etc/xrdp/key.pem
  check "user '${RDP_USER}' exists"                id -u "$RDP_USER"
  check "startwm.sh is executable"                 test -x /etc/xrdp/startwm.sh
  # If this attribute is missing, XFCE shows "Untrusted application launcher"
  # on every double-click of the Chrome icon.
  if [[ -f "$(getent passwd "$RDP_USER" | cut -d: -f6)/Desktop/google-chrome.desktop" ]]; then
    check "Chrome desktop icon is trusted"         bash -c "sudo -u ${RDP_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${RDP_USER}) gio info -a metadata::xfce-exe-checksum \"$(getent passwd "$RDP_USER" | cut -d: -f6)/Desktop/google-chrome.desktop\" 2>/dev/null | grep -q xfce-exe-checksum"
  fi
  # Font coverage: 0 here means every Indic page renders as empty boxes.
  check "Devanagari fonts present"                 bash -c "[[ \$(fc-list :lang=hi | wc -l) -gt 0 ]]"
  check "Tamil fonts present"                      bash -c "[[ \$(fc-list :lang=ta | wc -l) -gt 0 ]]"
  check "emoji font present"                       bash -c "[[ \$(fc-list :lang=und-zsye | wc -l) -gt 0 ]]"
  if [[ "$TIMEZONE" != "keep" ]]; then
    check "timezone is ${TIMEZONE}"                 bash -c "[[ \"\$(timedatectl show -p Timezone --value)\" == \"${TIMEZONE}\" ]]"
  fi
  # REGRESSION GUARD (v1.2.0): ls_logo_filename only exists in the distro
  # xrdp.ini. If it is missing, something hand-wrote the file and the login
  # screen will render as a bare coloured rectangle with no username box.
  check "xrdp.ini login-screen block intact"       grep -q '^ls_logo_filename' /etc/xrdp/xrdp.ini
  check "xrdp.ini has session geometry keys"       grep -q '^ls_width' /etc/xrdp/xrdp.ini
  if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
    check "Google Chrome is installed"             test -x /usr/bin/google-chrome-stable
  fi
  printf '\n'

  # A dry-run reaper sweep proves the reaper actually parses this system.
  info "Test sweep of the reaper (dry-run, nothing will be killed):"
  "$REAPER_BIN" --dry-run --verbose >/dev/null 2>&1 \
    && ok "Reaper ran cleanly" \
    || warn "Reaper test sweep reported a problem; see /var/log/xrdp-reaper.log"

  SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local public_ip; public_ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"

  printf '\n%s%s' "$C_BLD" "$C_GRN"
  printf '=====================================================================\n'
  printf '  SETUP COMPLETE\n'
  printf '=====================================================================%s\n\n' "$C_RESET"
  printf '  Connect with any RDP client (Windows: mstsc.exe)\n\n'
  printf '    Address    : %s%s%s\n' "$C_BLD" "${public_ip:-$SERVER_IP}:${RDP_PORT}" "$C_RESET"
  [[ -n "$public_ip" && "$public_ip" != "$SERVER_IP" ]] && \
  printf '    Private IP : %s\n' "${SERVER_IP}:${RDP_PORT}"
  printf '    Username   : %s%s%s\n' "$C_BLD" "$RDP_USER" "$C_RESET"
  printf '    Password   : (the one you just set)\n'
  printf '    Desktop    : %s\n' "${DE_CHOICE^^}"
  printf '    Browser    : Google Chrome (icon on the desktop)\n'
  printf '    Timezone   : %s  (%s)\n\n' "$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)" "$(date '+%H:%M %Z')"
  printf '  The first connection shows a certificate warning - that is the\n'
  printf '  self-signed TLS certificate. Accept it.\n\n'
  printf '  Useful commands\n'
  printf '    Reaper log      : tail -f /var/log/xrdp-reaper.log\n'
  printf '    Reaper status   : systemctl status xrdp-session-reaper.timer\n'
  printf '    Force a sweep   : sudo %s --verbose\n' "$REAPER_BIN"
  printf '    Dry-run a sweep : sudo %s --dry-run --verbose\n' "$REAPER_BIN"
  printf '    XRDP log        : tail -f /var/log/xrdp-sesman.log\n'
  printf '    Setup log       : %s\n\n' "$LOG_FILE"

  if [[ $failures -gt 0 ]]; then
    warn "${failures} verification check(s) failed. Review the output above and ${LOG_FILE}."
  fi
  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is pending from the package upgrade. Reboot when convenient:  sudo reboot"
    printf '  (RDP comes back automatically after reboot - that is what the boot\n'
    printf '   cleanup unit is for.)\n\n'
  fi

  mark_stage_done "10-verify"
}

# =============================================================================
#  ARGUMENT PARSING AND MAIN
# =============================================================================
usage() {
  sed -n '2,75p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run)      DRY_RUN=1 ;;
      --force)        FORCE=1 ;;
      --skip-upgrade) SKIP_UPGRADE=1 ;;
      --de=*)         DE_CHOICE="${arg#*=}" ;;
      --timezone=*)   TIMEZONE="${arg#*=}" ;;
      --version)      echo "ubuntu-rdp-setup.sh ${SCRIPT_VERSION}"; exit 0 ;;
      -h|--help)      usage ;;
      *)              echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
  done
  case "${DE_CHOICE}" in
    ""|xfce|mate|gnome) ;;
    *) echo "--de must be one of: xfce, mate, gnome" >&2; exit 2 ;;
  esac
}

main() {
  parse_args "$@"
  printf '\n%s%s  Ubuntu 24.04 -> XRDP desktop + Chrome   (v%s)%s\n' "$C_BLD" "$C_CYN" "$SCRIPT_VERSION" "$C_RESET"
  printf '%s  Fail-proof XRDP with a zombie-session reaper%s\n' "$C_CYN" "$C_RESET"
  [[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN MODE: nothing will be changed"

  stage_00_preflight "$@"

  if stage_done "01-update"; then
    # Re-run with --skip-upgrade so the timezone block still applies on a resume.
    info "Stage 01 already done; re-checking timezone only"
    SKIP_UPGRADE=1 stage_01_update
  else
    stage_01_update
  fi

  # Stages 02 and 03 always run interactively if their values are not on disk,
  # because later stages need $DE_CHOICE and $RDP_USER regardless of resume state.
  if stage_done "02-detect-specs" && [[ -f "${STATE_DIR}/desktop" ]]; then
    DE_CHOICE="$(cat "${STATE_DIR}/desktop")"
    info "Stage 02 already done; desktop = ${DE_CHOICE^^}"
  else
    stage_02_detect_specs
  fi

  if stage_done "03-create-user" && [[ -f "${STATE_DIR}/rdp_user" ]]; then
    RDP_USER="$(cat "${STATE_DIR}/rdp_user")"
    info "Stage 03 already done; RDP user = ${RDP_USER}"
  else
    stage_03_create_user
  fi

  if stage_done "04-install-de";    then info "Stage 04 already done, skipping"; else stage_04_install_de;    fi
  if stage_done "05-install-xrdp";  then info "Stage 05 already done, skipping"; else stage_05_install_xrdp;  fi
  stage_06_configure_xrdp        # always re-applied: cheap, and self-healing
  if stage_done "07-install-chrome"; then info "Stage 07 already done, skipping"; else stage_07_install_chrome; fi
  stage_08_reaper                # always re-applied: keeps the reaper current
  if stage_done "09-security";      then info "Stage 09 already done, skipping"; else stage_09_security;      fi
  stage_10_verify

  _log END "=== finished successfully ==="
}

main "$@"
