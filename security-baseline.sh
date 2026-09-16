#!/usr/bin/env bash
# security-baseline v1.0 — CIS-aligned security audit + hardening script generator
# Usage:
#   bash security-baseline.sh --audit          # audit only (read-only report)
#   bash security-baseline.sh --audit --md r.md # also write markdown report
#   bash security-baseline.sh --harden          # generate hardening script
# Requires: bash, coreutils. Tested on Ubuntu 20.04+, Debian 11+, RHEL/Rocky 8+

set -u
MODE="audit"; MDFILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --audit) MODE="audit"; shift ;;
    --harden) MODE="harden"; shift ;;
    --md) MDFILE="$2"; shift 2 ;;
    *) echo "Usage: $0 --audit [--md file.md] | --harden"; exit 1 ;;
  esac
done

G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[36m"; Bd="\033[1m"; _="\033[0m"
PASS=0; WARN=0; FAIL=0; HARD=0
MDL=()

p_pass(){ PASS=$((PASS+1)); echo -e "  ${G}[PASS]${_} $1"; [[ -n "$MDFILE" ]] && MDL+=("- ✅ $1"); }
p_warn(){ WARN=$((WARN+1)); echo -e "  ${Y}[WARN]${_} $1"; [[ -n "$MDFILE" ]] && MDL+=("- ⚠️ $1"); }
p_fail(){ FAIL=$((FAIL+1)); echo -e "  ${R}[FAIL]${_} $1"; [[ -n "$MDFILE" ]] && MDL+=("- ❌ $1"); }
p_info(){ echo -e "  ${B}[INFO]${_} $1"; [[ -n "$MDFILE" ]] && MDL+=("- ℹ️ $1"); }
p_hard(){ HARD=$((HARD+1)); echo -e "  ${B}[FIX ]${_} $1"; }
section(){ echo -e "\n${Bd}━━ $1 ━━${_}"; [[ -n "$MDFILE" ]] && MDL+=("" "### $1"); }

HARDEN_FILE=""
if [[ "$MODE" == "harden" ]]; then
  HARDEN_FILE="hardening-$(date +%Y%m%d).sh"
  cat > "$HARDEN_FILE" << 'HEOF'
#!/usr/bin/env bash
# Auto-generated security hardening script
# Review before running! Some changes may impact your application.
set -e
echo "Applying security hardening..."
HEOF
fi

harden(){ if [[ "$MODE" == "harden" ]]; then echo "$1" >> "$HARDEN_FILE"; fi; }

section "1. SSH Configuration"
SSHD_CONF="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONF" ]]; then
  # Root login
  if grep -qiE '^\s*PermitRootLogin\s+(yes|prohibit-password)' "$SSHD_CONF" 2>/dev/null; then
    VAL=$(grep -i '^\s*PermitRootLogin' "$SSHD_CONF" | awk '{print $2}')
    if [[ "$VAL" == "yes" ]]; then
      p_fail "SSH permits root login with password"
      harden "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSHD_CONF"
    elif [[ "$VAL" == "prohibit-password" ]]; then
      p_warn "SSH allows root login with keys (consider: PermitRootLogin no)"
      harden "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSHD_CONF"
    fi
  else
    p_pass "SSH root login disabled or not explicitly enabled"
  fi

  # Password auth
  if grep -qiE '^\s*PasswordAuthentication\s+yes' "$SSHD_CONF" 2>/dev/null; then
    p_fail "SSH allows password authentication — brute-force target"
    harden "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONF"
  elif grep -qiE '^\s*PasswordAuthentication\s+no' "$SSHD_CONF" 2>/dev/null; then
    p_pass "SSH password authentication disabled"
  else
    p_warn "PasswordAuthentication not explicitly set (default: yes on some distros)"
    harden "echo 'PasswordAuthentication no' >> $SSHD_CONF"
  fi

  # Max auth tries
  MAXAUTH=$(grep -i '^\s*MaxAuthTries' "$SSHD_CONF" 2>/dev/null | awk '{print $2}')
  if [[ -z "$MAXAUTH" ]]; then
    p_warn "MaxAuthTries not set (default: 6 — too many)"
    harden "echo 'MaxAuthTries 3' >> $SSHD_CONF"
  elif [[ $MAXAUTH -gt 4 ]]; then
    p_warn "MaxAuthTries = $MAXAUTH (recommend ≤ 4)"
    harden "sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' $SSHD_CONF"
  else
    p_pass "MaxAuthTries = $MAXAUTH"
  fi

  # SSH protocol version
  p_pass "SSH protocol v2 (v1 unsupported in modern OpenSSH)"

  if [[ "$MODE" == "harden" ]]; then
    harden "systemctl restart sshd || systemctl restart ssh"
    harden "echo '⚠️ SSH restarted — verify you can still connect before closing this session!'"
  fi
else
  p_skip "No sshd_config found (SSH server not installed?)"
fi

section "2. Firewall"
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  if echo "$UFW_STATUS" | grep -q "inactive"; then
    p_fail "UFW firewall is INACTIVE — all ports exposed"
    harden "ufw default deny incoming && ufw default allow outgoing && ufw allow ssh && ufw --force enable"
  else
    p_pass "UFW firewall is active"
    RULES=$(ufw status 2>/dev/null | grep "ALLOW" | grep -c "Anywhere" || echo 0)
    if [[ $RULES -gt 5 ]]; then p_warn "UFW has $RULES 'Anywhere' rules — review if all are needed"; fi
  fi
elif command -v firewall-cmd &>/dev/null; then
  if systemctl is-active firewalld &>/dev/null; then
    p_pass "firewalld is active"
  else
    p_fail "firewalld is INACTIVE"
    harden "systemctl enable --now firewalld"
  fi
elif command -v nft &>/dev/null; then
  NFT_RULES=$(nft list ruleset 2>/dev/null | wc -l)
  if [[ $NFT_RULES -lt 5 ]]; then
    p_fail "nftables has no rules — all ports exposed"
  else
    p_pass "nftables active ($NFT_RULES lines of rules)"
  fi
else
  p_fail "No firewall detected (ufw, firewalld, or nftables)"
  harden "# Install a firewall: apt install ufw || dnf install firewalld"
fi

section "3. Password & Account Policies"
# Check for empty passwords
EMPTY_PW=$(awk -F: '($2 == "" ) {print $1}' /etc/shadow 2>/dev/null | wc -l)
if [[ $EMPTY_PW -gt 0 ]]; then
  p_fail "$EMPTY_PW account(s) with EMPTY passwords"
  harden "passwd -l <username>  # lock accounts with empty passwords"
else
  p_pass "No accounts with empty passwords"
fi

# Check UID 0 accounts (should only be root)
ROOT_UID=$(awk -F: '($3 == 0) {print $1}' /etc/passwd 2>/dev/null | grep -v root | wc -l)
if [[ $ROOT_UID -gt 0 ]]; then
  p_fail "Non-root account(s) with UID 0 found — backdoor accounts!"
  awk -F: '($3 == 0) {print $1}' /etc/passwd | grep -v root | while read u; do
    p_fail "  → $u has UID 0"
  done
else
  p_pass "Only root has UID 0"
fi

# Password expiration policy
if grep -q "PASS_MAX_DAYS" /etc/login.defs 2>/dev/null; then
  MAXDAYS=$(grep "^PASS_MAX_DAYS" /etc/login.defs | awk '{print $2}')
  if [[ $MAXDAYS -gt 90 ]]; then
    p_warn "Password max days = $MAXDAYS (recommend ≤ 90)"
    harden "sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs"
  else
    p_pass "Password max days = $MAXDAYS"
  fi
fi

section "4. File Permissions"
# Check critical file permissions
for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers; do
  if [[ -f "$f" ]]; then
    PERMS=$(stat -c "%a %U:%G" "$f" 2>/dev/null)
    PERM_NUM=$(echo "$PERMS" | awk '{print $1}')
    case "$f" in
      /etc/shadow|/etc/gshadow)
        if [[ $PERM_NUM -le 600 ]]; then p_pass "$f: $PERMS"
        else p_fail "$f: $PERMS (should be 600 or less)"; harden "chmod 600 $f"; fi ;;
      /etc/sudoers)
        if [[ $PERM_NUM -le 440 ]]; then p_pass "$f: $PERMS"
        else p_fail "$f: $PERMS (should be 440)"; harden "chmod 440 $f"; fi ;;
      *)
        if [[ $PERM_NUM -le 644 ]]; then p_pass "$f: $PERMS"
        else p_warn "$f: $PERMS (should be 644 or less)"; harden "chmod 644 $f"; fi ;;
    esac
  fi
