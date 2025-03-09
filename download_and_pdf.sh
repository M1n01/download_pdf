#!/bin/bash
# 使い方: ./document_pdf.sh <base_url>
# 例: ./document_pdf.sh https://nextjs.org/docs/app
# 単一URLをPDFに変換するスクリプト（デフォルト）
# または、指定したURLのサイトマップからサブディレクトリを取得し、PDFに変換する

set -e  # エラー発生時に停止
trap 'echo "スクリプトが中断されました"; cleanup' INT TERM EXIT

# 一時ファイルのクリーンアップ
cleanup() {
    if [ "$DEBUG_MODE" = false ]; then
        echo "一時ファイルをクリーンアップしています..."
        rm -f "$TEMP_SITEMAP" "$TEMP_URLS" 2>/dev/null
    else
        echo "デバッグモード: 一時ファイルが保持されています:"
        echo "- $TEMP_SITEMAP"
        echo "- $TEMP_URLS"
    fi
}

#####################################
# step0. グローバル変数の設定
#####################################
DEBUG_MODE=false
TEMP_SITEMAP="sitemap.xml"
TEMP_URLS="urls.txt"
TIMEOUT_SEC=60
SINGLE_PAGE_MODE=true  # デフォルトを単一ページモードに変更

#####################################
# step1. 引数チェック
#####################################
show_help() {
    cat << EOF
使い方: $0 [オプション] <base_url>

オプション:
  -h, --help         このヘルプを表示
  -o, --output DIR   PDFの出力先ディレクトリを指定 (デフォルト: $HOME/Downloads/<ドメイン名>)
  -d, --debug        デバッグモード（一時ファイルを保持）
  -s, --single       単一ページモード（指定されたURLのみをPDFに変換）[デフォルト]
  -m, --multi        複数ページモード（サイトマップから複数ページを変換）

例:
  $0 https://nextjs.org/docs/app/start  # 単一ページのみPDF化（デフォルト）
  $0 --multi https://nextjs.org/docs/app # サイトマップから全ページを取得しPDF化
  $0 --output ./docs_pdf https://nextjs.org/docs/app/start
EOF
    exit 0
}

# コマンドライン引数の解析
BASE_URL=""
OUTPUT_DIR=""
WAIT_TIME=0.1
MULTI_PAGE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -s|--single)
            SINGLE_PAGE_MODE=true
            shift
            ;;
        -m|--multi)
            SINGLE_PAGE_MODE=false
            MULTI_PAGE_MODE=true
            shift
            ;;
        -w|--wait)
            WAIT_TIME="$2"
            shift 2
            ;;
        -*)
            echo "不明なオプション: $1"
            show_help
            ;;
        *)
            BASE_URL="$1"
            shift
            ;;
    esac
done

# ベースURLのチェック
if [ -z "$BASE_URL" ]; then
    echo "エラー: ベースURLが指定されていません。"
    show_help
fi

# URLの正規化（末尾のスラッシュを削除）
BASE_URL=${BASE_URL%/}

# ドメイン名を抽出
DOMAIN=$(echo "$BASE_URL" | sed -E 's#https?://([^/]+).*#\1#')

#####################################
# step2. 必要なコマンドのチェック
#####################################
echo "必要なツールのチェックを開始します。"

check_command() {
    local cmd=$1
    local desc=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "エラー: $cmd ($desc) がインストールされていません。"
        return 1
    else
        echo "✓ $cmd: インストール済み ($desc)"
        return 0
    fi
}

# 必須コマンドのチェック
MISSING_TOOLS=0

check_command "curl" "URLからデータを転送するツール" || MISSING_TOOLS=$((MISSING_TOOLS+1))
check_command "grep" "テキストパターンを検索するツール" || MISSING_TOOLS=$((MISSING_TOOLS+1))
check_command "sed" "テキストストリームを変換・解析するツール" || MISSING_TOOLS=$((MISSING_TOOLS+1))
check_command "awk" "テキスト処理ツール" || MISSING_TOOLS=$((MISSING_TOOLS+1))

