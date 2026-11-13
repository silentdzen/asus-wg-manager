#!/bin/sh
# ASUS WireGuard Client Manager v2.14.4 (ASUS shell path compatibility fix)
# Manages ASUS WireGuard SERVER 1 (wgs1): GUI slots 1-10 + unlimited custom peers.
# Requires /jffs/scripts support. Run locally on router as administrator/root.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Required Notice: Copyright (c) 2026 silentdzen
# Licence URL: https://polyformproject.org/licenses/noncommercial/1.0.0/
# Router-side updater uses HTTPS curl; no Entware dependency.

umask 077
export LC_ALL=C
# Firmware startup hooks may run with a minimal PATH. Include known ASUS and
# optional Entware executable directories without requiring shell `command`.
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin${PATH:+:$PATH}
export PATH
# Bump this version for every published release. GitHub Actions reads it.
WG_MANAGER_VERSION=2.14.4
# Project owner for release discovery (adjust only if repository owner differs).
UPDATE_REPO=silentdzen/asus-wg-manager
IFACE=wgs1
BASE=/jffs/wg-manager
LEGACY_BASE=/jffs/wg-extra-manager
SELF=/jffs/scripts/wg-manager.sh
PEERS=$BASE/peers
CLIENTS=$BASE/clients
META=$BASE/meta
POLICY=$BASE/policies
BACKUPS=$BASE/backups
EXPORTS=$BASE/exports
ARCHIVES=$BACKUPS/archives
HISTORY=$BASE/history
HISTORY_STATE=$HISTORY/state.tsv
HISTORY_CLEARED=$HISTORY/cleared-at
HISTORY_LOCK=/tmp/wg-manager-history.lock
HISTORY_SUSPEND=/tmp/wg-manager-history-suspend
HISTORY_CRON=WGManagerHistory
TAG=ASUS-WG-MANAGER-V2

