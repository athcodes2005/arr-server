#!/usr/bin/env bash
#
# Idempotently configures unattended-upgrades on the Pi:
#   - Installs the package if missing.
#   - Allows ONLY Debian security/stable-updates and Raspberry Pi Foundation
#     stable channels — never bleeding-edge rpi-update kernels, never
#     backports/testing/unstable, never third-party repos like Docker CE.
#   - Reschedules apt-daily timers around the user's 03:00 router reboot
#     (apt-daily 04:00, apt-daily-upgrade 04:30, auto-reboot 05:00).
#
# Designed to be re-run on every deploy from bootstrap-remote.sh. All writes
# are content-stable, so re-running with no changes is a no-op aside from a
# `systemctl daemon-reload`.
#
# Requires passwordless sudo for apt-get, tee, sed, systemctl — same
# privilege level the rest of bootstrap-remote.sh already needs.
set -euo pipefail

log() {
  printf '[unattended] %s\n' "$*"
}

ensure_packages_installed() {
  if dpkg -s unattended-upgrades >/dev/null 2>&1 \
     && dpkg -s apt-listchanges >/dev/null 2>&1; then
    return 0
  fi
  log "Installing unattended-upgrades + apt-listchanges"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    unattended-upgrades apt-listchanges >/dev/null
}

write_policy() {
  # Stable-only origins. Reboot at 05:00 (after the user's 03:00 router
  # maintenance window and after apt-daily-upgrade has applied at 04:30).
  sudo tee /etc/apt/apt.conf.d/52arr-server-unattended >/dev/null <<'EOF'
// Managed by scripts/install-unattended-upgrades.sh — do not edit by hand.
//
// arr-server: stable-only auto-upgrade policy.
// Allows security patches, Debian stable point-release updates, and the
// Raspberry Pi Foundation stable channel (kernel + firmware tested by RPi
// Foundation, NOT the bleeding-edge rpi-update GitHub builds).

Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";
    "origin=Raspberry Pi Foundation,archive=stable";
};

// Reboot at 05:00 if a kernel/libc/dbus update needs it. The 03:00 router
// reboot has fully recovered by then and apt-daily-upgrade (04:30) has
// finished applying packages.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:00";

// No mail server on this host; suppress the report.
Unattended-Upgrade::Mail "";

// Be quiet on success, verbose on errors so journalctl is useful.
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";

Unattended-Upgrade::Package-Blacklist {
};
EOF

  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
// Managed by scripts/install-unattended-upgrades.sh — do not edit by hand.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "1";
EOF
}

write_timer_overrides() {
  # Default apt-daily.timer fires 00:00 + RandomizedDelaySec=12h, so it can
  # run anywhere from midnight to noon — that overlaps the 03:00 router
  # reboot window. Pin it to 04:00 ± 15 min.
  sudo mkdir -p \
    /etc/systemd/system/apt-daily.timer.d \
    /etc/systemd/system/apt-daily-upgrade.timer.d

  sudo tee /etc/systemd/system/apt-daily.timer.d/arr-server-schedule.conf >/dev/null <<'EOF'
# Managed by scripts/install-unattended-upgrades.sh — do not edit by hand.
# Shift apt-daily out of the 03:00 router-reboot window.
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=15m
Persistent=true
EOF

  sudo tee /etc/systemd/system/apt-daily-upgrade.timer.d/arr-server-schedule.conf >/dev/null <<'EOF'
# Managed by scripts/install-unattended-upgrades.sh — do not edit by hand.
# Run apt-daily-upgrade right after apt-daily completes its refresh.
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=10m
Persistent=true
EOF
}

reload_and_restart_timers() {
  sudo systemctl daemon-reload
  sudo systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  sudo systemctl restart apt-daily.timer apt-daily-upgrade.timer
}

main() {
  ensure_packages_installed
  write_policy
  write_timer_overrides
  reload_and_restart_timers
  log "Stable-only auto-upgrades active (apt-daily 04:00, upgrade 04:30, reboot 05:00)"
}

main "$@"
