#!/bin/bash
# Lima system provision: adapted from the existing macOS hardening script.
set -e
if ! /usr/bin/xcrun --find python3 >/dev/null 2>&1; then
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  label="$(softwareupdate -l | sed -n 's/.*Label: \(Command Line Tools.*\)/\1/p' | tail -1)"
  [ -n "$label" ] && softwareupdate -i "$label" --agree-to-license
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
/usr/bin/xcrun --find python3 >/dev/null
if ! id work >/dev/null 2>&1; then
  PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  sysadminctl -addUser work -fullName "TATWO sandbox work" -password "$PW" -home /Users/work >/dev/null 2>&1
  createhomedir -c -u work >/dev/null 2>&1 || true
  unset PW
fi
dseditgroup -o edit -d work -t user admin 2>/dev/null || true
LIMA_HOME="$(dscl . -read "/Users/${LIMA_CIDATA_USER:-lima}" NFSHomeDirectory | cut -d ' ' -f 2-)"
chmod 600 "$LIMA_HOME/password"; chmod 700 "$LIMA_HOME"
if sudo -u work test -r "$LIMA_HOME/password"; then exit 1; fi
tee /etc/pf.anchors/tatwo >/dev/null <<'PF'
pass out quick proto { tcp udp } from any to 192.168.5.3 port 53 user work
block return out quick proto { tcp udp icmp } from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8 } user work
block return out quick inet6 from any to { fc00::/7, fe80::/10, ::1 } user work
PF
grep -q 'anchor "tatwo"' /etc/pf.conf || printf 'anchor "tatwo"\nload anchor "tatwo" from "/etc/pf.anchors/tatwo"\n' | tee -a /etc/pf.conf >/dev/null
tee /Library/LaunchDaemons/com.tatwo.pf.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.tatwo.pf</string>
<key>ProgramArguments</key><array><string>/sbin/pfctl</string><string>-E</string><string>-f</string><string>/etc/pf.conf</string></array>
<key>RunAtLoad</key><true/></dict></plist>
PL
chown root:wheel /Library/LaunchDaemons/com.tatwo.pf.plist; chmod 644 /Library/LaunchDaemons/com.tatwo.pf.plist
launchctl bootstrap system /Library/LaunchDaemons/com.tatwo.pf.plist 2>/dev/null || true
pfctl -E -f /etc/pf.conf >/dev/null
# A work daemon can run before anyone logs into the guest desktop.
tee /Library/LaunchDaemons/com.tatwo.sandbox.plist >/dev/null <<'PL'
<plist version="1.0"><dict><key>Label</key><string>com.tatwo.sandbox</string><key>UserName</key><string>work</string><key>EnvironmentVariables</key><dict><key>HOME</key><string>/Users/work</string></dict><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>while [ ! -f /Users/work/.tatwo-sandbox/token.json ]; do sleep 2; done; /usr/bin/python3 /Users/work/.tatwo-sandbox/sandbox-agent.py run --runner sh; status=$?; [ "$status" -eq 3 ] &amp;&amp; exit 0; [ "$status" -eq 0 ] &amp;&amp; exit 0; sleep 60; exit "$status"</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>60</integer></dict></plist>
PL
chown root:wheel /Library/LaunchDaemons/com.tatwo.sandbox.plist; chmod 644 /Library/LaunchDaemons/com.tatwo.sandbox.plist
launchctl bootstrap system /Library/LaunchDaemons/com.tatwo.sandbox.plist 2>/dev/null || launchctl print system/com.tatwo.sandbox >/dev/null
