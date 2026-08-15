#!/bin/sh
#
# 実機検証用の使い捨てボリュームを作る／片付ける。
#
# **ホームフォルダや Macintosh HD を検証に使わないため**のもの
# [ユーザー指示]。それらを触ると権限ダイアログが繰り返し出て、
# ユーザーの作業を止めてしまう（CLAUDE.md「実機を自動操作で検証するときの
# 落とし穴」参照）。
#
#   Scripts/verification-volume.sh create [name] [size]  # 作ってマウントし、パスを出力
#   Scripts/verification-volume.sh destroy [name]        # アンマウントして削除
#
# size は hdiutil の書式（既定 30m）。別ボリューム間のコピーで進捗・キャンセルを
# 試すときは、クローンが効かない分だけ時間がかかる大きさが要る（例: 2g）。
#
# `create` は中に検証用のフォルダ階層（aaa/child1, aaa/child2, bbb, ccc）と
# ファイルを 1 つ置く。ツリーの展開・並び・キーボード移動を試すのに足りる
# 最小限の形。
set -eu

name="${2:-QooVerify}"
size="${3:-30m}"
image="${TMPDIR:-/tmp}/${name}.dmg"

case "${1:-}" in
create)
    if [ -d "/Volumes/${name}" ]; then
        echo "already mounted: /Volumes/${name}" >&2
        exit 1
    fi
    rm -f "$image"
    # `-nobrowse` は付けない。付けるとボリュームが hidden 扱いになり、
    # `mountedVolumeURLs(options: [.skipHiddenVolumes])` を使うアプリの
    # フォルダツリーに現れない（実測で一度これに引っかかった）。
    hdiutil create -size "$size" -fs APFS -volname "$name" -o "$image" -quiet
    mount_point=$(hdiutil attach "$image" | grep -o '/Volumes/.*' | tail -1)
    mkdir -p "$mount_point/aaa/child1" "$mount_point/aaa/child2" "$mount_point/bbb" "$mount_point/ccc"
    printf 'sample\n' > "$mount_point/メモ.txt"
    echo "$mount_point"
    ;;
destroy)
    hdiutil detach "/Volumes/${name}" -quiet 2>/dev/null || true
    rm -f "$image"
    echo "removed: ${name}"
    ;;
*)
    echo "usage: $0 {create|destroy} [name]" >&2
    exit 2
    ;;
esac
