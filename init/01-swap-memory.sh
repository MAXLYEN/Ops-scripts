#!/bin/bash
# init/01-swap-memory.sh — Swap 与内存参数
# VERSION: 1.0.0
#
# 按内存分档创建 swapfile，配置 swappiness 与脏页写回。
# 本目录的脚本刻意不依赖 lib/common.sh，理由见 00-precheck.sh 头部。

set -e
SWAPFILE=/swapfile
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }

echo "════════ 01 · Swap 与内存 ════════"
SKIP=0
if [ -f /proc/user_beancounters ] || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
  echo "⚠️  OpenVZ/LXC 容器，跳过 swap 创建"; SKIP=1
fi
FSTYPE=$(stat -f -c %T /)
case "$FSTYPE" in
  btrfs|zfs) echo "⚠️  $FSTYPE 需专门流程，跳过 swap 创建"; SKIP=1 ;;
  xfs)       echo "ℹ️  XFS：fallocate 的文件 swapon 会拒绝，将直接用 dd（较慢，正常）" ;;
esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if   [ "$MEM_MB" -le 2048 ]; then SWAP_MB=$((MEM_MB*2))
elif [ "$MEM_MB" -le 8192 ]; then SWAP_MB=$MEM_MB
else                              SWAP_MB=8192
fi
AVAIL_MB=$(df -Pm / | awk 'NR==2{print $4}')
MAX_MB=$((AVAIL_MB/2))
if [ "$SWAP_MB" -gt "$MAX_MB" ]; then
  SWAP_MB=$MAX_MB; echo "⚠️  磁盘受限，swap 缩减为 ${SWAP_MB}MB"
fi
if [ "$SWAP_MB" -lt 256 ]; then
  echo "⚠️  可用空间不足，跳过 swap"; SKIP=1
fi
echo "内存 ${MEM_MB}MB | 可用 ${AVAIL_MB}MB | 文件系统 $FSTYPE | 目标 swap ${SWAP_MB}MB"
echo

if [ "$SKIP" -eq 0 ]; then
  CURB=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null \
         | awk -v f="$SWAPFILE" '$1==f{print $2}' || true)
  if [ -n "$CURB" ] && [ "$((CURB/1048576))" -ge "$((SWAP_MB*9/10))" ] 2>/dev/null; then
    echo "→ 已存在合适大小的 swap（$((CURB/1048576))MB），跳过重建"
  else
    PRE_OK=0
    if findmnt --verify >/dev/null 2>&1; then
      PRE_OK=1
    else
      echo "⚠️  改动前 fstab 即不通过校验，本次仅保证不引入新问题"
    fi

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
      swapoff "$SWAPFILE" || { echo "❌ swapoff 失败，终止且未删除文件"; exit 1; }
    fi
    rm -f "$SWAPFILE"

    NEED_DD=1
    case "$FSTYPE" in
      xfs) echo "→ XFS，直接使用 dd" ;;
      *)
        if fallocate -l "${SWAP_MB}M" "$SWAPFILE" 2>/dev/null; then
          chmod 600 "$SWAPFILE"
          if mkswap "$SWAPFILE" >/dev/null 2>&1; then
            NEED_DD=0; echo "→ fallocate 创建成功"
          fi
        fi
        ;;
    esac
    if [ "$NEED_DD" -eq 1 ]; then
      rm -f "$SWAPFILE"
      dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_MB" status=progress
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE" >/dev/null
    fi
    swapon "$SWAPFILE" || { echo "❌ swapon 失败"; exit 1; }

    BK=/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)
    cp -a /etc/fstab "$BK"
    if grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
      echo "→ fstab 条目已存在"
    else
      printf '\n%s none swap sw,pri=10 0 0\n' "$SWAPFILE" >> /etc/fstab
      echo "→ 已写入 fstab（备份 $BK）"
    fi

    if findmnt --verify --verbose > /root/.fstab_verify.log 2>&1; then
      echo "✅ fstab 校验通过"
    elif [ "$PRE_OK" -eq 1 ]; then
      echo "❌ 校验失败，自动回滚"
      sed -n '1,30p' /root/.fstab_verify.log
      cp -a "$BK" /etc/fstab
    else
      echo "⚠️  仍不通过校验，但改动前也不通过，未回滚:"
      sed -n '1,30p' /root/.fstab_verify.log
    fi
  fi
fi

echo
if   [ "$MEM_MB" -le 2048 ]; then SW=60; DBG=$((64*1024*1024));  DT=$((256*1024*1024))
elif [ "$MEM_MB" -le 8192 ]; then SW=30; DBG=$((128*1024*1024)); DT=$((512*1024*1024))
else                              SW=10; DBG=$((256*1024*1024)); DT=$((1024*1024*1024))
fi
mkdir -p /etc/sysctl.d
rm -f /etc/sysctl.d/99-swap.conf /etc/sysctl.d/99-memory.conf
cat > /etc/sysctl.d/99-zz-memory.conf << INNER
# Memory tuning for ${MEM_MB}MB - $(date -u +%F)
# zz 前缀确保排在 Debian 自带的 99-sysctl.conf 之后
vm.swappiness = $SW
vm.vfs_cache_pressure = 100
# 绝对值优于百分比：大内存机器用 dirty_ratio 会堆积巨量脏页导致写回卡顿
# dirty_bytes 与 dirty_ratio 互斥，设置本项会使 ratio 显示为 0（正常）
vm.dirty_background_bytes = $DBG
vm.dirty_bytes = $DT
INNER
sysctl --system >/dev/null

MIS=""
for kv in "vm.swappiness=$SW" "vm.vfs_cache_pressure=100" \
          "vm.dirty_bytes=$DT" "vm.dirty_background_bytes=$DBG"; do
  k=${kv%%=*}; w=${kv#*=}
  [ "$(sysctl -n "$k" 2>/dev/null)" = "$w" ] || MIS="$MIS $k"
done

echo "════════ 结果 ════════"
swapon --show 2>/dev/null | sed 's/^/  /' || echo "  无 swap"
echo
free -h | sed 's/^/  /'
echo
for k in vm.swappiness vm.vfs_cache_pressure vm.dirty_bytes vm.dirty_background_bytes; do
  printf '  %-30s = %s\n' "$k" "$(sysctl -n "$k")"
done
echo
if [ -n "$MIS" ]; then
  echo "  ⚠️  以下参数未生效，覆盖来源:"
  for k in $MIS; do
    echo "    $k:"
    grep -rln "^[[:space:]]*$k" /etc/sysctl.conf /etc/sysctl.d/ \
      /run/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null | sed 's/^/      /'
  done
else
  echo "  ✅ 所有参数已确认生效"
fi
echo
echo "✅ 阶段 01 完成"