# Some ASUS /bin/sh builds do not implement the POSIX `command -v` builtin.
# Find executable files in PATH using shell parameter expansion and test only.
# No dependency on `command`, `type`, `which`, or `id`.
has_bin() {
  case "$1" in
    */*) [ -f "$1" ] && [ -x "$1" ]; return $? ;;
  esac
  _wgxm_path=${PATH}:
  while [ -n "$_wgxm_path" ]; do
    _wgxm_dir=${_wgxm_path%%:*}
    _wgxm_path=${_wgxm_path#*:}
    [ -n "$_wgxm_dir" ] || _wgxm_dir=.
    if [ -f "$_wgxm_dir/$1" ] && [ -x "$_wgxm_dir/$1" ]; then
      return 0
    fi
  done
  return 1
}

# Create a private temporary directory without mktemp (absent on some ASUS
# firmware builds). mkdir itself provides atomic, no-clobber creation; each
# directory is mode 700 because of the global umask 077. Never reuse paths.
make_temp_dir() {
  _wgm_prefix=$1
  case "$_wgm_prefix" in
    ''|*[!a-zA-Z0-9_-]*) return 1 ;;
  esac
  _wgm_n=0
  while [ "$_wgm_n" -lt 100 ]; do
    _wgm_dir="/tmp/${_wgm_prefix}.$$.$_wgm_n"
    if (umask 077; mkdir "$_wgm_dir" 2>/dev/null); then
      printf '%s\n' "$_wgm_dir"
      return 0
    fi
    _wgm_n=$((_wgm_n + 1))
  done
  return 1
}

# UI colours only for an interactive, ANSI-capable terminal. Never pollute
# output from router hooks, cron or redirected/noninteractive sessions.
ui_init() {
  UI_RESET='' UI_CYAN='' UI_GREEN='' UI_YELLOW='' UI_RED='' UI_GREY=''
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    UI_RESET=$(printf '\033[0m')
    UI_CYAN=$(printf '\033[36m')
    UI_GREEN=$(printf '\033[32m')
    UI_YELLOW=$(printf '\033[33m')
    UI_RED=$(printf '\033[31m')
    UI_GREY=$(printf '\033[90m')
  fi
}
say() { printf '%s\n' "$*"; }
err() {
  if [ -t 2 ]; then
    printf '%sERROR:%s %s\n' "${UI_RED:-}" "${UI_RESET:-}" "$*" >&2
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
}
success() { printf '%s%s%s\n' "${UI_GREEN:-}" "$*" "${UI_RESET:-}"; }
warning() { printf '%s%s%s\n' "${UI_YELLOW:-}" "$*" "${UI_RESET:-}"; }
ui_heading() { printf '\n%s%s%s\n' "${UI_CYAN:-}" "$*" "${UI_RESET:-}"; }
# 76-character rule: long enough to separate clients, safe at 80 columns.
ui_menu_rule() {
  printf '%s%s%s\n' "${UI_GREY:-}" \
    '------------------------------------------------------------' "${UI_RESET:-}"
}
ui_rule() {
  printf '%s%s%s\n' "${UI_GREY:-}" \
    '----------------------------------------------------------------------------' "${UI_RESET:-}"
}
ui_menu_item() { printf '%s%s)%s %s\n' "${UI_CYAN:-}" "$1" "${UI_RESET:-}" "$2"; }
pause() { printf '\nPress Enter to return to the main menu: '; IFS= read -r _discard || :; }
clear_screen() { if [ -t 1 ]; then printf '\033[2J\033[H'; fi; }
is_back() { case "$1" in m|M|b|B|back|BACK) return 0;; *) return 1;; esac; }
ask() { printf '%s%s%s' "${UI_CYAN:-}" "$1" "${UI_RESET:-}"; IFS= read -r ANSWER || exit 0; }
yes() { case "$1" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
readfield() { sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'; }
confval() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | sed -n '1p'; }
valid_name() { case "$1" in ''|.*|*..*|*[!a-zA-Z0-9._-]*) return 1;; *) [ ${#1} -le 40 ];; esac; }
valid_ipv4() { awk -v s="$1" 'BEGIN{n=split(s,a,/[.]/);if(n!=4)exit 1;for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/||length(a[i])>3||a[i]+0>255||(length(a[i])>1&&substr(a[i],1,1)=="0"))exit 1;exit 0}'; }
# Replaces first IPv4 address token in ASUS NVRAM address/AllowedIPs lists,
# retaining any IPv6 entries. Refuses unsupported /not-host IPv4 prefixes.
replace_v4_host() {
  awk -v old="$1" -v ip="$2" 'BEGIN{
    n=split(old,a,/[ ,\t]+/);found=0;out="";
    for(i=1;i<=n;i++){
      if(a[i]=="")continue;
      if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/32)?$/){
        if(found)exit 2; found=1; a[i]=ip "/32";
      } else if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/)exit 3;
      out=out (out==""?"":" ") a[i];
    }
    if(!found)exit 1;print out;
  }'
}
server_subnet() { ip -4 addr show dev "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1);exit}}'; }
# ASUS/Merlin commonly assigns each tunnel interface a /32 host route, even
# when its GUI clients occupy the neighbouring /24. A /32 is NOT a usable
# client-address pool. For /32 we SUGGEST the containing /24 as a conservative
# pool, derived from this router's actual server IP (never hard-coded).
# A router with a configured /1.. /31 mask keeps its actual interface range.
client_pool() {
  case "$SERVER_SUBNET" in
    */32) printf '%s.0/24\n' "${SERVER_IP%.*}" ;;
    *) printf '%s\n' "$SERVER_SUBNET" ;;
  esac
}
subnet_usable() {
  awk -v target="$1" -v cidr="$2" 'BEGIN{
    n=split(cidr,b,"/"); if(n!=2||b[2]!~/^[0-9]+$/)exit 1;
    p=b[2]+0;if(p<1||p>31)exit 1;
    if(split(target,a,/[.]/)!=4||split(b[1],s,/[.]/)!=4)exit 1;
    for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/||s[i]!~/^[0-9]+$/||a[i]+0>255||s[i]+0>255)exit 1;
    x=((a[1]*256+a[2])*256+a[3])*256+a[4];
    y=((s[1]*256+s[2])*256+s[3])*256+s[4];
    z=2^(32-p);nw=int(y/z)*z;
    if(int(x/z)!=int(y/z)||x==y)exit 1;
    if(p<=30&&(x==nw||x==nw+z-1))exit 1;
  }'
}
# Reject addresses falling inside live peer AllowedIPs (including overlapping prefixes).
live_ip_used() {
  wg show "$IFACE" allowed-ips 2>/dev/null | awk -v ip="$1" '
    function num(s, a,n,i){n=split(s,a,/[.]/);if(n!=4)return -1;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]+0>255)return -1;return ((a[1]*256+a[2])*256+a[3])*256+a[4]}
    BEGIN{v=num(ip);hit=0}
    {for(i=2;i<=NF;i++){n=split($i,l,",");for(j=1;j<=n;j++){
      m=split(l[j],c,"/");x=num(c[1]);if(x<0)continue;
      p=(m==2?c[2]+0:32);if(p<0||p>32)continue;
      z=2^(32-p);if(int(v/z)==int(x/z))hit=1;
    }}}
    END{exit(hit?0:1)}'
}
used_ip() {
  ipaddr=$1
  [ "$ipaddr" = "${SERVER_IP:-}" ] && return 0
  i=1
  while [ "$i" -le 10 ]; do
    val=$(nvram get "wgs1_c${i}_addr")
    if printf '%s\n' "$val" | awk -v ip="$ipaddr" 'BEGIN{hit=0}{n=split($0,a,/[ ,\t]+/);for(i=1;i<=n;i++)if(a[i]==ip||a[i]==ip "/32")hit=1}END{exit(hit?0:1)}'; then return 0; fi
    i=$((i+1))
  done
  for file in "$META"/*.meta; do
    [ -f "$file" ] || continue
    [ "$(readfield "$file" IP)" = "$ipaddr" ] && return 0
  done
  live_ip_used "$ipaddr" && return 0
  return 1
}
# Suggest the first free IPv4 host, scanning numerically from immediately
# after the server address and wrapping around the client pool if needed.
# Check all ASUS GUI peers, script-managed peers, and live WireGuard AllowedIPs
# through used_ip(); this prevents hints that overlap a current assignment.
# A /32 server interface uses the inferred /24 client pool as before.
# The scan is bounded to avoid excessive work on extremely large subnets.
suggest_next_ip() {
  awk -v server="$SERVER_IP" -v cidr="$CLIENT_POOL" 'BEGIN {
    if (split(cidr,p,"/")!=2 || p[2]!~/^[0-9]+$/) exit 1;
    bits=p[2]+0; if(bits<1 || bits>31) exit 1;
    if (split(p[1],a,".")!=4 || split(server,b,".")!=4) exit 1;
    base=0; srv=0;
    for(i=1;i<=4;i++) {
      if(a[i]!~/^[0-9]+$/ || b[i]!~/^[0-9]+$/ || a[i]>255 || b[i]>255) exit 1;
      base=base*256+a[i]; srv=srv*256+b[i];
    }
    size=2^(32-bits); low=int(base/size)*size;
    high=low+size-1;
    if(bits<=30) {low++; high--}
    start=(srv>=low && srv<=high) ? srv+1 : low;
    if(start>high) start=low;
    # Try up to 65536 candidates, bounded even for huge address pools.
    total=high-low+1; if(total>65536) total=65536;
    for(i=0;i<total;i++) {
      n=start+i;
      if(n>high) n=low+(n-high-1);
      if(n==srv) continue;
      a1=int(n/16777216); rem=n-a1*16777216;
      a2=int(rem/65536); rem-=a2*65536;
      a3=int(rem/256); a4=rem-a3*256;
      printf "%d.%d.%d.%d\n",a1,a2,a3,a4;
    }
  }' | while IFS= read -r candidate; do
    if ! used_ip "$candidate"; then
      printf '%s\n' "$candidate"
      break
    fi
  done
}
choose_ip() {
  if [ "${SERVER_SUBNET##*/}" = 32 ]; then
    say "Note: $SERVER_SUBNET is the server's host address, not a client subnet."
    say "Suggested client pool: $CLIENT_POOL (inferred /24; check existing peer IPs)."
  fi
  # Only suggest an address while ADDING a client. Modifying an existing
  # peer should not silently change its address when Enter is pressed.
  SUGGESTED_IP=''
  if [ -z "${OLDIP:-}" ]; then
    SUGGESTED_IP=$(suggest_next_ip)
    if [ -n "$SUGGESTED_IP" ]; then
      say "First available VPN IPv4 address: $SUGGESTED_IP"
    else
      say 'No automatically available address found; enter an unused address manually.'
    fi
  fi
  while :; do
    if [ -n "$SUGGESTED_IP" ]; then
      ask "WireGuard VPN IPv4 address [Enter = $SUGGESTED_IP, m = menu]: "
    else
      ask "WireGuard VPN IPv4 address [$CLIENT_POOL, m = menu]: "
    fi
    NEWIP=$ANSWER
    is_back "$NEWIP" && return 2
    [ -n "$NEWIP" ] || NEWIP=$SUGGESTED_IP
    # Accept a host address entered in either plain or CIDR /32 notation.
    case "$NEWIP" in */32) NEWIP=${NEWIP%/32} ;; esac
    if ! valid_ipv4 "$NEWIP" || ! subnet_usable "$NEWIP" "$CLIENT_POOL"; then
      err "Enter a usable IPv4 host in $CLIENT_POOL (e.g. ${SERVER_IP%.*}.8); /32 suffix optional."
      continue
    fi
    if [ "$NEWIP" != "${OLDIP:-}" ] && used_ip "$NEWIP"; then err "IP $NEWIP is already allocated or overlaps another peer."; continue; fi
    return 0
  done
}
choose_policy() {
  say 'LAN access: 1) Allow access (subject to ASUS global server setting)'
  say '            2) Restrict: block router LAN IPv4 and LAN subnet; keep router DNS (TCP/UDP 53)'
  default=1
  [ "${1:-}" != deny ] || default=2
  ask "Select LAN access policy [1/2, Enter = $default, m = menu]: "
  [ -n "$ANSWER" ] || ANSWER=$default
  case "$ANSWER" in 1) NEWPOL=allow;; 2) NEWPOL=deny;; m|M|b|B) return 2;; *) err 'Invalid selection.'; return 1;; esac
  return 0
}
# The router's current WireGuard-client endpoint follows ASUS's generated config.
endpoint() {
  i=1
  while [ "$i" -le 10 ]; do
    file="/etc/wg/server1_client${i}.conf"
    if [ -f "$file" ]; then
      val=$(confval "$file" Endpoint)
      [ -z "$val" ] || { printf '%s\n' "$val"; return; }
    fi
    i=$((i+1))
  done
  host=''
  [ "$(nvram get ddns_enable_x)" = 1 ] && [ "$(nvram get ddns_status)" = 1 ] && host=$(nvram get ddns_hostname_x)
  [ -n "$host" ] || host=$(nvram get wan0_ipaddr)
  case "$host" in ''|0.0.0.0) host=$(nvram get lan_ipaddr);; esac
  case "$host" in *:*) host="[$host]";; esac
  printf '%s:%s\n' "$host" "$(wg show "$IFACE" listen-port)"
}
client_allowed() {
  i=1
  while [ "$i" -le 10 ]; do
    if [ "$(nvram get "wgs1_c${i}_enable")" = 1 ]; then
      val=$(nvram get "wgs1_c${i}_caips")
      if [ -n "$val" ]; then
        # IPv4 destinations only: custom peers are provisioned IPv4-only.
        val=$(printf '%s\n' "$val" | tr ', ' '\n\n' | awk '/^[0-9.]+\/[0-9]+$/ {o=o (o?", ":"") $0}END{print o}')
        [ -n "$val" ] && { printf '%s\n' "$val"; return; }
      fi
    fi
    i=$((i+1))
  done
  printf '0.0.0.0/0\n'
}
write_extra() {
  # Arguments: name ipv4 policy private public psk endpoint allowedIPs
  name=$1 ipaddr=$2 pol=$3 priv=$4 pub=$5 psk=$6 ep=$7 allowed=$8
  peer="$PEERS/$name.peer"; conf="$CLIENTS/$name.conf"; meta="$META/$name.meta"
  {
    printf '# Managed client: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ipaddr"
    [ -z "$psk" ] || printf 'PresharedKey = %s\n' "$psk"
  } > "$peer" || return 1
  {
    printf '# WireGuard client: %s\n[Interface]\nPrivateKey = %s\nAddress = %s/32\n' "$name" "$priv" "$ipaddr"
    if [ "$(nvram get wgs1_dns)" = 1 ]; then
      printf 'DNS = %s\n' "$SERVER_IP"
    fi
    printf '\n[Peer]\nPublicKey = %s\n' "$(wg show "$IFACE" public-key)"
    [ -z "$psk" ] || printf 'PresharedKey = %s\n' "$psk"
    printf 'AllowedIPs = %s\nEndpoint = %s\n' "$allowed" "$ep"
    keepalive=$(nvram get wgs1_alive)
    case "$keepalive" in ''|*[!0-9]*) keepalive=25;; esac
    [ "$keepalive" = 0 ] || printf 'PersistentKeepalive = %s\n' "$keepalive"
  } > "$conf" || return 1
  printf 'IP=%s\nPUB=%s\nPOLICY=%s\n' "$ipaddr" "$pub" "$pol" > "$meta" || return 1
  chmod 600 "$peer" "$conf" "$meta"
}
install_hook() {
  hook=$1; body=$2
  if [ -e "$hook" ] && [ ! -f "$hook" ]; then err "Not a regular file: $hook"; return 1; fi
  if [ -f "$hook" ] && grep -Fq "# BEGIN $TAG" "$hook"; then return 0; fi
  if [ -f "$hook" ]; then
    cp -p "$hook" "$BACKUPS/$(basename "$hook").$(date +%Y%m%d-%H%M%S).$$" || return 1
  else
    printf '#!/bin/sh\n' > "$hook" || return 1
  fi
  { printf '\n# BEGIN %s\n' "$TAG"; printf '%s\n' "$body"; printf '# END %s\n' "$TAG"; } >> "$hook" || return 1
  chmod 755 "$hook"
}
# Upgrade only the DNS setting that v2.3 itself inserted, identified by
# its exact marker comment. Keep any user-edited DNS settings untouched.
migrate_legacy_dns() {
  for conf in "$CLIENTS"/*.conf; do
    [ -f "$conf" ] || continue
    grep -Fq '# Router DNS is blocked when LAN access is restricted.' "$conf" || continue
    # Never modify configurations without preserving an owner-only backup.
    cp -p "$conf" "$BACKUPS/$(basename "$conf").dns-v23.$(date +%Y%m%d-%H%M%S).$$" || return 1
    tmp="$conf.tmp.$$"
    awk -v server="$SERVER_IP" -v enabled="$(nvram get wgs1_dns)" '
      /^# Router DNS is blocked when LAN access is restricted\.$/ {next}
      /^DNS = 1\.1\.1\.1$/ {
        if(enabled==1)print "DNS = " server;
        next
      }
      {print}
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv "$tmp" "$conf" || return 1
  done
}
# On an upgrade from v2.4 the Merlin hooks still call the old script name.
# Update ONLY manager-owned lines between the existing tag markers and leave
# any user's independent hook commands unchanged. Back up before each edit.
upgrade_hook_path() {
  hook=$1
  old=/jffs/scripts/asus-wg-manager.sh
  [ -f "$hook" ] || return 0
  grep -Fq "$old" "$hook" || return 0
  grep -Fq "# BEGIN $TAG" "$hook" || return 0
  tmp="$hook.wgxm.$$"
  awk -v start="# BEGIN $TAG" -v finish="# END $TAG" -v old="$old" -v new="$SELF" '
    $0 == start { inside=1 }
    {
      if (inside) {
        while ((pos=index($0,old))>0)
          $0=substr($0,1,pos-1) new substr($0,pos+length(old))
      }
      print
    }
    $0 == finish { inside=0 }
  ' "$hook" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Don't touch custom hook content if the old path wasn't in our tag.
  if cmp -s "$hook" "$tmp"; then rm -f "$tmp"; return 0; fi
  cp -p "$hook" "$BACKUPS/$(basename "$hook").pre-v25.$(date +%Y%m%d-%H%M%S).$$" || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp" && mv "$tmp" "$hook" || { rm -f "$tmp"; return 1; }
}
install_all() {
  mkdir -p /jffs/scripts "$PEERS" "$CLIENTS" "$META" "$POLICY" "$BACKUPS" "$EXPORTS" || return 1
  chmod 700 "$BASE" "$PEERS" "$CLIENTS" "$META" "$POLICY" "$BACKUPS" "$EXPORTS"
  if [ ! -f "$SELF" ] || ! cmp -s "$0" "$SELF"; then
    case "$0" in "$SELF") :;; *) cp "$0" "$SELF" || return 1;; esac
  fi
  chmod 700 "$SELF"
  # Older single-purpose script should not be used alongside this one.
  for hook in /jffs/scripts/wgserver.postconf /jffs/scripts/wgserver-start; do
    if [ -f "$hook" ] && grep -Fq '# BEGIN WG-EXTRA-MANAGER-' "$hook"; then
      err "An older peer-manager hook is present in $hook. Remove/disable its tagged block before using v2."
      return 1
    fi
  done
  install_hook /jffs/scripts/wgserver.postconf '[ "${1:-}" = "/etc/wg/server1.conf" ] && /jffs/scripts/wg-manager.sh --postconf "$1"' || return 1
  install_hook /jffs/scripts/wgserver-start '[ "${1:-}" = 1 ] && /jffs/scripts/wg-manager.sh --server-start' || return 1
  install_hook /jffs/scripts/wgserver-stop '[ "${1:-}" = 1 ] && /jffs/scripts/wg-manager.sh --server-stop' || return 1
  install_hook /jffs/scripts/firewall-start '/jffs/scripts/wg-manager.sh --firewall' || return 1
  # Register the cron job after all router services have started on reboot.
  install_hook /jffs/scripts/services-start '/jffs/scripts/wg-manager.sh --install-status-cron' || return 1
  # v2.4 hooks already contain the manager tag and are not reinserted above.
  # Retarget those exact tagged lines to this new executable.
  for hook in /jffs/scripts/wgserver.postconf /jffs/scripts/wgserver-start /jffs/scripts/wgserver-stop /jffs/scripts/firewall-start /jffs/scripts/services-start; do
    upgrade_hook_path "$hook" || return 1
  done
  migrate_legacy_dns || { err 'Failed migrating an old restricted-client DNS config; inspect backups.'; return 1; }
}
# Skip hardware acceleration for peer addresses on supporting Broadcom devices.
blog_network() {
  mode=$1 cidr=$2
  if [ -w /proc/blog/skip_wireguard_network ]; then
    printf '%s %s\n' "$mode" "$cidr" > /proc/blog/skip_wireguard_network 2>/dev/null || :
  fi
}
route_all() {
  for file in "$META"/*.meta; do
    [ -f "$file" ] || continue
    ipaddr=$(readfield "$file" IP)
    valid_ipv4 "$ipaddr" || continue
    ip -4 route replace "$ipaddr/32" dev "$IFACE" || :
    blog_network add "$ipaddr/32"
  done
}
route_clear() {
  for file in "$META"/*.meta; do
    [ -f "$file" ] || continue
    ipaddr=$(readfield "$file" IP)
    valid_ipv4 "$ipaddr" || continue
    blog_network del "$ipaddr/32"
  done
}
# Firewall policy deliberately mirrors the user's narrower IPv4 restriction:
# block access to the router LAN IPv4, except router DNS on TCP/UDP 53;
# block access to the router's LAN subnet through WGSF/FORWARD.
# Do not blanket-block RFC1918, guest VLANs, IPv6, or other router addresses.
# The IPv4-only policy cannot guarantee isolation if clients have IPv6 routes.
lan_network() {
  _lanip=$(nvram get lan_ipaddr)
  _lanmask=$(nvram get lan_netmask)
  valid_ipv4 "$_lanip" && valid_ipv4 "$_lanmask" || return 1
  awk -v ip="$_lanip" -v mask="$_lanmask" 'BEGIN {
    split(ip,a,"."); split(mask,m,"."); bits=0; zero=0; network="";
    for(i=1;i<=4;i++) {
      for(k=7;k>=0;k--) {
        bit=int(m[i]/(2^k))%2;
        if(bit && zero)exit 1;
        if(bit)bits++;else zero=1;
      }
      net=int(a[i]/(256-m[i]))*(256-m[i]);
      network=network (i==1?"":".") net;
    }
    if(bits<1 || bits>32)exit 1;
    print network "/" bits;
  }'
}
load_lan() {
  LAN_IP=$(nvram get lan_ipaddr)
  LAN_NET=$(lan_network) || { err 'Cannot determine LAN subnet from lan_ipaddr/lan_netmask; refusing unsafe firewall rules.'; return 1; }
  [ -n "$LAN_IP" ] && [ -n "$LAN_NET" ] || return 1
}
ensure_chain() {
  tool=$1 chain=$2
  "$tool" -nL "$chain" >/dev/null 2>&1 || "$tool" -N "$chain" || return 1
}
ensure_jump() {
  tool=$1 chain=$2 custom=$3
  "$tool" -nL "$chain" >/dev/null 2>&1 || return 0
  "$tool" -C "$chain" -i "$IFACE" -j "$custom" >/dev/null 2>&1 || "$tool" -I "$chain" 1 -i "$IFACE" -j "$custom" || return 1
}
v4_token_gui() {
  nvram get "wgs1_c${1}_addr" | awk '{n=split($0,a,/[ ,\t]+/);for(i=1;i<=n;i++)if(a[i]~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/32)?$/){split(a[i],p,"/");print p[1];exit}}'
}
v4_safe_gui() {
  assigned=$(v4_token_gui "$1")
  [ -n "$assigned" ] || return 1
  nvram get "wgs1_c${1}_aips" | awk -v ip="$assigned" '
    BEGIN{ok=0;bad=0}
    {n=split($0,a,/[ ,\t]+/);for(j=1;j<=n;j++) {
       if(a[j] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) {
         if(a[j]==ip "/32")ok++;else bad++;
       }
    }}
    END {exit(ok==1&&bad==0?0:1)}'
}
# v2.3 created blanket-block IPv6 chains. Remove ONLY our previous custom
# jumps/chains so an upgrade to v2.4 does not retain those broader rules.
remove_old_ipv6_policy() {
  has_bin ip6tables || return 0
  for pair in 'INPUT WGXM6_IN' 'FORWARD WGXM6_FW' 'WGSF WGXM6_FW'; do
    set -- $pair
    if ip6tables -nL "$1" >/dev/null 2>&1; then
      while ip6tables -C "$1" -i "$IFACE" -j "$2" >/dev/null 2>&1; do
        ip6tables -D "$1" -i "$IFACE" -j "$2" || break
      done
    fi
  done
  for chain in WGXM6_IN WGXM6_FW; do
    if ip6tables -nL "$chain" >/dev/null 2>&1; then
      ip6tables -F "$chain" || :
      ip6tables -X "$chain" 2>/dev/null || :
    fi
  done
}
firewall_apply() {
  has_bin iptables || { err 'iptables missing'; return 1; }
  load_lan || return 1
  # First validate all GUI peers requiring per-user restrictions.
  i=1
  while [ "$i" -le 10 ]; do
    if [ -f "$POLICY/gui-$i" ] && [ "$(cat "$POLICY/gui-$i")" = deny ] && [ "$(nvram get "wgs1_c${i}_enable")" = 1 ]; then
      v4_safe_gui "$i" || { err "GUI peer $i needs exactly one /32 IPv4 AllowedIPs entry."; return 1; }
    fi
    i=$((i+1))
  done
  ensure_chain iptables WGXM_IN || return 1
  ensure_chain iptables WGXM_FW || return 1
  ensure_jump iptables INPUT WGXM_IN || return 1
  ensure_jump iptables FORWARD WGXM_FW || return 1
  ensure_jump iptables WGSF WGXM_FW || return 1
  iptables -F WGXM_IN || return 1
  iptables -F WGXM_FW || return 1
  for file in "$META"/*.meta; do
    [ -f "$file" ] || continue
    [ "$(readfield "$file" POLICY)" = deny ] || continue
    ipaddr=$(readfield "$file" IP)
    valid_ipv4 "$ipaddr" || continue
    v4_deny_rules "$ipaddr" || return 1
  done
  i=1
  while [ "$i" -le 10 ]; do
    if [ -f "$POLICY/gui-$i" ] && [ "$(cat "$POLICY/gui-$i")" = deny ] && [ "$(nvram get "wgs1_c${i}_enable")" = 1 ]; then
      ipaddr=$(v4_token_gui "$i")
      [ -z "$ipaddr" ] || v4_deny_rules "$ipaddr" || return 1
    fi
    i=$((i+1))
  done
  remove_old_ipv6_policy
}
v4_deny_rules() {
  src=$1
  # Order is essential: permit the router's DNS before the router-IP DROP.
  iptables -A WGXM_IN -s "$src/32" -d "$LAN_IP/32" -p udp --dport 53 -j ACCEPT || return 1
  iptables -A WGXM_IN -s "$src/32" -d "$LAN_IP/32" -p tcp --dport 53 -j ACCEPT || return 1
  iptables -A WGXM_IN -s "$src/32" -d "$LAN_IP/32" -j DROP || return 1
  iptables -A WGXM_FW -s "$src/32" -d "$LAN_NET" -j DROP || return 1
}
peer_live_add() {
  name=$1 ipaddr=$2
  pub=$(confval "$PEERS/$name.peer" PublicKey)
  psk=$(confval "$PEERS/$name.peer" PresharedKey)
  if [ -n "$psk" ]; then
    tf_dir=$(make_temp_dir wgxmpsk) || return 1
    tf="$tf_dir/psk"
    if ! printf '%s\n' "$psk" > "$tf"; then
      rm -rf "$tf_dir"; return 1
    fi
    wg set "$IFACE" peer "$pub" preshared-key "$tf" allowed-ips "$ipaddr/32"
    rc=$?; rm -rf "$tf_dir"; [ "$rc" -eq 0 ] || return 1
  else
    wg set "$IFACE" peer "$pub" allowed-ips "$ipaddr/32" || return 1
  fi
  if ! ip -4 route replace "$ipaddr/32" dev "$IFACE"; then
    wg set "$IFACE" peer "$pub" remove >/dev/null 2>&1 || :
    return 1
  fi
  blog_network add "$ipaddr/32"
}
peer_live_remove() {
  pub=$1 ipaddr=$2
  if [ -n "$pub" ]; then
    wg set "$IFACE" peer "$pub" remove || { err "Failed to revoke live peer $pub"; return 1; }
  fi
  if [ -n "$ipaddr" ]; then
    ip -4 route del "$ipaddr/32" dev "$IFACE" 2>/dev/null || :
    blog_network del "$ipaddr/32"
  fi
}
# Migrate the complete directory, preserving peer keys, client configurations,
# firewall policy files and previous hook backups. Both paths are on /jffs,
# so the rename is atomic under normal conditions. Never merge directories:
# an existing new directory might contain different key material.
migrate_data_directory() {
  [ -e "$LEGACY_BASE" ] || [ -L "$LEGACY_BASE" ] || return 0
  if [ ! -d "$LEGACY_BASE" ] || [ -L "$LEGACY_BASE" ]; then
    err "Old data path is not a normal directory: $LEGACY_BASE"
    return 1
  fi
  if [ -e "$BASE" ] || [ -L "$BASE" ]; then
    err "Both $LEGACY_BASE and $BASE exist."
    err 'Migration stopped to prevent overwriting client keys or policies.'
    err 'Back up and reconcile both directories manually before running again.'
    return 1
  fi
  mv "$LEGACY_BASE" "$BASE" || {
    err "Could not move $LEGACY_BASE to $BASE; old data has not been intentionally deleted."
    return 1
  }
  chmod 700 "$BASE" || return 1
  say "Migrated WireGuard manager data: $LEGACY_BASE -> $BASE"
}

# Do this for hook invocations as well as the interactive menu. Otherwise an
# unattended router reboot immediately after copying the new script could fail
# to restore the extra peers because their data was still in the old directory.
migrate_data_directory || exit 1

# Persist WireGuard history by PUBLIC KEY, not client name, display ID or VPN IP.
# Format (pipe-delimited, root-only):
# pubkey|last_successful_handshake|last_endpoint|total_client_RX|total_client_TX|
# last_live_client_RX|last_live_client_TX|last_router_boot_id
# Retained totals begin at first collection after upgrading to this version.
# A cron snapshot runs every five minutes; stop and manual status also save.
# This avoids writing to JFFS on every packet, but unexpected power failures
# may lose up to five minutes of new activity.
install_status_cron() {
  if ! has_bin cru; then
    err 'ASUS cru utility missing: automatic 5-minute history snapshots unavailable.'
    return 1
  fi
  if cru l 2>/dev/null | grep -Fq "$HISTORY_CRON"; then return 0; fi
  cru a "$HISTORY_CRON" '*/5 * * * * /jffs/scripts/wg-manager.sh --save-status >/dev/null 2>&1'
}