done

section "5. System & Kernel"
# Core dumps
if grep -qE '^\s*\*\s+hard\s+core\s+0' /etc/security/limits.conf 2>/dev/null; then
  p_pass "Core dumps disabled"
else
  p_warn "Core dumps may be enabled — can leak sensitive data"
  harden "echo '* hard core 0' >> /etc/security/limits.conf"
fi

# Syn cookies
SYN=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || echo "1")
if [[ "$SYN" == "1" ]]; then p_pass "TCP SYN cookies enabled (anti-DDoS)"
else p_warn "TCP SYN cookies disabled"; harden "sysctl -w net.ipv4.tcp_syncookies=1"; fi

# IP forwarding (should be off unless router)
IPFWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
if [[ "$IPFWD" == "0" ]]; then p_pass "IP forwarding disabled (good for non-router)"
else p_warn "IP forwarding enabled (only needed for routers/containers)"; fi

# Automatic updates
if command -v unattended-upgrade &>/dev/null || dpkg -l unattended-upgrades &>/dev/null 2>&1; then
  p_pass "Unattended security updates installed"
elif command -v dnf &>/dev/null && dnf check-update --security -q 2>/dev/null; then
  p_info "dnf available — consider enabling automatic security updates"
else
  p_warn "No automatic security updates detected"
  harden "apt install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