# Google Chromeの検出（複数の可能性のあるパスをチェック）
CHROME_PATHS=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"  # macOS
    "/usr/bin/google-chrome"  # Linux
    "/usr/bin/google-chrome-stable"  # Linux alternative
    "/c/Program Files/Google/Chrome/Application/chrome.exe"  # Windows
    "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"  # Windows 32bit
)

CHROME_PATH=""
for path in "${CHROME_PATHS[@]}"; do
    if [ -x "$path" ]; then
        CHROME_PATH="$path"
        break
    fi
done

if [ -z "$CHROME_PATH" ]; then
    echo "エラー: Google Chrome が見つかりません。"
    MISSING_TOOLS=$((MISSING_TOOLS+1))
    echo "Google Chrome のインストール方法:"
    echo "  macOS: https://www.google.com/chrome/ からダウンロード"
    echo "  Linux: sudo apt install google-chrome-stable"
else
    echo "✓ Google Chrome: 発見 ($CHROME_PATH)"
fi

# タイムアウトコマンドのチェック
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
    echo "✓ タイムアウトコマンド: GNU timeout が利用可能"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
    echo "✓ タイムアウトコマンド: gtimeout が利用可能"
else
    echo "! タイムアウトコマンドが見つかりません - 代替手段を使用します"
    # 簡易タイムアウト関数の定義
    timeout_function() {
        local timeout_sec=$1
        shift
        (
            eval "$@" &
            child=$!
            
            # 指定秒数後に子プロセスを終了
            (
                sleep "$timeout_sec"
                kill $child 2>/dev/null
            ) &
            timeout_watcher=$!
            
            # 子プロセスの終了を待つ
            wait $child
            kill $timeout_watcher 2>/dev/null
        )
    }
    TIMEOUT_CMD="timeout_function"
fi

# 必須コマンドが不足している場合は終了
if [ $MISSING_TOOLS -gt 0 ]; then
    echo "エラー: $MISSING_TOOLS 個のツールがインストールされていません。"
    echo "必要なツールをインストール後、再度実行してください。"
    exit 1
fi

#####################################
# step3. 出力ディレクトリの設定
#####################################
# デフォルトの出力ディレクトリ設定
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$HOME/Downloads/$DOMAIN"
fi

# 対話モードでダウンロード先を確認
if [ -t 0 ]; then  # 標準入力がターミナルからの場合
    read -p "PDFの出力先ディレクトリ [$OUTPUT_DIR]: " output_choice
    if [ -n "$output_choice" ]; then
        OUTPUT_DIR="$output_choice"
    fi
fi

# ディレクトリ作成
mkdir -p "$OUTPUT_DIR"
echo "PDFの出力先: $OUTPUT_DIR"

#####################################
# step4. PDF変換関数
#####################################
# PDF変換関数（タイムアウト処理を含む）
convert_to_pdf() {
    local url="$1"
    local output_path="$2"
    
    if [ "$TIMEOUT_CMD" = "timeout_function" ]; then
        # 簡易タイムアウト関数を使用
        timeout_function "$TIMEOUT_SEC" "$CHROME_PATH --headless --disable-gpu --print-to-pdf=\"$output_path\" \"$url\" 2>/dev/null"
    else
        # 通常のタイムアウトコマンドを使用
        $TIMEOUT_CMD "$TIMEOUT_SEC" "$CHROME_PATH" --headless --disable-gpu --print-to-pdf="$output_path" "$url" 2>/dev/null
    fi
    
    return $?
}

#####################################
# step5. 単一ページモードの処理
#####################################
if [ "$SINGLE_PAGE_MODE" = true ]; then
    echo "単一ページモード: $BASE_URL をPDF化します"
    
    # ファイル名生成（URLからパスを抽出、スラッシュを_に置換）
    filename=$(echo "$BASE_URL" | sed "s|https://||" | sed "s|http://||" | sed 's/[\/\?&=]/_/g').pdf
    output_path="$OUTPUT_DIR/$filename"
    
    echo "PDF化中: $BASE_URL → $output_path"
    if convert_to_pdf "$BASE_URL" "$output_path"; then
        echo "✓ PDF作成成功: $output_path"
        exit 0
    else
        echo "✗ PDF作成失敗: $BASE_URL"
        exit 1
    fi
fi

