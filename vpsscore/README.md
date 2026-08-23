# vpsscore — VPS 质量采集与横向对比

三个脚本串成一条链：**采集 → 汇总 → 打分**。

| 脚本 | 跑在哪 | 干什么 |
|---|---|---|
| `probe.sh` | 每台被评估的机器 | 采一份 JSON 到 `/var/lib/vpsscore/` |
| `collect.sh` | 汇总机（一台） | ssh 到各机重采、收集 JSON、自动打分 |
| `score.sh` | 汇总机 | 读一批 JSON，按角色权重打分并分组排名 |

`collect.sh` 和 `score.sh` **只装在汇总机一台上**。

## 日常用法

```bash
collect.sh -n            # 预演：只列出会连哪些机器
collect.sh -p            # 重采（线路/硬件）并打分，约 1.5 分钟/台
collect.sh -p --ipq      # 加深度 IP 质量检测，约 3 分钟/台
score.sh -r line ~/vpsscore-baseline    # 只看某一个榜
```

主机清单自动发现，优先级从高到低：命令行给的文件 → `/etc/ops-scripts/vps-hosts.txt`
→ `~/.vps-hosts.txt` → `~/.ssh/config` 的 Host 条目。走 ssh 别名时端口/IP/用户
全由 ssh 解析，不用在这里再维护一份。

新机器纳管：`opsget ops/setup-key-login <IP> <端口> <密码>`，成功后自动追加进清单。

## 三个榜

**line（线路质量）**：带宽 30、丢包 30、延迟 20、steal 10、虚拟化 5、CPU 5

**ip（IP 质量）**：流媒体 25、归属地一致性 20、风险评分 20、原生IP 15、
黑名单 12、风险标记 5、住宅属性 3 —— 需要 `--ipq` 采集，否则整榜为空

**web（建站）**：CPU 20、磁盘4K 20、内存 15、磁盘顺序 15、带宽 10、丢包 10、
steal 5、虚拟化 5 —— **只收 4C4G 以上的机器**，低配机在建站榜垫底是必然的，
列进去只会让榜变长、把真正该比较的那几台淹没

## 读榜的四条规则

**一、按地区分组，不跨区比。** 国内直连 400ms 对美西机正常、对香港机是灾难，
混在一张榜上比出的顺序没有意义。分组以 CDN 实测落地（`cdn_loc`）为准而非 IP 库
—— 实测反映流量实际走到哪，IP 库只是登记信息。同地区不足 3 台的归入「其它地区」，
只列绝对分不排名。

**二、看区间，不抠零点几分。** 48 和 50 没有实质区别，60 和 45 才有。

**三、覆盖率低于 50% 不给分。** 缺失项会被剔除并归一化，一台只测到硬件的机器
可能算出 95 分——那个数字被截图之后，旁边的警告不会跟着走。所以低覆盖率直接
显示「数据不足」。

**四、IP 榜是初筛，不是结论。** 见下。

## 这套工具测不出什么

这不是 bug 列表，是方法本身的边界。踩过的都在这里：

**持续限速。** 带宽是单次单点采样，测不出长期限速。曾有机器线路分 87.8 排第二，
实际用起来什么都干不了。

**稳定性与断链。** 探针只做一次瞬时采样，「6/6 稳定性」那节永远留空。需要
Komari 那类长期监控才能发现。曾有机器两榜都不错，实际经常断链。

**IP 的真实可用性。** IP 榜反映的是各风险库怎么看这个 IP。曾有机器 IPQuality
判「原生IP」、本表给 92.6 分排第二，但 ping0 / IPPure / iplark 三个站都判它是
广播 IP、风控 37-40%、bot 流量占 66%、适用场景全部不推荐——根源是七个库对它的
归属国给出 HK/SG/CN/US 四种判定。加入「归属地一致性」后它降到 77.3，但**这类
判断最终仍要靠实际使用体感**。

**结论：分数接近时（相差 10 分以内），以你用下来的感受为准。**
实测中使用体感三次推翻了分数，三次都是体感对。

## 采集依赖

探针需要：`ping dig curl python3 fio mtr`
`--ipq` 额外需要（IPQuality 自己的依赖）：`jq bc netcat dnsutils`

**`jq` 缺失最隐蔽**：IPQuality 会静默降级成 Lite 模式——风险评分、IP 类型、
五个数据库整节失效，而报告看起来仍然正常。探针 1.1.2 起会主动检查并拒绝 Lite
数据，但机器上还是应该把依赖装齐。

一次性检查全机群：

```bash
while IFS= read -r h <&3; do
  h=${h%%#*}; [ -n "$(echo $h)" ] || continue
  case "$h" in *:*) t=${h%:*}; p=${h##*:} ;; *) t=$h; p=22 ;; esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$p" "$t" '
    miss=""
    for c in ping dig curl python3 fio mtr jq bc; do
      command -v $c >/dev/null || miss="$miss $c"
    done
    [ -n "$miss" ] && echo "缺:$miss" || echo "齐全"' </dev/null 2>/dev/null \
  | sed "s|^|  $h: |"
done 3< ~/.vps-hosts.txt
```

## 数据清理

每采集一轮，每台新增一份 JSON 加一份 route.txt，跑几次就是几百个文件。

```bash
opsget ops/cleanup-tidy          # 预演
opsget ops/cleanup-tidy --apply  # 执行
```

第 8 节专管 vpsscore 产物：本机 `/var/lib/vpsscore` 留最新 2 份；汇总目录
`~/vpsscore-baseline` **按 IP 分组**各留 2 份——直接按时间排会把某几台的历史
全删光，而横向对比恰恰需要每台都有数据。

## 排查

**IP 榜全空**：这轮采集没带 `--ipq`。`score.sh` 只读每台最新那份，新数据会把
带 IP 质量的旧数据顶掉。重采时带上 `--ipq`。

**探针版本不一致告警**：装了 `opsget` 的机器从云端拉探针，没装的用汇总机的
`/usr/local/bin/probe.sh` 推送。两者不一致时同一轮会混用两个版本。
先 `opsget -i vpsscore/probe` 再重采。

**某台采集失败**：`collect.sh` 会打印该机的真实报错。常见是不是 root
且无免密 sudo（探针要写 `/var/lib/vpsscore`、读 `/proc/stat`）。

**某台数据一直是旧的**：1.2.2 之前 `collect.sh` 对汇总机本机只复制不重采，
本机数据会停在上次手动跑探针的时刻。升级到 1.2.2 以上即可。