# All state writes/clear operations use the same atomic in-RAM lock.
# Run in a subshell so we can always release the lock on normal signals.
history_save() (
  [ ! -e "$HISTORY_SUSPEND" ] || return 0
  (umask 077; mkdir "$HISTORY_LOCK" 2>/dev/null) || return 1
  trap 'rm -rf "$HISTORY_LOCK"' 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  mkdir -p "$HISTORY" || return 1
  chmod 700 "$HISTORY" || return 1
  h_tmp=$(make_temp_dir wgm-history) || return 1
  trap 'rm -rf "$h_tmp" "$HISTORY_LOCK"' 0
  : > "$h_tmp/old"
  if [ -f "$HISTORY_STATE" ]; then
    cp "$HISTORY_STATE" "$h_tmp/old" || return 1
  fi
  wg show "$IFACE" latest-handshakes > "$h_tmp/hs" || return 1
  wg show "$IFACE" endpoints > "$h_tmp/ep" || return 1
  wg show "$IFACE" transfer > "$h_tmp/tr" || return 1
  h_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$h_boot" ] || h_boot=unknown
  h_cutoff=0
  if [ -f "$HISTORY_CLEARED" ]; then h_cutoff=$(cat "$HISTORY_CLEARED"); fi
  case "$h_cutoff" in ''|*[!0-9]*) h_cutoff=0;; esac
  awk -F '|' -v boot="$h_boot" -v cleared="$h_cutoff" '
    function numeric(x) { return x ~ /^[0-9]+$/ ? x+0 : 0 }
    FILENAME==ARGV[1] {
      if (NF<8 || $1=="") next
      k=$1; keys[k]=1; ts[k]=numeric($2); ep[k]=$3;
      totalr[k]=numeric($4); totals[k]=numeric($5)
      previousr[k]=numeric($6); previouss[k]=numeric($7); bootid[k]=$8
      next
    }
    FILENAME==ARGV[2] {
      split($0,a,/[ \t]+/); if (a[1]!="") { keys[a[1]]=1; hs[a[1]]=numeric(a[2]); } next
    }
    FILENAME==ARGV[3] {
      split($0,a,/[ \t]+/); if (a[1]!="") { keys[a[1]]=1; endpoint[a[1]]=a[2]; } next
    }
    FILENAME==ARGV[4] {
      split($0,a,/[ \t]+/)
      if (a[1]!="") { keys[a[1]]=1; live_s[a[1]]=numeric(a[2]); live_r[a[1]]=numeric(a[3]); observed[a[1]]=1 }
      next
    }
    END {
      for (k in keys) {
        last=ts[k]+0
        if (hs[k]>last && hs[k]>cleared) last=hs[k]
        if (last<=cleared) last=0
        remote=ep[k]
        if (remote=="") remote="(none)"
        if (last>0 && endpoint[k]!="" && endpoint[k]!="(none)") remote=endpoint[k]
        tr=totalr[k]+0; tt=totals[k]+0
        pr=previousr[k]+0; ps=previouss[k]+0; bid=bootid[k]
        if (observed[k]) {
          cr=live_r[k]+0; cs=live_s[k]+0
          if (bid!=boot || cr<pr) tr+=cr
          else tr+=cr-pr
          if (bid!=boot || cs<ps) tt+=cs
          else tt+=cs-ps
          pr=cr; ps=cs; bid=boot
        }
        printf "%s|%.0f|%s|%.0f|%.0f|%.0f|%.0f|%s\n", k,last,remote,tr,tt,pr,ps,bid
      }
    }
  ' "$h_tmp/old" "$h_tmp/hs" "$h_tmp/ep" "$h_tmp/tr" > "$h_tmp/new" || return 1
  chmod 600 "$h_tmp/new" || return 1
  # Sort by stable public key to avoid rewriting flash when only AWK's array
  # iteration order changes. Avoid ANY flash write when state is unchanged.
  sort "$h_tmp/new" > "$h_tmp/sorted" || return 1
  if [ -f "$HISTORY_STATE" ] && cmp -s "$HISTORY_STATE" "$h_tmp/sorted"; then return 0; fi
  chmod 600 "$h_tmp/sorted" || return 1
  mv "$h_tmp/sorted" "$HISTORY_STATE" || return 1
)

# Clearing affects MANAGER-SAVED HISTORY ONLY, never kernel WireGuard peer
# handshakes, kernel transfer counters or actual VPN connections. The cutoff
# prevents already-existing handshakes from reappearing after a reboot.
history_clear() (
  (umask 077; mkdir "$HISTORY_LOCK" 2>/dev/null) || { err 'History is busy; try again.'; return 1; }
  trap 'rm -rf "$HISTORY_LOCK"' 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  mkdir -p "$HISTORY" || return 1
  chmod 700 "$HISTORY" || return 1
  c_tmp=$(make_temp_dir wgm-clear) || return 1
  trap 'rm -rf "$c_tmp" "$HISTORY_LOCK"' 0
  c_time=$(date +%s) || return 1
  case "$c_time" in ''|*[!0-9]*) err 'Cannot clear history: invalid router clock.'; return 1;; esac
  c_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$c_boot" ] || c_boot=unknown
  : > "$c_tmp/hs"; : > "$c_tmp/ep"; : > "$c_tmp/tr"
  # Record a baseline of currently live kernel counters, so previously
  # transferred bytes do not immediately return as accumulated history.
  wg show "$IFACE" transfer > "$c_tmp/tr" || return 1
  awk -v boot="$c_boot" '{
    if ($1!="" && $2~/^[0-9]+$/ && $3~/^[0-9]+$/)
      printf "%s|0|(none)|0|0|%.0f|%.0f|%s\n",$1,$3,$2,boot
  }' "$c_tmp/tr" | sort > "$c_tmp/new" || return 1
  printf '%s\n' "$c_time" > "$c_tmp/cleared" || return 1
  chmod 600 "$c_tmp/new" "$c_tmp/cleared" || return 1
  mv "$c_tmp/new" "$HISTORY_STATE" || return 1
  mv "$c_tmp/cleared" "$HISTORY_CLEARED" || return 1
)

