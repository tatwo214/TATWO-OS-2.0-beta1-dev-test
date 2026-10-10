#!/bin/bash
# tatwo-sandbox 加固：派進來的工作一律用沒有 sudo 的 work 帳號跑；work 不能連區網／主機（只准 DNS 與外網）。
set -e
useradd --create-home --shell /bin/bash work 2>/dev/null || true
gpasswd -d work sudo 2>/dev/null || true
if ! command -v nft >/dev/null || ! command -v python3 >/dev/null || ! command -v git >/dev/null; then
  apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y nftables python3 git >/dev/null
fi
UIDW=$(id -u work)
tee /etc/nftables.conf >/dev/null <<NFT
flush ruleset
table inet tatwo_sandbox {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid $UIDW ip daddr 127.0.0.53 udp dport 53 accept
    meta skuid $UIDW ip daddr 127.0.0.53 tcp dport 53 accept
    meta skuid $UIDW ip daddr 192.168.5.3 udp dport 53 accept
    meta skuid $UIDW ip daddr 192.168.5.3 tcp dport 53 accept
    meta skuid $UIDW ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8 } counter reject
    meta skuid $UIDW ip6 daddr { fc00::/7, fe80::/10, ::1 } counter reject
  }
}
NFT
systemctl enable --now nftables >/dev/null 2>&1
nft -f /etc/nftables.conf
loginctl enable-linger work
