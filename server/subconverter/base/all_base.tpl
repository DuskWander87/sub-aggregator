{% if request.target == "clash" or request.target == "clashr" %}

port: {{ default(global.clash.http_port, "7890") }}
socks-port: {{ default(global.clash.socks_port, "7891") }}
allow-lan: {{ default(global.clash.allow_lan, "true") }}
mode: Rule
log-level: {{ default(global.clash.log_level, "info") }}
external-controller: {{ default(global.clash.external_controller, "127.0.0.1:9090") }}
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: strict
global-client-fingerprint: chrome

# 持久化策略组选择。Mihomo 默认 false，即每次 reload 都把 select 组重置为
# 第一项；配合 rename 去掉节点名里的流量后缀（名字必须稳定才能匹配回来），
# 更新订阅后才不会掉回组内第一项。
profile:
  store-selected: true

geodata-mode: true
geo-auto-update: true
geo-update-interval: 24
geox-url:
  geoip: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - "any:53"
    - "tcp://any:53"

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  respect-rules: true
  default-nameserver:
    - 119.29.29.29
    - 223.5.5.5
    - 114.114.114.114
  nameserver-policy:
    "geosite:cn,private,apple":
      - https://doh.pub/dns-query
      - https://dns.alidns.com/dns-query
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  direct-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  direct-nameserver-follow-policy: true
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.arpa"
    - "localhost.ptlogin2.qq.com"
    - "time.*.com"
    - "time.*.gov"
    - "time.*.edu.cn"
    - "time.*.apple.com"
    - "time-ios.apple.com"
    - "+.pool.ntp.org"
    - "ntp.*.com"
    - "ntp1.*.com"
    - "ntp2.*.com"
    - "ntp3.*.com"
    - "*.msftncsi.com"
    - "www.msftconnecttest.com"
    - "dns.msftncsi.com"
    - "+.push.apple.com"
    - "+.courier.push.apple.com"
    - "+.market.xiaomi.com"
    - "+.stun.*.*"
    - "+.stun.*.*.*"
    - "+.stun.*.*.*.*"
    - "+.srv.nintendo.net"
    - "+.stun.playstation.net"
    - "xbox.*.microsoft.com"
    - "+.xboxlive.com"
    - "+.battlenet.com.cn"
    - "+.battlenet.com"
    - "+.blzstatic.cn"
    - "lens.l.google.com"

{% if local.clash.new_field_name == "true" %}
proxies: ~
proxy-groups: ~
rules: ~
{% else %}
Proxy: ~
Proxy Group: ~
Rule: ~
{% endif %}

{% endif %}