# ---------------------------------------------------------------------------
# System hook entry points (no menu, no prompts)
# ---------------------------------------------------------------------------
case "${1:-}" in
  --postconf)
    [ "${2:-}" = /etc/wg/server1.conf ] || exit 0
    for file in "$PEERS"/*.peer; do [ -f "$file" ] && { printf '\n'; cat "$file"; } >> "$2"; done
    exit 0;;
  --server-start)
    route_all; wgm_rc=$?
    firewall_apply || wgm_rc=1
    install_status_cron || :
    exit "$wgm_rc";;
  --server-stop)
    history_save || :
    route_clear; exit 0;;
  --firewall)
    firewall_apply; exit $?;;
  --install-status-cron)
    install_status_cron; exit $?;;
  --save-status)
    history_save; exit $?;;
esac
# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
# BusyBox-based ASUS builds might not include the `id` applet/command.
# /proc/self/status is available on Linux and exposes the effective UID as
# the third field on its `Uid:` line. Check for awk before using it.
for binary in wg ip nvram iptables awk sed grep cat cp chmod mkdir rm mv sort tar service; do
  has_bin "$binary" || { err "Missing required command: $binary"; exit 1; }
done
if ! awk '$1 == "Uid:" { found = 1; root = ($3 == 0) } END { exit !(found && root) }' /proc/self/status 2>/dev/null; then
  err 'Run on the router as the SSH administrator/root.'
  exit 1
fi
[ "$(nvram get jffs2_scripts)" = 1 ] || { err 'Enable custom JFFS scripts in Administration > System.'; exit 1; }
[ "$(nvram get wgs1_enable)" = 1 ] || { err 'Enable ASUS WireGuard server 1 (wgs1) in the router GUI.'; exit 1; }
wg show "$IFACE" >/dev/null 2>&1 || { err 'wgs1 is not running.'; exit 1; }
SERVER_SUBNET=$(server_subnet)
[ -n "$SERVER_SUBNET" ] || { err 'Unable to determine wgs1 IPv4 subnet.'; exit 1; }
SERVER_IP=${SERVER_SUBNET%%/*}
CLIENT_POOL=$(client_pool)
[ -n "$(wg show "$IFACE" public-key)" ] || { err 'wgs1 public key is unavailable.'; exit 1; }
install_all || { err 'Installation/setup failed. Review hooks before proceeding.'; exit 1; }
install_status_cron || err 'History will still save when opening connection status, but periodic snapshots are not scheduled.'
history_save || err 'Initial history snapshot failed; check WireGuard and JFFS permissions.'
# Applying the new firewall policy here also removes obsolete v2.3 IPv6 blocks.
firewall_apply || { err 'Firewall initialization failed: LAN restrictions may be ineffective. No menu actions permitted.'; exit 1; }

# Client rows are sorted numerically by IPv4 octets, not lexically by name
# or IP. Keep GUI and extra sections separate and number continuously. Both
# display screens use the same iterators; the index uses the same ordering.
# The sort key is zero-padded (001.002.003.004), so .9 sorts before .10.
ip_sort_key() {
  printf '%s\n' "$1" | awk -F '[.]' 'NF==4 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/ && $1<=255 && $2<=255 && $3<=255 && $4<=255 {printf "%03d.%03d.%03d.%03d",$1,$2,$3,$4}'
}
sorted_gui_slots() {
  i=1
  while [ "$i" -le 10 ]; do
    name=$(nvram get "wgs1_c${i}_name")
    pub=$(nvram get "wgs1_c${i}_pub")
    enabled=$(nvram get "wgs1_c${i}_enable")
    addr=$(nvram get "wgs1_c${i}_addr")
    if [ -n "$name$pub$addr" ] || [ "$enabled" = 1 ]; then
      ipaddr=$(v4_token_gui "$i")
      key=$(ip_sort_key "$ipaddr")
      [ -n "$key" ] || key=999.999.999.999
      printf '%s|%s\n' "$key" "$i"
    fi
    i=$((i+1))
  done | sort | sed 's/^[^|]*|//'
}
sorted_extra_names() {
  for file in "$META"/*.meta; do
    [ -f "$file" ] || continue
    name=${file##*/}; name=${name%.meta}
    ipaddr=$(readfield "$file" IP)
    key=$(ip_sort_key "$ipaddr")
    [ -n "$key" ] || key=999.999.999.999
    printf '%s|%s\n' "$key" "$name"
  done | sort | sed 's/^[^|]*|//'
}
print_clients() {
  : > "$INDEXFILE" || return 1
  count=0
  ui_heading 'ASUS GUI clients (slots 1-10):'
  print_columns
  for sorted_slot in $(sorted_gui_slots); do
    i=$sorted_slot
    name=$(nvram get "wgs1_c${i}_name")
    enabled=$(nvram get "wgs1_c${i}_enable")
    count=$((count+1))
    [ -n "$name" ] || name="(slot $i)"
    ipaddr=$(v4_token_gui "$i")
    pol=inherit
    [ -f "$POLICY/gui-$i" ] && pol=$(cat "$POLICY/gui-$i")
    [ "$enabled" = 1 ] && status=enabled || status=disabled
    table_row "$count" "$name" "$ipaddr" "$status" "$pol"
    printf '%s|gui|%s\n' "$count" "$i" >> "$INDEXFILE"
  done
  ui_heading 'Additional script-managed clients:'
  print_columns
  found=0
  for name in $(sorted_extra_names); do
    found=1
    count=$((count+1))
    file="$META/$name.meta"
    table_row "$count" "$name" "$(readfield "$file" IP)" enabled "$(readfield "$file" POLICY)"
    printf '%s|extra|%s\n' "$count" "$name" >> "$INDEXFILE"
  done
  [ "$found" = 1 ] || say '(none)'
  printf '\nGUI policy "inherit" means the ASUS server-wide LAN-access setting applies.\n'
  say 'GUI policy "allow" is also subject to the server-wide LAN-access setting.'
  say 'Restrict is IPv4-only; router DNS on TCP/UDP 53 stays allowed.'
}
# A 74-character fixed-width client table fits conventional 80-column SSH
# sessions; print the complete name on an extra line if it exceeds 34 chars.
# Apply colour only AFTER field padding, to avoid breaking alignment.
table_row() {
  printf '%-3.3s %-34.34s %-15.15s ' "$1" "$2" "$3"
  case "$4" in
    enabled) row_colour=${UI_GREEN:-} ;;
    disabled) row_colour=${UI_GREY:-} ;;
    *) row_colour=${UI_YELLOW:-} ;;
  esac
  table_policy=$5
  [ "$table_policy" = deny ] && table_policy=restrict
  printf '%s%-8.8s%s %-10.10s\n' "$row_colour" "$4" "${UI_RESET:-}" "$table_policy"
  if [ "${#2}" -gt 34 ]; then printf '    Full name: %s\n' "$2"; fi
  ui_rule
}
table_columns() {
  printf '%-3s %-34s %-15s %-8s %-10s\n' ID Name 'VPN IPv4' "$1" "$2"
  ui_rule
}
print_columns() {
  table_columns Status 'LAN policy'
}
select_client() {
  while :; do
    ask 'Client ID [number, m = menu]: '
    SELECT=$ANSWER
    is_back "$SELECT" && return 2
    case "$SELECT" in
      ''|*[!0-9]*) err 'Enter a numeric ID from the list, or m to return.'; continue;;
    esac
    selection=$(awk -F '|' -v id="$SELECT" '$1==id {print $2 "|" $3;exit}' "$INDEXFILE")
    if [ -z "$selection" ]; then err 'Unknown client ID. Choose an ID from the list.'; continue; fi
    KIND=${selection%%|*}
    target=${selection#*|}
    if [ "$KIND" = gui ]; then
      INDEX=$target; NAME=$(nvram get "wgs1_c${INDEX}_name")
      [ -n "$NAME" ] || NAME="GUI-slot-$INDEX"
    else
      NAME=$target
      [ -f "$META/$NAME.meta" ] || { err 'This client no longer exists.'; continue; }
    fi
    return 0
  done
}
export_gui() {
  slot=$1
  # Prefer ASUS-generated client configuration. It contains original key material.
  src="/etc/wg/server1_client${slot}.conf"
  out="$EXPORTS/gui-$slot.conf"
  if [ -f "$src" ]; then cp "$src" "$out" || return 1
  else
    pre="wgs1_c${slot}_"
    priv=$(nvram get "${pre}priv"); addr=$(nvram get "${pre}addr")
    pub=$(nvram get wgs1_pub)
    psk=$(nvram get "${pre}psk"); allowed=$(nvram get "${pre}caips")
    [ -n "$priv" ] && [ -n "$addr" ] && [ -n "$pub" ] || { err 'GUI configuration missing and not reconstructable from NVRAM.'; return 1; }
    [ -n "$allowed" ] || allowed=$(nvram get wgs1_addr)
    ep=$(endpoint)
    {
      printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$priv" "$addr"
      [ "$(nvram get wgs1_dns)" = 1 ] && printf 'DNS = %s\n' "$SERVER_IP"
      printf '\n[Peer]\nPublicKey = %s\n' "$pub"
      [ "$(nvram get wgs1_psk)" != 1 ] || [ -z "$psk" ] || printf 'PresharedKey = %s\n' "$psk"
      printf 'AllowedIPs = %s\nEndpoint = %s\n' "$allowed" "$ep"
      keepalive=$(nvram get wgs1_alive)
      case "$keepalive" in ''|0|*[!0-9]*) :;; *) printf 'PersistentKeepalive = %s\n' "$keepalive";; esac
    } > "$out" || return 1
  fi
  # Do not rewrite the GUI-provided DNS: restricted clients may use
  # router DNS and custom DNS routing (for example, ASUS XrayUI).
  chmod 600 "$out"
  printf '%s\n' "$out"
}
show_config() {
  print_clients
  select_client || return $?
  if [ "$KIND" = gui ]; then
    path=$(export_gui "$INDEX") || return 1
  else
    path="$CLIENTS/$NAME.conf"
  fi
  printf "\nConfiguration for %s: %s\n" "$NAME" "$path"
  say 'WARNING: The following configuration contains PRIVATE KEY material.'
  ask 'Display it in this terminal? [y/n, Enter = n, m = menu]: '
  is_back "$ANSWER" && return 2
  if yes "$ANSWER"; then say ''; cat "$path"; fi
  printf "\nSave/copy this file securely: %s\n" "$path"
}
add_client() {
  while :; do
    ask 'New client name [letters, numbers, _ - ., m = menu]: '
    NEWNAME=$ANSWER
    is_back "$NEWNAME" && return 2
    valid_name "$NEWNAME" || { err 'Invalid name. Max 40 characters.'; continue; }
    [ ! -e "$PEERS/$NEWNAME.peer" ] && [ ! -e "$META/$NEWNAME.meta" ] && [ ! -e "$CLIENTS/$NEWNAME.conf" ] || { err 'Name already exists.'; continue; }
    break
  done
  OLDIP=''; choose_ip || return $?
  choose_policy || return $?
  priv=$(wg genkey) || return 1
  pub=$(printf '%s\n' "$priv" | wg pubkey) || return 1
  psk=''
  [ "$(nvram get wgs1_psk)" != 1 ] || psk=$(wg genpsk) || return 1
  ep=$(endpoint); allowed=$(client_allowed)
  case "$ep" in :*|0.0.0.0:*) err 'Endpoint unresolved; configure ASUS DDNS or WAN IP first.'; return 1;; esac
  if ! write_extra "$NEWNAME" "$NEWIP" "$NEWPOL" "$priv" "$pub" "$psk" "$ep" "$allowed"; then
    rm -f "$PEERS/$NEWNAME.peer" "$CLIENTS/$NEWNAME.conf" "$META/$NEWNAME.meta"
    err 'Unable to create files.'; return 1
  fi
  # Enforce restrictions before making peer live (fail closed on firewall errors).
  if ! firewall_apply; then
    rm -f "$PEERS/$NEWNAME.peer" "$CLIENTS/$NEWNAME.conf" "$META/$NEWNAME.meta"
    firewall_apply >/dev/null 2>&1 || :
    err 'Failed to install firewall policy; client not added.'; return 1
  fi
  if ! peer_live_add "$NEWNAME" "$NEWIP"; then
    rm -f "$PEERS/$NEWNAME.peer" "$CLIENTS/$NEWNAME.conf" "$META/$NEWNAME.meta"
    firewall_apply >/dev/null 2>&1 || :
    err 'WireGuard rejected peer; files rolled back.'; return 1
  fi
  success "Added $NEWNAME ($NEWIP) without restarting $IFACE."
  say "Client configuration: $CLIENTS/$NEWNAME.conf"
}
backup_gui() {
  slot=$1
  backup="$BACKUPS/gui-$slot.$(date +%Y%m%d-%H%M%S).$$.nvram"
  nvram show 2>/dev/null | grep "^wgs1_c${slot}_" > "$backup" || :
  chmod 600 "$backup"
  say "GUI settings backed up to $backup"
}
restart_gui_server() {
  say 'Restarting ASUS WireGuard server to apply GUI peer changes (brief VPN interruption)...'
  service restart_wgs || { err 'Service restart failed; inspect router GUI.'; return 1; }
  if wg show "$IFACE" >/dev/null 2>&1; then say 'WireGuard server is running.'; else err 'WireGuard server has not come up; check ASUS GUI.'; return 1; fi
}
modify_gui() {
  slot=$INDEX; prefix="wgs1_c${slot}_"
  oldname=$(nvram get "${prefix}name")
  oldip=$(v4_token_gui "$slot")
  ask "New name [Enter = keep '$oldname', m = menu]: "; newname=$ANSWER
  is_back "$newname" && return 2
  [ -n "$newname" ] || newname=$oldname
  # GUI labels may use arbitrary characters. Reject control chars / newlines.
  case "$newname" in ''|*'
'*) err 'Invalid GUI label.'; return 1;; esac
  say "Current VPN IPv4 address: $oldip"
  ask "Change VPN IPv4 address? [y/n, Enter = n, m = menu]: "; changeip=$ANSWER
  is_back "$changeip" && return 2
  NEWIP=$oldip
  if yes "$changeip"; then
    OLDIP=$oldip; choose_ip || return $?
  fi
  oldpol=inherit
  [ -f "$POLICY/gui-$slot" ] && oldpol=$(cat "$POLICY/gui-$slot")
  choose_policy "$oldpol" || return $?
  if [ "$newname" = "$oldname" ] && [ "$NEWIP" = "$oldip" ] && [ "$NEWPOL" = "$oldpol" ]; then
    say 'No changes needed.'; return 0
  fi
  newaddr=''; newaips=''
  if [ "$NEWIP" != "$oldip" ]; then
    newaddr=$(replace_v4_host "$(nvram get "${prefix}addr")" "$NEWIP") || { err 'Unsupported GUI address layout; no changes made.'; return 1; }
    newaips=$(replace_v4_host "$(nvram get "${prefix}aips")" "$NEWIP") || { err 'Unsupported GUI AllowedIPs layout; no changes made.'; return 1; }
  fi
  if [ "$NEWPOL" = deny ]; then
    # Validate current /32 AllowedIPs; IP edits substitute that /32 only.
    v4_safe_gui "$slot" || { err 'Per-client LAN denial requires one matching /32 IPv4 AllowedIPs entry.'; return 1; }
  fi
  say "Updating GUI slot $slot. The VPN server will restart."
  ask 'Proceed? [y/n, Enter = n, m = menu]: '; is_back "$ANSWER" && return 2
  yes "$ANSWER" || return 0
  backup_gui "$slot"
  [ "$newname" = "$oldname" ] || nvram set "${prefix}name=$newname"
  if [ "$NEWIP" != "$oldip" ]; then nvram set "${prefix}addr=$newaddr"; nvram set "${prefix}aips=$newaips"; fi
  if [ "$NEWPOL" = deny ]; then printf 'deny\n' > "$POLICY/gui-$slot"; else rm -f "$POLICY/gui-$slot"; fi
  nvram commit || { err 'NVRAM commit failed.'; return 1; }
  restart_gui_server || return 1
  firewall_apply || { err 'Firewall application failed. Check access restrictions immediately.'; return 1; }
  success 'GUI-managed client updated. Import its new configuration if its IP changed.'
  export_gui "$slot" >/dev/null && say "Updated configuration: $EXPORTS/gui-$slot.conf"
}
modify_extra() {
  oldname=$NAME; oldip=$(readfield "$META/$oldname.meta" IP)
  oldpol=$(readfield "$META/$oldname.meta" POLICY)
  ask "New name [Enter = keep '$oldname', m = menu]: "; newname=$ANSWER
  is_back "$newname" && return 2
  [ -n "$newname" ] || newname=$oldname
  valid_name "$newname" || { err 'Invalid name.'; return 1; }
  if [ "$newname" != "$oldname" ] && { [ -e "$PEERS/$newname.peer" ] || [ -e "$CLIENTS/$newname.conf" ] || [ -e "$META/$newname.meta" ]; }; then
    err 'That name is already in use.'; return 1
  fi
  say "Current VPN IPv4 address: $oldip"
  ask "Change VPN IPv4 address? [y/n, Enter = n, m = menu]: "; changeip=$ANSWER
  is_back "$changeip" && return 2
  NEWIP=$oldip
  if yes "$changeip"; then OLDIP=$oldip; choose_ip || return $?; fi
  choose_policy "$oldpol" || return $?
  [ "$newname" != "$oldname" ] || [ "$NEWIP" != "$oldip" ] || [ "$NEWPOL" != "$oldpol" ] || { say 'No changes.'; return 0; }
  priv=$(confval "$CLIENTS/$oldname.conf" PrivateKey)
  pub=$(confval "$PEERS/$oldname.peer" PublicKey)
  psk=$(confval "$PEERS/$oldname.peer" PresharedKey)
  ep=$(confval "$CLIENTS/$oldname.conf" Endpoint)
  allowed=$(confval "$CLIENTS/$oldname.conf" AllowedIPs)
  [ -n "$priv" ] && [ -n "$pub" ] && [ -n "$ep" ] && [ -n "$allowed" ] || { err 'Existing config is incomplete.'; return 1; }
  # Capture recoverable backup of original private-key material before changes.
  stamp=$(date +%Y%m%d-%H%M%S).$$
  mkdir -p "$BACKUPS/extra-$oldname.$stamp"
  chmod 700 "$BACKUPS/extra-$oldname.$stamp"
  cp -p "$PEERS/$oldname.peer" "$CLIENTS/$oldname.conf" "$META/$oldname.meta" "$BACKUPS/extra-$oldname.$stamp/" || return 1
  if ! write_extra "$newname" "$NEWIP" "$NEWPOL" "$priv" "$pub" "$psk" "$ep" "$allowed"; then
    err 'Unable to update client files; recover the original files from the backup folder.'
    return 1
  fi
  # Enforce new deny policy before updating WireGuard AllowedIPs.
  firewall_apply || { err 'Firewall update failed. Restore files from backup.'; return 1; }
  if ! peer_live_add "$newname" "$NEWIP"; then err 'Failed updating live peer; restore backup.'; return 1; fi
  if [ "$NEWIP" != "$oldip" ]; then
    ip -4 route del "$oldip/32" dev "$IFACE" 2>/dev/null || :
    blog_network del "$oldip/32"
  fi
  if [ "$newname" != "$oldname" ]; then
    rm -f "$PEERS/$oldname.peer" "$CLIENTS/$oldname.conf" "$META/$oldname.meta"
  fi
  firewall_apply || err 'Could not finalize policy; review firewall rules.'
  success "Updated script client: $newname ($NEWIP)."
  say "Updated config (re-import if IP changed): $CLIENTS/$newname.conf"
}
modify_client() {
  history_save || :
  print_clients; select_client || return $?
  if [ "$KIND" = gui ]; then modify_gui; else modify_extra; fi
}
delete_client() {
  history_save || :
  print_clients; select_client || return $?
  printf "\n"
  warning "About to delete $NAME ($SELECT)."
  [ "$KIND" = gui ] && warning 'This will erase its ASUS GUI slot, commit NVRAM, and restart the VPN server.'
  [ "$KIND" = extra ] && warning 'This will revoke the peer immediately and delete its local private-key config.'
  ask 'Type DELETE to confirm [m = menu]: '
  is_back "$ANSWER" && return 2
  [ "$ANSWER" = DELETE ] || { say 'Cancelled.'; return 0; }
  if [ "$KIND" = gui ]; then
    backup_gui "$INDEX"
    prefix="wgs1_c${INDEX}_"
    for field in enable name addr aips caips priv pub psk; do nvram unset "${prefix}${field}"; done
    rm -f "$POLICY/gui-$INDEX" "$EXPORTS/gui-$INDEX.conf"
    nvram commit || { err 'NVRAM commit failed.'; return 1; }
    restart_gui_server || return 1
    # ASUS may leave an old generated file when a slot is disabled.
    rm -f "/etc/wg/server1_client${INDEX}.conf" "/etc/wg/server1_client${INDEX}.png"
  else
    pub=$(readfield "$META/$NAME.meta" PUB)
    ipaddr=$(readfield "$META/$NAME.meta" IP)
    peer_live_remove "$pub" "$ipaddr" || return 1
    rm -f "$PEERS/$NAME.peer" "$CLIENTS/$NAME.conf" "$META/$NAME.meta"
  fi
  firewall_apply || { err 'Firewall cleanup failed; check rules.'; return 1; }
  success "Client $NAME deleted."
}


