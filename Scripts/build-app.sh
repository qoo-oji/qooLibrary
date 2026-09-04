#!/bin/bash
#
# アプリターゲットを**手元で**ビルドする唯一の入口。
#
# ## なぜスクリプトにするか
# `ci.yml` の xcodebuild は署名を上書きしている——
#   CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
# これは **CI に証明書が無いから**の措置で、手元で使ってはならない。
# 使うとアドホック署名になり、指定要件が `cdhash H"…"` に落ちるため
# **再ビルドのたびに TCC から見て別のアプリになる**——写真・ミュージック・
# ダウンロード等の許可が失効し、起動のたびに許可ダイアログが出る。
#
# **2026-09-04 に実際にこれをやった。** CI の 1 行をそのまま手元のビルドへ
# 写し、起動確認でダウンロードフォルダの許可ダイアログを利用者へ出した
# （tccd のログに `Failed to match existing code requirement for subject
# com.qoolibrary.app` → `AUTHREQ_PROMPTING` として残っている）。
# CLAUDE.md には「CI 用の上書きである」と書いてあったが、**書いてある注意は
# 新しい作業に自動では適用されない**——だからコマンドのほうを 1 つにする。
#
# ## 使い方
#   Scripts/build-app.sh              # Debug
#   Scripts/build-app.sh Release
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"

command -v xcodegen >/dev/null || { echo "xcodegen が要ります: brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

xcodebuild -project qooLibrary.xcodeproj -scheme qooLibraryApp \
           -configuration "$CONFIG" build

APP="$(xcodebuild -project qooLibrary.xcodeproj -scheme qooLibraryApp \
        -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/qooLibrary.app"

# **署名を検査する。** ここが落ちるのは「CI 用の上書きを手元で使った」か
# 「証明書が無い」ときで、どちらも起動すると利用者へ許可ダイアログを出す。
SIG="$(codesign -dv "$APP" 2>&1 || true)"
if grep -q "Signature=adhoc" <<<"$SIG"; then
    cat >&2 <<'MSG'

  ✗ アドホック署名になっています。

    このまま起動すると、TCC から見て「別のアプリ」になるため、
    写真・ミュージック・ダウンロード等の許可ダイアログが出ます。

    原因はたいてい CI 用の上書きを手元で使ったこと:
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
    これは ci.yml だけのものです。手元では引数を付けずにこの
    スクリプトを使ってください。

    証明書そのものが無い場合は、Xcode の Settings → Accounts で
    Apple Development の証明書を用意してください
    （project.yml の DEVELOPMENT_TEAM は 2FF822GHRW）。

MSG
    exit 1
fi

echo "$SIG" | grep -E "TeamIdentifier|Identifier=" >&2
echo "✓ $CONFIG ビルド完了・署名 OK: $APP" >&2
