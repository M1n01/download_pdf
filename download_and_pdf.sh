#!/bin/bash
# 使い方: ./download_and_pdf.sh <base_url>
# 例: ./download_and_pdf.sh https://nextjs.org/docs/app

set -e  # エラー発生時に停止
trap 'echo "スクリプトが中断されました"; cleanup' INT TERM EXIT

# 一時ファイルのクリーンアップ
cleanup() {
    echo "一時ファイルをクリーンアップしています..."
    rm -f sitemap.xml
    rm -f urls.txt
}

# デバッグモード
DEBUG=true

# ヘルプメッセージ表示
show_help() {
    cat << EOF
使い方: $0 [オプション] <base_url>

オプション:
  -h, --help         このヘルプを表示
  -o, --output DIR   PDFの出力先ディレクトリを指定 (デフォルト: Download)
  -a, --all          確認なしですべてのURLを処理
  -m, --max NUM      処理するURLの最大数を指定
  -d, --depth NUM    クロールする深さを指定 (デフォルト: 1)
  --debug            一時ファイルを保持（デバッグ用）
  --wait NUM         ページ間の待機時間（秒）

例:
  $0 https://nextjs.org/docs/app
  $0 --all --output nextjs_docs https://nextjs.org/docs/app
EOF
    exit 0
}

# ==== デフォルト設定 ====
OUTPUT_DIR="Download"
PROCESS_ALL=false
MAX_URLS=1000
CRAWL_DEPTH=1
WAIT_TIME=1

# ==== コマンドライン引数の解析 ====
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -a|--all)
            PROCESS_ALL=true
            shift
            ;;
        -m|--max)
            MAX_URLS="$2"
            shift 2
            ;;
        -d|--depth)
            CRAWL_DEPTH="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --wait)
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

# デバッグモードの場合、cleanup を無効化
if [ "$DEBUG" = true ]; then
    trap - INT TERM EXIT
    echo "デバッグモード: 一時ファイルは保持されます"
fi

# ==== ベースURLの指定チェック ====
if [ -z "$BASE_URL" ]; then
    echo "エラー: ベースURLが指定されていません。"
    show_help
fi

# ==== OS検出 ====
OS_TYPE="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS_TYPE="linux"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    OS_TYPE="windows"
fi
echo "検出されたOS: $OS_TYPE"

# ==== 必要なツールのチェック ====
declare -a TOOL_DESCRIPTIONS=(
    ["curl"]="URLからデータを転送するためのツール"
    ["grep"]="テキストパターンを検索するツール"
    ["sed"]="テキストストリームを変換・解析するツール"
    ["wget"]="ネットワーク経由でコンテンツを取得するツール"
    ["awk"]="テキスト処理のためのツール"
)

TOOLS=("curl" "grep" "sed" "wget" "awk")
MISSING_TOOLS=()

echo "必要なツールのチェックを開始します。"
for tool in "${TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    else
        echo "✓ $tool : インストール済み (${TOOL_DESCRIPTIONS[$tool]})"
    fi
done

# grepの拡張正規表現サポートチェック
GREP_PERL_SUPPORT=false
if grep --help 2>&1 | grep -q -- "-P, --perl-regexp"; then
    GREP_PERL_SUPPORT=true
    echo "✓ grep: Perl正規表現(-P)サポート有り"
else
    echo "! grep: Perl正規表現(-P)サポート無し - 代替手段を使用します"
fi

# タイムアウトコマンドのチェック
TIMEOUT_CMD=""
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
fi

# Chrome の検出 (複数の可能性のあるパスをチェック)
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
    echo "Google Chrome が見つかりません。"
    MISSING_TOOLS+=("Google Chrome")
else
    echo "✓ Google Chrome : 発見 ($CHROME_PATH)"
fi

# ツールが不足している場合は終了
if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "以下のツールがインストールされていません:"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    
    if [[ " ${MISSING_TOOLS[@]} " =~ " Google Chrome " ]]; then
        echo "Google Chrome のインストール方法:"
        echo "  macOS: https://www.google.com/chrome/ からダウンロード"
        echo "  Linux: sudo apt install google-chrome-stable"
        echo "  または brew install --cask google-chrome (macOS + Homebrew)"
    fi
    
    echo "必要なツールをインストール後、再度実行してください。"
    exit 1