# Show LIVE connection activity plus previously persisted connection history.
# The last handshake and endpoint survive an interface restart/reboot, but a
# past handshake does not establish that a client is currently connected.
# Totals are accumulated from samples since history tracking was enabled.
# Each peer: one identity/status line, one traffic+endpoint line (or two
# details lines for longer endpoints). No information is truncated.
status_columns() {
  printf '%-3s %-26s %-15s %-10s %s\n' \
    'ID' 'Name' 'VPN IPv4' 'Connection' 'Last handshake'
  ui_rule
}
format_transfer() {
  awk -v rx="$1" -v tx="$2" '
    function nice(n, u,j) {
      if (n !~ /^[0-9]+$/) return "?";
      n += 0;
      if (n<1024) return sprintf("%.0f B",n);
      split("B KiB MiB GiB TiB PiB EiB",u," "); j=1;
      while(n>=1024 && j<7){n/=1024;j++}
      return sprintf("%.2f %s",n,u[j]);
    }
    BEGIN {printf "RX: %s | TX: %s\n",nice(rx),nice(tx)}'
}
handshake_age() {
  last=$1
  case "$last" in ''|0|*[!0-9]*) printf 'never\n'; return;; esac
  age=$((NOW - last))
  if [ "$age" -lt 0 ]; then printf 'clock skew\n'
  elif [ "$age" -lt 60 ]; then printf '%ss ago\n' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%sm %ss ago\n' "$((age / 60))" "$((age % 60))"
  elif [ "$age" -lt 86400 ]; then printf '%sh %sm ago\n' "$((age / 3600))" "$(((age % 3600) / 60))"
  else printf '%sd %sh ago\n' "$((age / 86400))" "$(((age % 86400) / 3600))"
  fi
}
status_row() {
  rowid=$1 rowname=$2 rowip=$3 rowenabled=$4 rowpub=$5
  state=unknown; when='-'; remote='(none)'; transfer='-'
  livehs=''; hisths=0; last=0; liveint=0
  if [ -n "$rowpub" ]; then
    livehs=$(awk -v key="$rowpub" '$1==key {print $2;exit}' "$STATUSFILE")
    histline=$(awk -F '|' -v key="$rowpub" '$1==key {print;exit}' "$HISTORY_STATE" 2>/dev/null)
    if [ -n "$histline" ]; then
      # Split the persisted record; fields cannot contain pipe characters.
      hisths=$(printf '%s\n' "$histline" | awk -F '|' '{print $2}')
      remote=$(printf '%s\n' "$histline" | awk -F '|' '{print $3}')
      h_rx=$(printf '%s\n' "$histline" | awk -F '|' '{print $4}')
      h_tx=$(printf '%s\n' "$histline" | awk -F '|' '{print $5}')
      transfer=$(format_transfer "$h_rx" "$h_tx")
    fi
    # WireGuard keeps its live handshake and endpoint in kernel memory after
    # manager history is cleared. Suppress those *older* live values until a
    # successful handshake occurs strictly AFTER the clear timestamp.
    # Otherwise "Clear saved connection history" appears not to work.
    case "$hisths" in ''|*[!0-9]*) hisths=0;; esac
    case "$livehs" in ''|*[!0-9]*) liveint=0;; *) liveint=$livehs;; esac
    if [ "$STATUS_CUTOFF" -gt 0 ]; then
      if [ "$hisths" -le "$STATUS_CUTOFF" ]; then
        hisths=0
        remote='(none)'
      fi
      if [ "$liveint" -le "$STATUS_CUTOFF" ]; then
        liveint=0
      fi
    fi
    liveep=$(awk -v key="$rowpub" '$1==key {print $2;exit}' "$ENDPOINTFILE")
    # A remembered endpoint is not a new connection after a clear.
    # Only show it when a post-clear handshake proves it is fresh.
    if [ "$liveint" -gt 0 ] && [ -n "$liveep" ] && [ "$liveep" != '(none)' ]; then
      remote=$liveep
    fi
    if [ "$transfer" = '-' ]; then
      if [ "$STATUS_CUTOFF" -gt 0 ]; then
        # The unadjusted kernel counters include traffic from before clear.
        # Do not show them without a known post-clear baseline.
        transfer='RX: 0 B | TX: 0 B'
      else
        # Without saved history, display the available live counters.
        transfer=$(awk -v key="$rowpub" '$1==key {printf "%.0f %.0f\n", $3, $2;exit}' "$TRANSFERFILE")
        if [ -n "$transfer" ]; then
          transfer=$(format_transfer ${transfer})
        else
          transfer='-'
        fi
      fi
    fi
  fi
  [ -n "$remote" ] || remote='(none)'
  case "$hisths" in ''|*[!0-9]*) hisths=0;; esac
  # liveint is already filtered against the last history-clear cutoff above.
  [ -n "$rowpub" ] || liveint=0
  last=$hisths
  if [ "$liveint" -gt "$last" ]; then last=$liveint; fi
  if [ "$rowenabled" != 1 ]; then
    state=disabled
  elif [ -z "$rowpub" ]; then
    state='no key'
  elif [ -z "$livehs" ]; then
    state='not loaded'
  elif [ "$liveint" -gt 0 ] && [ "$liveint" -le "$NOW" ] && [ "$((NOW - liveint))" -le 180 ]; then
    state=recent
  elif [ "$last" -gt 0 ]; then
    state=idle
  else
    state=never
  fi
  when=$(handshake_age "$last")
  [ "$transfer" = '-' ] && transfer='Transfer: unavailable'
  case "$state" in
    recent) STATUS_RECENT=$((STATUS_RECENT + 1)); status_colour=${UI_GREEN:-} ;;
    idle) STATUS_IDLE=$((STATUS_IDLE + 1)); status_colour=${UI_YELLOW:-} ;;
    never) STATUS_NEVER=$((STATUS_NEVER + 1)); status_colour=${UI_GREY:-} ;;
    disabled) STATUS_DISABLED=$((STATUS_DISABLED + 1)); status_colour=${UI_GREY:-} ;;
    *) STATUS_UNAVAILABLE=$((STATUS_UNAVAILABLE + 1)); status_colour=${UI_RED:-} ;;
  esac
  # Recent: green name. Idle with an actual handshake <24h ago: yellow name.
  # A stored handshake may be older than 24h; never colour it yellow merely
  # because its connection state is 'idle'. Disabled peers keep neutral names.
  name_colour=''
  if [ "$state" = recent ]; then
    name_colour=${UI_GREEN:-}
  elif [ "$state" = idle ] && [ "$last" -gt 0 ] && [ "$last" -le "$NOW" ] &&
       [ "$((NOW - last))" -lt 86400 ]; then
    name_colour=${UI_YELLOW:-}
  fi
  printf '%-3.3s ' "$rowid"
  printf '%s%-26.26s%s %-15.15s ' "$name_colour" "$rowname" "${UI_RESET:-}" "$rowip"
  printf '%s%-10.10s%s %s\n' "$status_colour" "$state" "${UI_RESET:-}" "$when"
  if [ "${#rowname}" -gt 26 ]; then
    printf '    Full name: %s%s%s\n' "$name_colour" "$rowname" "${UI_RESET:-}"
  fi
  # The long IPv6 endpoint is moved onto its own line rather than wrapping
  # against the next client's row; this preserves both endpoint and traffic.
  if [ $(( ${#transfer} + ${#remote} + 19 )) -le 76 ]; then
    printf '    %s | Endpoint: %s\n' "$transfer" "$remote"
  else
    printf '    %s\n' "$transfer"
    printf '    Endpoint: %s\n' "$remote"
  fi
  ui_rule
}
show_connection_status() {
  if ! wg show "$IFACE" latest-handshakes > "$STATUSFILE" ||
     ! wg show "$IFACE" endpoints > "$ENDPOINTFILE" ||
     ! wg show "$IFACE" transfer > "$TRANSFERFILE"; then
    err "Unable to read the running WireGuard interface $IFACE."
    return 1
  fi
  NOW=$(date +%s) || return 1
  case "$NOW" in ''|*[!0-9]*) err 'Router clock is invalid.'; return 1;; esac
  # Save before displaying. The five-minute cron and server-stop hook also
  # update history even if nobody opens the menu.
  history_save || err 'Could not update saved history; displaying available data.'
  # A clear does not reset the live WireGuard kernel state. Read the durable
  # cutoff once per snapshot, and enforce it on BOTH persisted and live values.
  STATUS_CUTOFF=0
  if [ -f "$HISTORY_CLEARED" ]; then STATUS_CUTOFF=$(cat "$HISTORY_CLEARED" 2>/dev/null); fi
  case "$STATUS_CUTOFF" in ''|*[!0-9]*) STATUS_CUTOFF=0;; esac
  # Build the two sections once in private /tmp files to place the summary
  # above the tables without re-reading or reclassifying any peer.
  STATUS_RECENT=0 STATUS_IDLE=0 STATUS_NEVER=0
  STATUS_DISABLED=0 STATUS_UNAVAILABLE=0
  count=0
  : > "$STATUS_GUI_RENDER" || return 1
  : > "$STATUS_EXTRA_RENDER" || return 1
  {
    ui_heading 'ASUS GUI clients (slots 1-10):'
    status_columns
    for i in $(sorted_gui_slots); do
      name=$(nvram get "wgs1_c${i}_name")
      pub=$(nvram get "wgs1_c${i}_pub")
      enabled=$(nvram get "wgs1_c${i}_enable")
      count=$((count+1))
      [ -n "$name" ] || name="(slot $i)"
      status_row "$count" "$name" "$(v4_token_gui "$i")" "$enabled" "$pub"
    done
  } > "$STATUS_GUI_RENDER" || return 1
  found=0
  {
    ui_heading 'Additional script-managed clients:'
    status_columns
    for name in $(sorted_extra_names); do
      found=1; count=$((count+1))
      file="$META/$name.meta"
      status_row "$count" "$name" "$(readfield "$file" IP)" 1 "$(readfield "$file" PUB)"
    done
    [ "$found" = 1 ] || say '(none)'
  } > "$STATUS_EXTRA_RENDER" || return 1
  ui_heading "Connection status — $IFACE (live + saved history)"
  printf 'Clients: %s | Recent: %s | Idle: %s | Never: %s' \
    "$count" "$STATUS_RECENT" "$STATUS_IDLE" "$STATUS_NEVER"
  [ "$STATUS_DISABLED" -gt 0 ] && printf ' | Disabled: %s' "$STATUS_DISABLED"
  [ "$STATUS_UNAVAILABLE" -gt 0 ] && printf ' | Unavailable: %s' "$STATUS_UNAVAILABLE"
  printf '\n'
  ui_rule
  cat "$STATUS_GUI_RENDER" "$STATUS_EXTRA_RENDER" || return 1
  printf '\n'
  say 'Recent = live handshake within 3 minutes; idle = older live/saved handshake.'
  [ "$STATUS_CUTOFF" -gt 0 ] && say 'After history clear, only newer handshakes are shown.'
  say 'Status is approximate, not a guarantee of an active connection.'
  say 'Endpoints and accumulated transfers survive router restarts.'
  say 'History directory: /jffs/wg-manager/history/.'
  say 'RX/TX: client perspective; accumulated since history tracking began.'
  say 'Snapshots: every 5 minutes, at server stop and when this screen opens.'
}
connection_status() {
  while :; do
    show_connection_status || return 1
    printf '\n'
    ui_menu_item 1 'Refresh connection status'
    ui_menu_item 2 'Clear saved connection history'
    ask 'Select [1-2, m = menu]: '
    case "$ANSWER" in
      1) : ;;
      2)
        warning 'This removes saved endpoint, handshake and accumulated transfer history.'
        warning 'It does NOT disconnect clients or reset live WireGuard kernel counters.'
        say 'Earlier live handshakes and endpoints will be hidden from the status screen.'
        ask 'Clear saved history for all clients? [y/n, Enter = n, m = menu]: '
        is_back "$ANSWER" && return 2
        if yes "$ANSWER"; then
          history_clear || { err 'Could not clear saved connection history.'; return 1; }
          say 'Saved history cleared. Pre-clear handshakes and endpoints are now hidden.'
          say 'New handshakes and traffic will be recorded from this point forward.'
        fi ;;
      m|M) return 2 ;;
      *) err 'Select 1, 2 or m.' ;;
    esac
  done
}