fi

section "6. Audit & Logging"
# auditd
if command -v auditctl &>/dev/null && systemctl is-active auditd &>/dev/null; then
  p_pass "auditd is running"
elif command -v auditctl &>/dev/null; then
  p_warn "auditd installed but not running"
  harden "systemctl enable --now auditd"
else
  p_warn "auditd not installed — no audit trail"
  harden "apt install -y auditd || dnf install -y audit"
fi

# Remote logging
if grep -qE '^\s*[^#].*@@?\s' /etc/rsyslog.conf 2>/dev/null || ls /etc/rsyslog.d/*.conf 2>/dev/null | grep -qv "^#"; then
  p_pass "Remote logging configured"
else
  p_warn "No remote log forwarding — logs lost if server compromised"
fi

# Journald persistence
if grep -q "Storage=persistent" /etc/systemd/journald.conf 2>/dev/null; then
  p_pass "Journald persistent storage enabled"
else
  p_warn "Journald volatile (logs lost on reboot)"
  harden "sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf && systemctl restart systemd-journald"
fi

section "7. Running Services"
ENABLED_COUNT=$(systemctl list-unit-files --state=enabled 2>/dev/null | grep -c "\.service" || echo 0)
p_info "$ENABLED_COUNT services enabled"
RISKY=("telnet" "rsh" "rlogin" "tftp" "xinetd" "vsftpd" "vsftpd.service")
for svc in "${RISKY[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null 2>&1 || systemctl is-active "$svc" &>/dev/null 2>&1; then
    p_fail "Risky service running: $svc"
    harden "systemctl disable --now $svc"
  fi
done
p_pass "Legacy insecure services check done"

# Listening ports
LISTENING=$(ss -tlnp 2>/dev/null | grep -c "LISTEN" || echo 0)
p_info "$LISTENING ports listening"
ZERO_NET=$(ss -tlnp 2>/dev/null | grep "0.0.0.0" | grep -v "127.0.0.1" | wc -l || echo 0)
if [[ $ZERO_NET -gt 8 ]]; then
  p_warn "$ZERO_NET services listening on 0.0.0.0 — review if all are internet-facing"
else
  p_pass "$ZERO_NET services on 0.0.0.0 (reasonable)"
fi

# ---- Score ----
if [[ "$MODE" == "audit" ]]; then
  SCORE=$((100 - FAIL*15 - WARN*5)); [[ $SCORE -lt 0 ]] && SCORE=0
  if [[ $SCORE -ge 90 ]]; then GRADE="🛡 SECURE"; GC=$G
  elif [[ $SCORE -ge 70 ]]; then GRADE="🩹 NEEDS HARDENING"; GC=$Y
  else GRADE="🚨 CRITICAL — ACT NOW"; GC=$R; fi
  echo -e "\n${Bd}════ SECURITY SCORE: ${GC}${SCORE}/100 ${GRADE}${_} ════"
  echo -e "  Pass: ${G}${PASS}${_} · Warn: ${Y}${WARN}${_} · Fail: ${R}${FAIL}${_}"
  [[ -n "$MDFILE" ]] && {
    { echo "# Security Baseline Report"
      echo "**Date:** $(date '+%F %T')  |  **Score:** $SCORE/100  |  **Fail:** $FAIL  |  **Warn:** $WARN"
      for l in "${MDL[@]}"; do echo "$l"; done
    } > "$MDFILE"
    echo "Report: $MDFILE"
  }
elif [[ "$MODE" == "harden" ]]; then
  chmod +x "$HARDEN_FILE"
  echo -e "\n${Bd}${G}✅ Hardening script generated: ${HARDEN_FILE}${_}"
  echo -e "  ${Y}⚠️ Review before running! Some changes may impact your application.${_}"
  echo -e "  Run: bash $HARDEN_FILE"
fi