fi

# ==== 出力先ディレクトリの設定 ====
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

# ==== URLの収集方法 ====

# macOS互換のXML解析関数
extract_urls_from_xml() {
    local xml_file=$1
    local base_url=$2
    local max_urls=$3
    
    if [ "$GREP_PERL_SUPPORT" = true ]; then
        # Perl正規表現サポートがある場合
        grep -oPm"$max_urls" "(?<=<loc>)[^<]+" "$xml_file" | grep "^$base_url"
    else
        # macOS/BSD互換の方法
        # awkを使ってXMLからURLを抽出
        awk -F'[<>]' '/<loc>/ {print $3}' "$xml_file" | grep "^$base_url" | head -n "$max_urls"
    fi
}

get_urls_from_sitemap() {
    local base_url="$1"
    local sitemap_url="${base_url%/}/sitemap.xml"
    echo "サイトマップをチェック: $sitemap_url"
    
    # サイトマップをダウンロード
    if curl -s --head "$sitemap_url" | grep -q "200 OK"; then
        echo "サイトマップを発見しました。ダウンロード中..."
        curl -s "$sitemap_url" -o sitemap.xml
        
        # URLを抽出して保存
        extract_urls_from_xml "sitemap.xml" "$base_url" "$MAX_URLS" > urls.txt
        
        if [ -s urls.txt ]; then
            echo "サイトマップから $(wc -l < urls.txt) 件のURLを取得しました。"
            return 0
        else
            echo "サイトマップに対象URLが含まれていません。"
        fi
    else
        echo "サイトマップが見つかりませんでした。"
    fi
    return 1
}

crawl_with_wget() {
    local base_url="$1"
    local depth="$CRAWL_DEPTH"
    local temp_dir="temp_crawl"
    
    echo "サイトをクロールしています (深さ: $depth)..."
    mkdir -p "$temp_dir"
    
    # wgetでクロール (ログは抑制)
    wget --spider --force-html -r -l "$depth" -P "$temp_dir" "$base_url" 2>&1 | \
        grep '^--' | awk '{ print $3 }' | grep -E "^$base_url" | sort | uniq > urls.txt
    
    # 一時ディレクトリを削除
    rm -rf "$temp_dir"
    
    if [ -s urls.txt ]; then
        echo "クロールから $(wc -l < urls.txt) 件のURLを取得しました。"
        return 0
    else
        echo "クロールでURLを取得できませんでした。"
        return 1
    fi
}

# robots.txtからサイトマップURLを取得
get_sitemap_from_robots() {
    local base_url="$1"
    local domain=$(echo "$base_url" | sed -E 's#https?://([^/]+).*#\1#')
    local robots_url="https://$domain/robots.txt"
    
    echo "robots.txtをチェック: $robots_url"
    local sitemap_url=$(curl -s "$robots_url" | grep -i "^Sitemap:" | head -n 1 | sed 's/^Sitemap://i' | tr -d ' ')
    
    if [ -n "$sitemap_url" ]; then
        echo "robots.txtからサイトマップを発見: $sitemap_url"
        curl -s "$sitemap_url" -o sitemap.xml
        
        # URLを抽出して保存
        extract_urls_from_xml "sitemap.xml" "$base_url" "$MAX_URLS" > urls.txt
        
        if [ -s urls.txt ]; then
            echo "サイトマップから $(wc -l < urls.txt) 件のURLを取得しました。"
            return 0
        fi
    else
        echo "robots.txtからサイトマップを見つけられませんでした。"
    fi
    return 1
}

# ==== メイン処理: URLの収集 ====
echo "サイト $BASE_URL からURLを収集します..."

# 各方法を順番に試す
if ! get_urls_from_sitemap "$BASE_URL"; then
    if ! get_sitemap_from_robots "$BASE_URL"; then
        if ! crawl_with_wget "$BASE_URL"; then
            echo "URLを収集できませんでした。処理を終了します。"
            exit 1
        fi
    fi
fi