# Backups contain unencrypted private keys, pre-shared keys, and router-side
# settings. Store archives on trusted storage only. Restores target wgs1 and
# the manager's JFFS files, never the router's entire NVRAM.
backup_create() {
  b_output=$1
  [ -n "$b_output" ] || return 1
  case "$b_output" in /*) : ;; *) err 'Backup path must be absolute.'; return 1;; esac
  [ ! -e "$b_output" ] || { err "Backup already exists: $b_output"; return 1; }
  b_parent=${b_output%/*}
  [ -n "$b_parent" ] || b_parent=/
  mkdir -p "$b_parent" || return 1
  b_tmp=$(make_temp_dir wgm-backup) || { err 'Unable to create private backup staging directory in /tmp.'; return 1; }
  mkdir -p "$b_tmp/data" "$b_tmp/scripts/hooks" "$b_tmp/generated" || { rm -rf "$b_tmp"; return 1; }
  printf 'FORMAT=WG_MANAGER_BACKUP_V1\nMODEL=%s\nFIRMWARE=%s\nCREATED=%s\nSERVER=wgs1\n' \
    "$(nvram get productid)" "$(firmware_version)" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$b_tmp/manifest"
  # Capture the freshest possible connection snapshot in backup as well.
  history_save || { err 'Unable to save connection history before backup.'; rm -rf "$b_tmp"; return 1; }
  # Includes server and ASUS GUI clients (names, VPN IPs, keys and server setup).
  # Do not save unrelated router settings.
  nvram show 2>/dev/null | grep '^wgs1_' > "$b_tmp/nvram-wgs1.txt"
  if [ ! -s "$b_tmp/nvram-wgs1.txt" ]; then
    err 'Unable to capture wgs1 NVRAM settings.'
    rm -rf "$b_tmp"; return 1
  fi
  # Include manager clients/keys/policies and historical edit backups. Archives
  # are intentionally excluded to avoid nested recursive backup growth.
  for b_folder in peers clients meta policies exports backups history; do
    mkdir -p "$b_tmp/data/$b_folder" || { rm -rf "$b_tmp"; return 1; }
    for b_entry in "$BASE/$b_folder"/*; do
      [ -e "$b_entry" ] || [ -L "$b_entry" ] || continue
      [ "$b_entry" = "$ARCHIVES" ] && continue
      cp -pR "$b_entry" "$b_tmp/data/$b_folder/" || {
        err "Could not copy $b_entry into backup."; rm -rf "$b_tmp"; return 1;
      }
    done
  done
  # Save executable itself and all manager-touched Merlin hooks, including any
  # unrelated commands those hooks contain; restoring overwrites those hooks.
  cp -p "$SELF" "$b_tmp/scripts/wg-manager.sh" || { rm -rf "$b_tmp"; return 1; }
  for b_hook in wgserver.postconf wgserver-start wgserver-stop firewall-start services-start; do
    if [ -f "/jffs/scripts/$b_hook" ]; then
      cp -p "/jffs/scripts/$b_hook" "$b_tmp/scripts/hooks/$b_hook" || {
        rm -rf "$b_tmp"; return 1;
      }
    fi
  done
  # Store generated ASUS client config files for reference; firmware normally
  # regenerates these ephemeral files after NVRAM is restored/restarted.
  for b_generated in /etc/wg/server1.conf /etc/wg/server1_client*.conf; do
    [ -f "$b_generated" ] || continue
    cp -p "$b_generated" "$b_tmp/generated/" || { rm -rf "$b_tmp"; return 1; }
  done
  chmod -R go-rwx "$b_tmp" 2>/dev/null || :
  b_partial="$b_output.partial.$$"
  if ! tar -czf "$b_partial" -C "$b_tmp" .; then
    rm -f "$b_partial"; rm -rf "$b_tmp"; err 'Failed creating backup archive.'; return 1
  fi
  chmod 600 "$b_partial"
  if ! mv "$b_partial" "$b_output"; then
    rm -f "$b_partial"; rm -rf "$b_tmp"; return 1
  fi
  rm -rf "$b_tmp"
  return 0
}

backup_menu() {
  say 'Backup scope: wgs1 ASUS settings/GUI peers, extra clients, keys, policies,'
  say 'the manager executable, Merlin hooks, and generated client configs.'
  warning 'Archives contain UNENCRYPTED private keys: keep them secure.'
  say 'Consider using a mounted USB drive instead of limited JFFS storage.'
  b_suggest="$ARCHIVES/wg-manager-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  ask "Backup archive [Enter = $b_suggest, m = menu]: "
  is_back "$ANSWER" && return 2
  b_target=${ANSWER:-$b_suggest}
  case "$b_target" in /*) :;; *) err 'Use an absolute destination path.'; return 1;; esac
  if backup_create "$b_target"; then
    success "Backup saved to: $b_target"
    say 'Keep a separate copy off the router; JFFS does not survive every reset.'
  else
    return 1
  fi
}

# Validate tar paths BEFORE extracting to avoid archive path traversal. Only
# restore archives you made with this manager; do not use untrusted archives.
validate_backup_archive() {
  r_archive=$1
  r_list=$2
  tar -tzf "$r_archive" > "$r_list" || { err 'Archive is unreadable or corrupt.'; return 1; }
  while IFS= read -r r_member || [ -n "$r_member" ]; do
    case "$r_member" in
      /*|../*|*/../*|*/..|..)
        err 'Unsafe archive member path found; refusing restore.'; return 1;;
    esac
  done < "$r_list"
  if ! awk '/[[:cntrl:]]/ {bad=1} END{exit bad?1:0}' "$r_list"; then
    err 'Unsafe control character in archive member path.'; return 1
  fi
  # Archives created by this script contain ordinary files and directories.
  # Reject symlink/hardlink entries to avoid redirecting extracted paths.
  r_types="$r_list.types"
  tar -tvzf "$r_archive" > "$r_types" || return 1
  if awk 'substr($1,1,1)=="l" || substr($1,1,1)=="h" {bad=1} END{exit bad?0:1}' "$r_types"; then
    err 'Archive contains symbolic/hard links; refusing restore.'; return 1
  fi
  return 0
}

