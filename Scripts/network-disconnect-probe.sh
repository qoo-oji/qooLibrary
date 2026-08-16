#!/bin/bash
#
# ネットワーク共有を一時的に到達不能にして、切断時の挙動を測る。
#
#   sudo Scripts/network-disconnect-probe.sh /Volumes/<共有名>
#
# **何を確かめるためのものか**
# 8章 §8.11 の調査は「接続中」の状態に偏っていた。切断中にしか出ない事象が
# いくつも未検証のまま残っている:
#
#   NV-94  到達不能なパスを含む FSEventStreamCreate がブロックしないか
#   NV-93  マウント一覧での判定（載っていれば退避しない）が成立するか
#   —      切断時に実際に返る errno（PosixFailure の翻訳は文献ベースのまま）
#   NV-91  .withoutMounting でのブックマーク解決がどうなるか
#   F3     mmap されたページのフォルトが切断中に SIGBUS になるか（項目 12、
#          子プロセスで判定。CGPDFDocument はファイルを mmap する [実測]）
#
# これらは**1 回の遮断でまとめて確定する**。
#
# **安全のための作り**
#   - pf の本体ルールセットには触らない。/etc/pf.conf が既定で持つ
#     `anchor "com.apple/*"` の下に専用のアンカーを作って入れるだけ。
#   - pf の有効化は参照カウント付きの `pfctl -E` / `-X` を使う。ほかが
#     有効にしていても壊さない。
#   - trap で必ず解除する（失敗しても Ctrl-C でも）。最後に疎通を確かめる。
#   - 遮断している時間は 45 秒ほど。計測は並行に走らせて短くしてある。
#
# **なぜ「共有をアンマウントする」ではないのか**
# 知りたいのは「マウントされたまま相手が居ない」状態である。きれいに
# アンマウントするとマウント一覧から消えてしまい、NV-93 の判定
# （マウント一覧に無ければ退避しない）を確かめられない。

set -u

SHARE="${1:-}"
ANCHOR="com.apple/qooprobe"
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(mktemp -d)/probe"
PF_TOKEN=""

if [ -z "$SHARE" ]; then
  echo "使い方: sudo $0 /Volumes/<共有名>" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "root で実行してください:  sudo $0 $SHARE" >&2
  exit 1
fi
if [ ! -d "$SHARE" ]; then
  echo "$SHARE が見つかりません" >&2
  exit 1
fi

# 共有のマウント元からサーバのホスト名を取り、IP へ解決する。
# 例: //user@TS-664._smb._tcp.local/Private
MNT_FROM="$(mount | awk -v s="$SHARE" '$0 ~ " on " s " " {print $1}')"
HOST="$(echo "$MNT_FROM" | sed -E 's|^//||; s|^[^@]*@||; s|/.*$||')"
if [ -z "$HOST" ]; then
  echo "$SHARE のマウント元を判定できません（mount の出力: $MNT_FROM）" >&2
  exit 1
fi
# Bonjour で見つけた共有は `TS-664._smb._tcp.local` のような**サービス名**で
# マウントされる。これは名前解決できないので、サービス種別を落として
# `TS-664.local` に戻す（実測: 前者は解決できず、後者は解決できる）。
HOST_RESOLVABLE="$(echo "$HOST" | sed -E 's|\._[a-z]+\._[a-z]+\.local$|.local|')"
NAS_IP="$(dscacheutil -q host -a name "$HOST_RESOLVABLE" | awk '/^ip_address:/ {print $2; exit}')"
# それでも駄目なら、既に張られている接続の相手から取る（いちばん確実）。
if [ -z "$NAS_IP" ]; then
  NAS_IP="$(netstat -an -p tcp 2>/dev/null \
    | awk '/\.(445|139) +.*ESTABLISHED/ {print $5}' \
    | sed -E 's|\.[0-9]+$||' | sort -u | head -1)"
fi
if [ -z "$NAS_IP" ]; then
  echo "$HOST の IP を解決できません" >&2
  exit 1
fi
echo "対象: $SHARE  （マウント元 $MNT_FROM → $HOST_RESOLVABLE → $NAS_IP）"

restore() {
  echo ""
  echo "=== 後始末 ==="
  pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 && echo "  遮断ルールを削除しました"
  if [ -n "$PF_TOKEN" ]; then
    pfctl -X "$PF_TOKEN" >/dev/null 2>&1 && echo "  pf の参照を返しました（トークン $PF_TOKEN）"
  fi
  if ping -c 2 -t 3 "$NAS_IP" >/dev/null 2>&1; then
    echo "  疎通確認: $NAS_IP に到達できます ✅"
    "$BIN" cleanup "$SHARE" 2>/dev/null
  else
    echo "  ★疎通確認に失敗しました。手動で確認してください:"
    echo "     sudo pfctl -a $ANCHOR -F rules"
    echo "     sudo pfctl -s References"
  fi
  rm -rf "$(dirname "$BIN")"
}
trap restore EXIT INT TERM

echo "=== 計測プログラムを用意 ==="
xcrun swiftc -O "$DIR/network-disconnect-probe.swift" -o "$BIN" || exit 1

echo "=== 事前準備（接続したまま）==="
"$BIN" prepare "$SHARE" || exit 1

echo ""
echo "=== 遮断します ==="
PF_TOKEN="$(pfctl -E 2>&1 | awk '/Token/ {print $3}')"
echo "  pf を有効化（トークン ${PF_TOKEN:-取得できず}）"
printf 'block drop quick from any to %s\nblock drop quick from %s to any\n' "$NAS_IP" "$NAS_IP" \
  | pfctl -a "$ANCHOR" -f - 2>&1 | grep -v '^$' || true

if ping -c 2 -t 2 "$NAS_IP" >/dev/null 2>&1; then
  echo "  ★まだ到達できます。遮断が効いていないので中止します。"
  exit 1
fi
echo "  遮断を確認しました（ping が通らない）"

# mmap フォルト計測（項目 12）のため、書いたばかりのプローブファイルの
# ページをキャッシュから追い出す。キャッシュに居るとフォルトがネットワークへ
# 行かず、偽の「読めた」になる。
echo "  ディスクキャッシュを破棄します（purge）"
purge 2>/dev/null || true

echo ""
"$BIN" measure "$SHARE"

echo ""
echo "=== 遮断を解除します ==="