# 処理するURLの数を制限
if [ "$(wc -l < urls.txt)" -gt "$MAX_URLS" ]; then
    echo "処理するURLを $MAX_URLS 件に制限します。"
    head -n "$MAX_URLS" urls.txt > urls.tmp
    mv urls.tmp urls.txt
fi

# ==== 変換前の確認 ====
TOTAL_URLS=$(wc -l < urls.txt)
echo "合計 $TOTAL_URLS 件のURLを処理します。"

if [ "$PROCESS_ALL" = false ]; then
    read -p "すべてのURLをPDF化しますか？ (y/n): " choice
    if [ "$choice" != "y" ]; then
        echo "URL毎に確認を行います。"
    else
        PROCESS_ALL=true
    fi
fi

# ==== 各URLを処理 ====
COUNTER=0
SUCCESS=0
FAILED=0
START_TIME=$(date +%s)

# PDF変換関数（タイムアウト処理を含む）
convert_to_pdf() {
    local url="$1"
    local output_path="$2"
    local timeout_sec=60
    
    if [ -n "$TIMEOUT_CMD" ]; then
        # タイムアウトコマンドが利用可能な場合
        $TIMEOUT_CMD $timeout_sec "$CHROME_PATH" --headless --disable-gpu --print-to-pdf="$output_path" "$url" 2>/dev/null
        return $?
    else
        # 簡易タイムアウト関数を使用
        timeout_function $timeout_sec "$CHROME_PATH --headless --disable-gpu --print-to-pdf=\"$output_path\" \"$url\" 2>/dev/null"
        return $?
    fi
}

while IFS= read -r url; do
    COUNTER=$((COUNTER + 1))
    
    # ファイル名生成
    filename=$(echo "$url" | sed 's/https\?:\/\///; s/[\/?&=]/_/g').pdf
    output_path="$OUTPUT_DIR/$filename"
    
    echo "[$COUNTER/$TOTAL_URLS] 処理中: $url"
    
    # HEADリクエストでContent-Lengthを取得
    header=$(curl -sI "$url")
    size=$(echo "$header" | grep -i "Content-Length:" | awk '{print $2}' | tr -d '\r')
    if [ -n "$size" ]; then
        # サイズをKBに変換
        size_kb=$((size / 1024))
        echo "推定サイズ: ${size} bytes (${size_kb} KB)"
    else
        echo "サイズ情報は取得できませんでした。"
    fi

    # ユーザーに確認（すべて処理するオプションがオフの場合）
    if [ "$PROCESS_ALL" = false ]; then
        read -p "このページをPDF化しますか？ (y/n/a/q - yes/no/all/quit): " choice
        case "$choice" in
            a)
                PROCESS_ALL=true
                ;;
            q)
                echo "ユーザーにより処理が中断されました。"
                break
                ;;
            n)
                echo "スキップします。"
                continue
                ;;
        esac
    fi

    echo "PDF化中: $url → $output_path"
    
    # タイムアウト処理付きでPDF変換
    if convert_to_pdf "$url" "$output_path"; then
        echo "✓ PDF作成成功: $output_path"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "✗ PDF作成失敗: $url"
        FAILED=$((FAILED + 1))
    fi
    
    # 進捗表示
    ELAPSED=$(($(date +%s) - START_TIME))
    PERCENT=$((COUNTER * 100 / TOTAL_URLS))
    echo "進捗: $PERCENT% 完了 ($COUNTER/$TOTAL_URLS) - 経過時間: ${ELAPSED}秒"
    
    # レート制限（サーバーに過度な負荷をかけないため）
    echo "次のURLを処理する前に ${WAIT_TIME}秒待機しています..."
    sleep "$WAIT_TIME"
done < urls.txt

# ==== 結果の表示 ====
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo "==== 処理結果 ===="
echo "処理したURL: $COUNTER/$TOTAL_URLS"
echo "成功: $SUCCESS"
echo "失敗: $FAILED"
echo "所要時間: ${TOTAL_TIME}秒"
echo "PDFの出力先: $OUTPUT_DIR"

# デバッグモードの表示
if [ "$DEBUG" = true ]; then
    echo "デバッグモード: 一時ファイルが保持されています:"
    echo "- sitemap.xml"
    echo "- urls.txt"
fi

# プログラム終了
exit 0