# Restore a complete wgs1 snapshot. The current snapshot is automatically
# archived first. If restart or firewall application fails, attempt rollback.
restore_archive() {
  r_file=$1
  [ -f "$r_file" ] || { err "Backup file not found: $r_file"; return 1; }
  r_stage=$(make_temp_dir wgm-restore) || { err 'Unable to create private restore staging directory in /tmp.'; return 1; }
  if ! validate_backup_archive "$r_file" "$r_stage/list"; then
    rm -rf "$r_stage"; return 1
  fi
  mkdir -p "$r_stage/unpacked" "$r_stage/prior-hooks" || { rm -rf "$r_stage"; return 1; }
  if ! tar -xzf "$r_file" -C "$r_stage/unpacked"; then
    err 'Backup extraction failed.'; rm -rf "$r_stage"; return 1
  fi
  r_payload=$r_stage/unpacked
  if [ "$(readfield "$r_payload/manifest" FORMAT)" != WG_MANAGER_BACKUP_V1 ] || \
     [ "$(readfield "$r_payload/manifest" SERVER)" != wgs1 ]; then
    err 'Unsupported backup format or server.'; rm -rf "$r_stage"; return 1
  fi
  r_model=$(readfield "$r_payload/manifest" MODEL)
  if [ -z "$r_model" ] || [ "$r_model" != "$(nvram get productid)" ]; then
    err "This backup belongs to a different router model ($r_model)."
    rm -rf "$r_stage"; return 1
  fi
  for r_required in "$r_payload/nvram-wgs1.txt" "$r_payload/scripts/wg-manager.sh" \
    "$r_payload/data/peers" "$r_payload/data/clients" \
    "$r_payload/data/meta" "$r_payload/data/policies"; do
    if [ ! -e "$r_required" ]; then
      err "Backup is incomplete (missing ${r_required##*/})."; rm -rf "$r_stage"; return 1
    fi
  done
  [ -s "$r_payload/nvram-wgs1.txt" ] || { err 'Empty wgs1 settings.'; rm -rf "$r_stage"; return 1; }
  if ! grep -q '^wgs1_enable=' "$r_payload/nvram-wgs1.txt"; then
    err 'Backup has no WireGuard server enable setting; refusing restore.'
    rm -rf "$r_stage"; return 1
  fi
  # Sanity-check each NVRAM assignment before touching live settings.
  if ! awk '
    /^[[:space:]]*$/ {next}
    !/^wgs1_[A-Za-z0-9_]+=/ {bad=1}
    END{exit bad?1:0}
  ' "$r_payload/nvram-wgs1.txt"; then
    err 'Invalid wgs1 NVRAM records in archive.'; rm -rf "$r_stage"; return 1
  fi
  # ASUS /usr/sbin/sh is a memory utility, not the shell; use /bin/sh.
  if ! /bin/sh -n "$r_payload/scripts/wg-manager.sh"; then
    err 'Manager script inside archive has invalid shell syntax.'; rm -rf "$r_stage"; return 1
  fi
  r_firmware=$(readfield "$r_payload/manifest" FIRMWARE)
  say "Backup router: $r_model | Firmware at backup: $r_firmware"
  say "Current firmware: $(firmware_version)"
  warning 'RESTORE WILL REPLACE the current wgs1 ASUS GUI settings, extra clients,'
  warning 'private keys, access policies, manager executable, and manager hooks.'
  warning 'It will restart the WireGuard server and disconnect active clients.'
  say 'Hook files may contain other custom commands; those will also be replaced.'
  ask 'Type RESTORE to continue [m = menu]: '
  if is_back "$ANSWER"; then rm -rf "$r_stage"; return 2; fi
  if [ "$ANSWER" != RESTORE ]; then say 'Restore cancelled.'; rm -rf "$r_stage"; return 0; fi

  # Always take a safety snapshot first; do not proceed if it fails.
  mkdir -p "$ARCHIVES" || { rm -rf "$r_stage"; return 1; }
  r_safety="$ARCHIVES/before-restore-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  if ! backup_create "$r_safety"; then
    err 'Unable to create mandatory pre-restore backup; restore cancelled.'
    rm -rf "$r_stage"; return 1
  fi
  say "Safety backup: $r_safety"
  : > "$HISTORY_SUSPEND"
  r_stamp=$(date +%Y%m%d-%H%M%S).$$
  r_incoming="$BASE.incoming.$r_stamp"
  r_previous="$BASE.before-restore.$r_stamp"
  mkdir -p "$r_incoming" || { rm -f "$HISTORY_SUSPEND"; rm -rf "$r_stage"; return 1; }
  for r_folder in peers clients meta policies exports backups history; do
    if [ -d "$r_payload/data/$r_folder" ]; then
      cp -pR "$r_payload/data/$r_folder" "$r_incoming/" || {
        rm -f "$HISTORY_SUSPEND"; rm -rf "$r_incoming" "$r_stage"; return 1;
      }
    else
      mkdir -p "$r_incoming/$r_folder" || { rm -f "$HISTORY_SUSPEND"; rm -rf "$r_incoming" "$r_stage"; return 1; }
    fi
  done
  chmod -R go-rwx "$r_incoming" 2>/dev/null || :
  # Save exact state required for an automated rollback on service failure.
  nvram show 2>/dev/null | grep '^wgs1_' > "$r_stage/prior-nvram.txt"
  for r_hook in wgserver.postconf wgserver-start wgserver-stop firewall-start services-start; do
    [ -f "/jffs/scripts/$r_hook" ] && cp -p "/jffs/scripts/$r_hook" "$r_stage/prior-hooks/$r_hook"
  done
  cp -p "$SELF" "$r_stage/prior-manager.sh" || { rm -f "$HISTORY_SUSPEND"; rm -rf "$r_incoming" "$r_stage"; return 1; }
  if mv "$BASE" "$r_previous" && mv "$r_incoming" "$BASE"; then
    :
  else
    err 'Could not swap manager data directories.'
    [ -d "$r_previous" ] && [ ! -d "$BASE" ] && mv "$r_previous" "$BASE"
    rm -f "$HISTORY_SUSPEND"
    rm -rf "$r_incoming" "$r_stage"; return 1
  fi
  # Archive hook files are restored as supplied; the installer can fix older
  # manager-owned paths when opened again.
  r_failed=0
  for r_hook in wgserver.postconf wgserver-start wgserver-stop firewall-start services-start; do
    if [ -f "$r_payload/scripts/hooks/$r_hook" ]; then
      cp -p "$r_payload/scripts/hooks/$r_hook" "/jffs/scripts/$r_hook" || r_failed=1
    fi
  done
  if [ "$r_failed" = 0 ]; then
    # Restore all captured wgs1_* settings, removing keys added after backup.
    while IFS= read -r r_line || [ -n "$r_line" ]; do
      r_key=${r_line%%=*}
      case "$r_key" in wgs1_*) nvram unset "$r_key" || r_failed=1;; esac
    done < "$r_stage/prior-nvram.txt"
    while IFS= read -r r_line || [ -n "$r_line" ]; do
      [ -n "$r_line" ] || continue
      nvram set "$r_line" || r_failed=1
    done < "$r_payload/nvram-wgs1.txt"
    nvram commit || r_failed=1
  fi
  if [ "$r_failed" = 0 ]; then
    cp -p "$r_payload/scripts/wg-manager.sh" "$SELF.tmp.$$" && \
      chmod 700 "$SELF.tmp.$$" && mv "$SELF.tmp.$$" "$SELF" || r_failed=1
  fi
  if [ "$r_failed" = 0 ]; then
    service restart_wgs && wg show "$IFACE" >/dev/null 2>&1 && firewall_apply || r_failed=1
  fi
  if [ "$r_failed" = 0 ]; then
    # Keep the archive library (including the safety backup), which was
    # excluded from the archive to avoid recursion.
    mkdir -p "$BASE/backups"
    if [ -d "$r_previous/backups/archives" ]; then
      rm -rf "$BASE/backups/archives"
      mv "$r_previous/backups/archives" "$BASE/backups/archives" || err 'Could not move historical backup archives back.'
    fi
    rm -rf "$r_previous" "$r_stage"
    rm -f "$HISTORY_SUSPEND"
    success 'Restore completed. ASUS WireGuard server restarted with restored settings.'
    return 0
  fi
  err 'Restore did not complete; attempting to revert to prior settings.'
  rm -f "$SELF.tmp.$$"
  cp -p "$r_stage/prior-manager.sh" "$SELF.rollback.$$" && \
    chmod 700 "$SELF.rollback.$$" && mv "$SELF.rollback.$$" "$SELF" || :
  for r_hook in wgserver.postconf wgserver-start wgserver-stop firewall-start services-start; do
    [ -f "$r_stage/prior-hooks/$r_hook" ] && cp -p "$r_stage/prior-hooks/$r_hook" "/jffs/scripts/$r_hook"
  done
  # Remove currently-present restored settings and reapply pre-restore values.
  nvram show 2>/dev/null | grep '^wgs1_' | sed 's/=.*//' | while IFS= read -r r_key; do
    nvram unset "$r_key" || :
  done
  while IFS= read -r r_line || [ -n "$r_line" ]; do
    [ -n "$r_line" ] && nvram set "$r_line"
  done < "$r_stage/prior-nvram.txt"
  nvram commit || :
  rm -rf "$BASE"
  mv "$r_previous" "$BASE" || err 'Automatic data rollback failed; recover from safety backup.'
  service restart_wgs || :
  firewall_apply || :
  rm -f "$HISTORY_SUSPEND"
  rm -rf "$r_stage"
  err 'Restore failed; rollback was attempted. Verify clients and firewall rules.'
  return 1
}