#####################################
# step6. サイトマップの確認
#####################################
echo "サイトマップをチェック中: $BASE_URL/sitemap.xml"

# サイトマップのURLを生成
SITEMAP_URL="$BASE_URL/sitemap.xml"

# サイトマップが存在するかチェック
if ! curl -s --head "$SITEMAP_URL" | grep -q "200 OK"; then
    # ドメインのルートでもチェック
    SITEMAP_URL="https://$DOMAIN/sitemap.xml"
    echo "サブディレクトリにサイトマップが見つかりません。ドメインルートをチェック: $SITEMAP_URL"
    
    if ! curl -s --head "$SITEMAP_URL" | grep -q "200"; then
        echo "エラー: サイトマップが見つかりません。処理を終了します。"
        exit 1
    fi
fi

# サイトマップをダウンロード
echo "サイトマップを発見しました。ダウンロード中..."
if ! curl -s "$SITEMAP_URL" -o "$TEMP_SITEMAP"; then
    echo "エラー: サイトマップのダウンロードに失敗しました。"
    exit 1
fi

#####################################
# step7. サイトマップからURLを取得
#####################################
echo "サイトマップから $BASE_URL のサブディレクトリのURLを取得しています..."

# URLを抽出して保存（grep -P のサポートを確認）
if grep --help 2>&1 | grep -q -- "-P, --perl-regexp"; then
    # Perl正規表現サポートがある場合
    grep -oP "(?<=<loc>)[^<]+" "$TEMP_SITEMAP" | grep "^$BASE_URL" > "$TEMP_URLS"
else
    # macOS/BSD互換の方法（awk使用）
    awk -F'[<>]' '/<loc>/ {print $3}' "$TEMP_SITEMAP" | grep "^$BASE_URL" > "$TEMP_URLS"
fi

# URLが取得できたか確認
URL_COUNT=$(wc -l < "$TEMP_URLS")
if [ "$URL_COUNT" -eq 0 ]; then
    echo "エラー: $BASE_URL のサブディレクトリのURLが見つかりませんでした。"
    exit 1
fi

echo "合計 $URL_COUNT 件のURLを取得しました。"

#####################################
# step8. URLからPDFを生成
#####################################
echo "PDFの生成を開始します..."

COUNTER=0
SUCCESS=0
FAILED=0
START_TIME=$(date +%s)

while IFS= read -r url; do
    COUNTER=$((COUNTER + 1))
    
    # ファイル名生成（URLからパスを抽出、スラッシュを_に置換）
    filename=$(echo "$url" | sed "s|$BASE_URL/||" | sed 's/[\/\?&=]/_/g').pdf
    output_path="$OUTPUT_DIR/$filename"
    
    echo "[$COUNTER/$URL_COUNT] 処理中: $url"
    
    # PDF変換を実行
    echo "PDF化中: $url → $output_path"
    if convert_to_pdf "$url" "$output_path"; then
        echo "✓ PDF作成成功: $output_path"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "✗ PDF作成失敗: $url"
        FAILED=$((FAILED + 1))
        # 続行するかの確認
        if [ -t 0 ]; then  # 標準入力がターミナルからの場合
            read -p "続行しますか？ (y/n): " choice
            if [ "$choice" != "y" ]; then
                echo "ユーザーの要求により処理を中断します。"
                break
            fi
        fi
    fi
    
    # 進捗表示
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((COUNTER * 100 / URL_COUNT))
    
    echo "進捗: $PERCENT% 完了 ($COUNTER/$URL_COUNT) - 経過時間: ${ELAPSED}秒"
    
    # レート制限
    if [ "$COUNTER" -lt "$URL_COUNT" ]; then
        echo "次のURLを処理する前に ${WAIT_TIME}秒待機しています..."
        sleep "$WAIT_TIME"
    fi
done < "$TEMP_URLS"

#####################################
# step9. 結果の表示
#####################################
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo "==== 処理結果 ===="
echo "処理したURL: $COUNTER/$URL_COUNT"
echo "成功: $SUCCESS"
echo "失敗: $FAILED"
echo "所要時間: ${TOTAL_TIME}秒"
echo "PDFの出力先: $OUTPUT_DIR"

exit 0
