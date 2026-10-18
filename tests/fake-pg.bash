# tests/fake-pg.bash — 假的宝塔 PostgreSQL：psql、pg_dump、pg_dumpall、pg_restore 记录调用、按状态目录作答。
# fake_pg <程序目录> <状态目录>
#   状态目录/db/<库>/tables      表数（恢复时 pg_restore 按 dump 里的 TABLE 条目写）
#   状态目录/role/<角色>          角色存在
#   状态目录/databases.tsv        备份时 pg_database 的查询结果（库名 属主 编码 排序规则 字符分类）
#   状态目录/globals.sql          备份时 pg_dumpall --globals-only 的输出
#   状态目录/src/<库>             备份时 pg_dump -Fc 输出的内容（PGDMP 一行，其后是 pg_restore --list 的条目）
#   状态目录/props-<库>           备份时「库本身的权限与设置」那条查询的结果（每行一条语句）
#   状态目录/down                 存在时连不上；down 里写数字 N 就是前 N 次连不上
#   状态目录/dump-fail-<库>       存在时 pg_dump 这个库失败
#   状态目录/no-ext-<扩展>        存在时本机没有这个扩展
#   状态目录/log                  调用与语句
# 能证明的只是脚本按什么顺序、带什么参数调了这些程序；真实 PostgreSQL 的行为测不到。
fake_pg() {
  local bin=$1 st=$2 p
  mkdir -p "$bin" "$st/db" "$st/role" "$st/src"
  cat > "$bin/fake-pg" <<EOF
#!/usr/bin/env bash
ST=$st
EOF
  cat >> "$bin/fake-pg" <<'EOF'
prog=$(basename "$0")
echo "$prog $*" >> "$ST/log"
down() {
  [ -e "$ST/down" ] || return 1
  local n; n=$(cat "$ST/down")
  [ -z "$n" ] && return 0
  [ "$n" -gt 0 ] || return 1
  echo $((n - 1)) > "$ST/down"
}
db="" q="" list="" file="" globals=0 stop=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|-p|-U|-AtF) shift 2 ;;          # -AtF 后面跟的是分隔符
    -v) [ "$2" = ON_ERROR_STOP=1 ] && stop=1; shift 2 ;;
    -d) db=$2; shift 2 ;;
    -c|-Atc|-qc) q=$2; shift 2 ;;
    --list) list=1; shift ;;
    --globals-only) globals=1; shift ;;
    -*) shift ;;
    *) file=$1; shift ;;
  esac
done
case "$prog" in
  pg_restore)
    if [ -n "$list" ]; then   # 真的 pg_restore --list 先打几行 ; 开头的头信息，空库也有
      [ "$(head -1 "$file")" = PGDMP ] || { echo 'pg_restore: error: input file does not appear to be a valid archive' >&2; exit 1; }
      printf '%s\n' ';' '; Archive created at 2026-10-18 20:00:00 UTC' ';'; tail -n +2 "$file"; exit 0
    fi
    down && { echo 'pg_restore: error: connection to server failed' >&2; exit 1; }
    in=$(cat)
    [ "$(head -1 <<<"$in")" = PGDMP ] || { echo 'pg_restore: error: input file does not appear to be a valid archive' >&2; exit 1; }
    mkdir -p "$ST/db/$db"
    awk '$4 == "TABLE" && $5 != "DATA"' <<<"$in" | wc -l > "$ST/db/$db/tables"
    echo "RESTORE $db" >> "$ST/log"; exit 0 ;;
esac
down && { echo 'psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: No such file or directory' >&2; exit 2; }
case "$prog" in
  pg_dumpall) [ "$globals" = 1 ] && cat "$ST/globals.sql"; exit 0 ;;
  pg_dump)
    [ -e "$ST/dump-fail-$db" ] && { echo "pg_dump: error: dump of $db failed" >&2; exit 1; }
    if [ -f "$ST/src/$db" ]; then cat "$ST/src/$db"; else printf 'PGDMP\n'; fi; exit 0 ;;
esac
# psql：-c 的语句，或从标准输入读的脚本
if [ -z "$q" ]; then
  while IFS= read -r l; do
    echo "SQL $l" >> "$ST/log"
    case "$l" in
      "CREATE ROLE "*) r=$(sed -E 's/^CREATE ROLE "?([^" ;]+).*/\1/' <<<"$l")
        if [ -e "$ST/role/$r" ]; then echo "ERROR:  role \"$r\" already exists" >&2; else touch "$ST/role/$r"; fi ;;
      *BROKEN*) echo "ERROR:  syntax error at or near \"BROKEN\"" >&2; [ "$stop" = 1 ] && exit 3 ;;
    esac
  done
  exit 0
fi
echo "SQL $q" >> "$ST/log"
case "$q" in
  "SELECT 1") echo 1 ;;
  "SHOW server_version") echo 17.11 ;;
  "SELECT rolname FROM pg_roles") ls "$ST/role" ;;
  *"FROM pg_database WHERE NOT datistemplate"*) cat "$ST/databases.tsv" ;;
  *"FROM pg_database WHERE datname"*) n=$(sed -E "s/.*datname = '([^']+)'.*/\1/" <<<"$q"); [ -d "$ST/db/$n" ] && echo 1 ;;
  *pg_available_extensions*) n=$(sed -E "s/.*name = '([^']+)'.*/\1/" <<<"$q"); [ -e "$ST/no-ext-$n" ] || echo 1 ;;
  *aclexplode*) n=$(grep -oE "datname = '[^']+'" <<<"$q" | head -1 | cut -d"'" -f2); cat "$ST/props-$n" 2>/dev/null ;;
  *information_schema.tables*) cat "$ST/db/$db/tables" 2>/dev/null || echo 0 ;;
  "CREATE DATABASE"*) n=$(sed -E 's/^CREATE DATABASE "([^"]+)".*/\1/' <<<"$q")
    [ -e "$ST/no-locale" ] && [[ $q == *LC_COLLATE* ]] && { echo 'ERROR:  invalid locale name' >&2; exit 1; }
    mkdir -p "$ST/db/$n"; echo 0 > "$ST/db/$n/tables" ;;
  "DROP DATABASE"*) n=$(sed -E 's/^DROP DATABASE (IF EXISTS )?"([^"]+)".*/\2/' <<<"$q"); rm -rf "${ST:?}/db/$n" ;;
  "DROP ROLE"*) n=$(sed -E 's/^DROP ROLE (IF EXISTS )?"([^"]+)".*/\2/' <<<"$q"); rm -f "$ST/role/$n" ;;
esac
exit 0
EOF
  chmod 755 "$bin/fake-pg"
  for p in psql pg_dump pg_dumpall pg_restore; do ln -sf fake-pg "$bin/$p"; done
}

# 一份 Open WebUI 那样的库的 dump：带 pgvector 扩展、两张表
pg_dump_body() {
  printf '%s\n' PGDMP \
    '5; 3079 16385 EXTENSION - vector ' \
    '215; 1259 16389 TABLE public auth openwebui' \
    '216; 1259 16390 TABLE public chat openwebui' \
    '3400; 0 16389 TABLE DATA public auth openwebui'
}