backup_restore_menu() {
  while :; do
    ui_heading 'Backup and restore (wgs1)'
    ui_menu_item 1 'Create backup archive'
    ui_menu_item 2 'Restore from backup archive'
    ask 'Select [1-2, m = menu]: '
    case "$ANSWER" in
      1) backup_menu; return $?;;
      2)
        say 'Available archives in the default directory:'
        for r_path in "$ARCHIVES"/*.tar.gz; do
          [ -f "$r_path" ] && printf '  %s\n' "$r_path"
        done
        ask 'Absolute path to backup archive [m = menu]: '
        is_back "$ANSWER" && return 2
        case "$ANSWER" in /*) restore_archive "$ANSWER"; return $?;;
          *) err 'Enter an absolute archive path.'; return 1;; esac;;
      m|M) return 2;;
      *) err 'Select 1, 2 or m.';;
    esac
  done
}

firmware_version() {
  # E.g. firmver=3.0.0.6, buildno=102, extendno=9_0
  # -> 3006.102.9; newer builds may already contain 102.9 in buildno.
  base=$(nvram get firmver | tr -d '.')
  build=$(nvram get buildno)
  extra=$(nvram get extendno)
  extra=${extra%%_*}
  extra=${extra%%-*}
  case "$base" in ''|*[!0-9]*) base=$(nvram get firmver);; esac
  if [ -z "$build" ]; then printf '%s\n' "$base"; return; fi
  case "$build" in
    *.*) printf '%s.%s\n' "$base" "$build" ;;
    *) case "$extra" in
         ''|0|*[!0-9]*) printf '%s.%s\n' "$base" "$build" ;;
         *) printf '%s.%s.%s\n' "$base" "$build" "$extra" ;;
       esac ;;
  esac
}
# ---------------------------------------------------------------------------
# GitHub Releases updater (interactive menu only; never called by boot hooks).
# The release workflow publishes immutable, tagged wg-manager.sh files and a
# VERSION=... SHA256=... manifest. The hash is an integrity check, not a digital
# signature; only publish from a repository whose contributors you trust.
# ---------------------------------------------------------------------------
UPDATE_CACHE=$BASE/update-cache.txt
UPDATE_FAILED_AT=$BASE/update-check-failed-at
UPDATE_BACKUPS=$BACKUPS/updates
UPDATE_LATEST_URL="https://github.com/$UPDATE_REPO/releases/latest/download"
UPDATE_CHECK_INTERVAL=43200

valid_update_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$'
}
update_newer() {
  # Return true if semver-like a.b.c in $1 > a.b.c in $2.
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a,x,"."); split(b,y,".");
    for(i=1;i<=3;i++){if(x[i]+0>y[i]+0) exit 0; if(x[i]+0<y[i]+0) exit 1;}
    exit 1;
  }'
}
update_parse_manifest() {
  um_file=$1
  UM_VERSION=$(sed -n 's/^VERSION=//p' "$um_file" | sed -n '1p')
  UM_HASH=$(sed -n 's/^SHA256=//p' "$um_file" | sed -n '1p')
  valid_update_version "$UM_VERSION" || return 1
  [ "${#UM_HASH}" -eq 64 ] || return 1
  case "$UM_HASH" in *[!0-9a-fA-F]*) return 1;; esac
  [ "$(grep -c '^VERSION=' "$um_file")" -eq 1 ] || return 1
  [ "$(grep -c '^SHA256=' "$um_file")" -eq 1 ] || return 1
  return 0
}
update_fetch() {
  # -f fails on HTTP errors; -L follows GitHub's HTTPS release redirects;
  # no -k / insecure TLS options. Does not accept a caller-supplied URL.
  has_bin curl || { warning 'curl is not installed on this router.'; return 1; }
  curl --proto '=https' --proto-redir '=https' -fLsS \
    --connect-timeout 7 --max-time 25 --retry 1 -o "$2" "$1"
}
update_load_cache() {
  UPDATE_LATEST='' UPDATE_CACHED_AT=0
  [ -f "$UPDATE_CACHE" ] || return 1
  UPDATE_LATEST=$(sed -n 's/^VERSION=//p' "$UPDATE_CACHE" | sed -n '1p')
  UPDATE_CACHED_AT=$(sed -n 's/^CHECKED=//p' "$UPDATE_CACHE" | sed -n '1p')
  valid_update_version "$UPDATE_LATEST" || { UPDATE_LATEST=''; return 1; }
  case "$UPDATE_CACHED_AT" in ''|*[!0-9]*) UPDATE_CACHED_AT=0;; esac
  return 0
}
update_check() {
  # A fresh check always re-fetches the manifest. For routine menu viewing,
  # use the successful result for 12 hours and continue normally if offline.
  uc_force=${1:-n}
  update_load_cache || :
  uc_now=$(date +%s) || return 1
  case "$uc_now" in ''|*[!0-9]*) uc_now=0;; esac
  if [ "$uc_force" != y ] && [ -n "$UPDATE_LATEST" ] &&
     [ "$UPDATE_CACHED_AT" -le "$uc_now" ] &&
     [ "$((uc_now - UPDATE_CACHED_AT))" -lt "$UPDATE_CHECK_INTERVAL" ]; then
    return 0
  fi
  # Do not retry a failed automatic check on every menu repaint.
  if [ "$uc_force" != y ] && [ -f "$UPDATE_FAILED_AT" ]; then
    uc_failed=$(cat "$UPDATE_FAILED_AT" 2>/dev/null)
    case "$uc_failed" in ''|*[!0-9]*) uc_failed=0;; esac
    if [ "$uc_failed" -le "$uc_now" ] &&
       [ "$((uc_now - uc_failed))" -lt 1800 ]; then return 1; fi
  fi
  uc_temp=$(make_temp_dir wgm-update-check) || return 1
  if ! update_fetch "$UPDATE_LATEST_URL/update-info.txt" "$uc_temp/manifest"; then
    rm -rf "$uc_temp"
    printf '%s\n' "$uc_now" > "$UPDATE_FAILED_AT" 2>/dev/null || :
    return 1
  fi
  if ! update_parse_manifest "$uc_temp/manifest"; then
    rm -rf "$uc_temp"; printf '%s\n' "$uc_now" > "$UPDATE_FAILED_AT" 2>/dev/null || :; warning 'Invalid update manifest returned by GitHub.'; return 1
  fi
  UPDATE_LATEST=$UM_VERSION
  mkdir -p "$BASE" || { rm -rf "$uc_temp"; return 1; }
  printf 'VERSION=%s\nCHECKED=%s\n' "$UPDATE_LATEST" "$uc_now" > "$uc_temp/cache"
  chmod 600 "$uc_temp/cache"
  mv "$uc_temp/cache" "$UPDATE_CACHE" || { rm -rf "$uc_temp"; return 1; }
  UPDATE_CACHED_AT=$uc_now
  rm -f "$UPDATE_FAILED_AT"
  rm -rf "$uc_temp"
  return 0
}
update_version_line() {
  # We display one version in the banner; only the latest is a separate line.
  update_load_cache || :
  if [ -z "$UPDATE_LATEST" ]; then
    printf 'Latest version:  Unavailable (check via option 7)\n'
  elif update_newer "$UPDATE_LATEST" "$WG_MANAGER_VERSION"; then
    printf 'Latest version:  %s  %s[Update available]%s\n' \
      "$UPDATE_LATEST" "${UI_YELLOW:-}" "${UI_RESET:-}"
  elif [ "$UPDATE_LATEST" = "$WG_MANAGER_VERSION" ]; then
    printf 'Latest version:  %s  %s[Up to date]%s\n' \
      "$UPDATE_LATEST" "${UI_GREEN:-}" "${UI_RESET:-}"
  else
    printf 'Latest version:  %s  (installed version is newer)\n' "$UPDATE_LATEST"
  fi
}
update_backup_current() {
  mkdir -p "$UPDATE_BACKUPS" || return 1
  chmod 700 "$UPDATE_BACKUPS" || return 1
  ub_time=$(date +%Y%m%d-%H%M%S)
  ub_file="$UPDATE_BACKUPS/$ub_time-v$WG_MANAGER_VERSION-$$.sh"
  cp -p "$SELF" "$ub_file" || return 1
  chmod 700 "$ub_file" || return 1
  printf '%s\n' "$ub_file"
}
update_apply_file() {
  # Caller has validated script and checksum. Stage on the SAME JFFS
  # filesystem, then rename atomically. Do not alter client data or history.
  ua_source=$1
  ua_dir="/jffs/scripts/.wg-manager-install.$$"
  (umask 077; mkdir "$ua_dir") || { err 'Cannot create update staging directory.'; return 1; }
  # Always use /bin/sh for validation: /usr/sbin/sh may be an ASUS utility.
  if ! cp "$ua_source" "$ua_dir/wg-manager.sh" ||
     ! chmod 700 "$ua_dir/wg-manager.sh" ||
     ! /bin/sh -n "$ua_dir/wg-manager.sh"; then
    rm -rf "$ua_dir"; return 1
  fi
  if ! mv "$ua_dir/wg-manager.sh" "$SELF"; then
    rm -rf "$ua_dir"; return 1
  fi
  rmdir "$ua_dir" 2>/dev/null || :
  return 0
}
# SHA-256 tools differ between ASUSWRT-Merlin models: some have no
# sha256sum executable, but do have a BusyBox applet or firmware OpenSSL.
# Never downgrade to MD5/SHA-1 or skip checksum verification.
update_normalize_sha256() {
  uns_hash=$1
  [ "${#uns_hash}" -eq 64 ] || return 1
  case "$uns_hash" in *[!0123456789abcdefABCDEF]*) return 1;; esac
  printf '%s\n' "$uns_hash" | tr 'ABCDEF' 'abcdef'
}
update_file_sha256() {
  ufs_file=$1
  [ -f "$ufs_file" ] || return 1
  if has_bin sha256sum; then
    ufs_output=$(sha256sum "$ufs_file" 2>/dev/null) && {
      ufs_hash=${ufs_output%% *}
      update_normalize_sha256 "$ufs_hash" && return 0
    }
  fi
  if has_bin busybox; then
    ufs_output=$(busybox sha256sum "$ufs_file" 2>/dev/null) && {
      ufs_hash=${ufs_output%% *}
      update_normalize_sha256 "$ufs_hash" && return 0
    }
  fi
  if has_bin openssl; then
    ufs_output=$(openssl dgst -sha256 "$ufs_file" 2>/dev/null) && {
      ufs_hash=${ufs_output##* }
      update_normalize_sha256 "$ufs_hash" && return 0
    }
  fi
  return 1
}
update_install() {
  update_file_sha256 "$SELF" >/dev/null || {
    err 'No working SHA-256 verifier found (sha256sum, BusyBox or OpenSSL required).'
    return 1
  }
  warning 'A new release will replace the manager script, not router or client data.'
  # Always perform a fresh release check immediately before installation.
  ui_heading 'Checking GitHub for the latest stable release...'
  if ! update_check y; then
    err 'Could not verify the latest release. Keeping the installed version.'
    return 1
  fi
  if ! update_newer "$UPDATE_LATEST" "$WG_MANAGER_VERSION"; then
    success "No update needed (installed: $WG_MANAGER_VERSION; latest: $UPDATE_LATEST)."
    return 0
  fi
  ui_heading "Update WG Manager: $WG_MANAGER_VERSION -> $UPDATE_LATEST"
  ud_temp=$(make_temp_dir wgm-update-download) || return 1
  ud_tag="v$UPDATE_LATEST"
  ud_base="https://github.com/$UPDATE_REPO/releases/download/$ud_tag"
  # Pin the downloaded files to the SAME tag that was just checked, avoiding
  # releases/latest changing partway through an update operation.
  if ! update_fetch "$ud_base/update-info.txt" "$ud_temp/manifest" ||
     ! update_parse_manifest "$ud_temp/manifest" ||
     [ "$UM_VERSION" != "$UPDATE_LATEST" ]; then
    err 'Could not download/validate this version’s manifest.'
    rm -rf "$ud_temp"; return 1
  fi
  ud_hash=$UM_HASH
  if ! update_fetch "$ud_base/wg-manager.sh" "$ud_temp/wg-manager.sh"; then
    err 'Download failed. Installed script is unchanged.'
    rm -rf "$ud_temp"; return 1
  fi
  ud_actual=$(update_file_sha256 "$ud_temp/wg-manager.sh") || {
    err 'SHA-256 verification failed: no working verifier. Update cancelled.'
    rm -rf "$ud_temp"; return 1
  }
  ud_expected=$(update_normalize_sha256 "$ud_hash") || {
    err 'Invalid SHA-256 digest in release manifest. Update cancelled.'
    rm -rf "$ud_temp"; return 1
  }
  if [ "$ud_actual" != "$ud_expected" ]; then
    err 'SHA-256 mismatch. Update cancelled.'
    rm -rf "$ud_temp"; return 1
  fi
  ud_script_version=$(sed -n 's/^WG_MANAGER_VERSION=//p' "$ud_temp/wg-manager.sh" | sed -n '1p')
  if [ "$ud_script_version" != "$UPDATE_LATEST" ] || ! /bin/sh -n "$ud_temp/wg-manager.sh"; then
    err 'New script version or syntax verification failed.'
    rm -rf "$ud_temp"; return 1
  fi
  # Release notes are nonessential: failure to retrieve them cannot cause an
  # installation to proceed without explicit consent.
  if update_fetch "$ud_base/README-CHANGELOG.txt" "$ud_temp/changelog"; then
    ui_heading 'Release notes:'
    sed -n '1,50p' "$ud_temp/changelog"
  else
    warning 'Release notes unavailable; consult the GitHub release page.'
  fi
  ask 'Install this update? [y/n, Enter = n, m = menu]: '
  if is_back "$ANSWER"; then rm -rf "$ud_temp"; return 2; fi
  if ! yes "$ANSWER"; then rm -rf "$ud_temp"; say 'Update cancelled.'; return 0; fi
  ud_backup=$(update_backup_current) || {
    rm -rf "$ud_temp"; err 'Backup failed. Script was not replaced.'; return 1;
  }
  if ! update_apply_file "$ud_temp/wg-manager.sh"; then
    err "Installation failed; old executable remains. Backup: $ud_backup"
    rm -rf "$ud_temp"; return 1
  fi
  rm -rf "$ud_temp"
  success "Updated WG Manager to v$UPDATE_LATEST. Backup: $ud_backup"
  say 'Restarting WG Manager without rebooting or restarting WireGuard...'
  exec "$SELF"
}
update_list_backups() {
  ub_idx=0
  : > "$UPDATE_BACKUP_INDEX" || return 1
  for ub_path in $(
    for ub_match in "$UPDATE_BACKUPS"/*.sh; do
      [ -f "$ub_match" ] && printf '%s\n' "$ub_match"
    done | sort -r
  ); do
    ub_idx=$((ub_idx+1))
    [ "$ub_idx" -le 20 ] || break
    printf '%2s) %s\n' "$ub_idx" "${ub_path##*/}"
    printf '%s|%s\n' "$ub_idx" "$ub_path" >> "$UPDATE_BACKUP_INDEX"
  done
  [ "$ub_idx" -gt 0 ] || say '(no saved script versions)'
  [ "$ub_idx" -gt 0 ]
}
update_rollback() {
  ui_heading 'Available WG Manager script backups:'
  if ! update_list_backups; then return 0; fi
  ask 'Backup number to restore [m = menu]: '
  is_back "$ANSWER" && return 2
  case "$ANSWER" in ''|*[!0-9]*) err 'Select a numeric backup ID.'; return 1;; esac
  ur_path=$(awk -F '|' -v n="$ANSWER" '$1==n {print $2;exit}' "$UPDATE_BACKUP_INDEX")
  [ -f "$ur_path" ] || { err 'Backup not found.'; return 1; }
  ur_version=$(sed -n 's/^WG_MANAGER_VERSION=//p' "$ur_path" | sed -n '1p')
  if ! valid_update_version "$ur_version" || ! /bin/sh -n "$ur_path"; then
    err 'Backup is not a valid WG Manager version or has shell syntax errors.'
    return 1
  fi
  warning "Restoring WG Manager script v$ur_version (client data will not be changed)."
  ask 'Restore selected script? [y/n, Enter = n, m = menu]: '
  is_back "$ANSWER" && return 2
  yes "$ANSWER" || { say 'Rollback cancelled.'; return 0; }
  ur_safety=$(update_backup_current) || { err 'Unable to safeguard current script.'; return 1; }
  if ! update_apply_file "$ur_path"; then
    err "Rollback failed. Current script safeguarded: $ur_safety"
    return 1
  fi
  success "Rolled back to v$ur_version. Previous version saved: $ur_safety"
  exec "$SELF"
}
update_menu() {
  while :; do
    ui_heading 'Update WG Manager'
    printf 'Installed: %s\n' "$WG_MANAGER_VERSION"
    update_version_line
    ui_rule
    ui_menu_item 1 'Check installed and latest versions'
    ui_menu_item 2 'Update WG Manager'
    ui_menu_item 3 'Roll back to a previous version'
    ask 'Select [1-3, m = menu]: '
    case "$ANSWER" in
      1) if update_check y; then update_version_line; else warning 'Version check failed (offline or GitHub unavailable).'; fi ;;
      2) update_install || : ;;
      3) update_rollback || : ;;
      m|M) return 2 ;;
      *) err 'Select 1, 2, 3 or m.' ;;
    esac
  done
}

INDEXFILE=/tmp/wg-manager-client-index.$$
STATUSFILE=/tmp/wg-manager-handshakes.$$
ENDPOINTFILE=/tmp/wg-manager-endpoints.$$
TRANSFERFILE=/tmp/wg-manager-transfer.$$
STATUS_GUI_RENDER=/tmp/wg-manager-status-gui.$$
STATUS_EXTRA_RENDER=/tmp/wg-manager-status-extra.$$
UPDATE_BACKUP_INDEX=/tmp/wg-manager-update-backups.$$
trap 'rm -f "$INDEXFILE" "$STATUSFILE" "$ENDPOINTFILE" "$TRANSFERFILE" "$STATUS_GUI_RENDER" "$STATUS_EXTRA_RENDER" "$UPDATE_BACKUP_INDEX"' 0
trap 'exit 130' 2
trap 'exit 143' 15

ui_init
# Version checks only happen on the interactive menu. Successful results are
# cached for 12 hours, with a 30-minute backoff on network errors.
while :; do
  update_check n || :
  clear_screen
  printf '\n'
  ui_menu_rule
  printf '%sWG Manager v%s%s\n' "${UI_CYAN:-}" "$WG_MANAGER_VERSION" "${UI_RESET:-}"
  ui_menu_rule
  printf 'Router:           %s\n' "$(nvram get productid)"
  printf 'Firmware:         %s\n' "$(firmware_version)"
  printf 'Server:           %s\n' "$IFACE"
  printf 'Server VPN IPv4:  %s\n' "$SERVER_IP"
  printf '\n'
  update_version_line
  ui_menu_rule
  ui_menu_item 1 'List clients / view or export configuration'
  ui_menu_item 2 'Add a new client'
  ui_menu_item 3 'Modify an existing client'
  ui_menu_item 4 'Delete a client'
  ui_menu_item 5 'Connection status'
  printf '\n'
  ui_menu_item 6 'Backup and restore'
  ui_menu_item 7 'Update WG Manager'
  printf '\n'
  ui_menu_item 0 'Exit'
  ui_menu_rule
  ask 'Select [0-7]: '
  case "$ANSWER" in
    1) show_config; rc=$?;;
    2) add_client; rc=$?;;
    3) modify_client; rc=$?;;
    4) delete_client; rc=$?;;
    5) connection_status; rc=$?;;
    6) backup_restore_menu; rc=$?;;
    7) update_menu; rc=$?;;
    0) exit 0;;
    *) err 'Choose 0 through 7.'; rc=2;;
  esac
  [ "$rc" = 2 ] && continue
  pause
done
