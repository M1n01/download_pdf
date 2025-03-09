# DLPDF 詳細使用ガイド

このドキュメントでは、`download_and_pdf.sh` スクリプトの詳細な使用方法を説明します。

## コマンド構文

```bash
./download_and_pdf.sh [オプション] <base_url>
```

`base_url` は処理を開始するウェブサイトのURLです。

## オプション一覧

| オプション | 省略形 | 説明 | デフォルト値 |
|-----------|--------|------|------------|
| `--help` | `-h` | ヘルプメッセージを表示して終了 | - |
| `--output DIR` | `-o DIR` | PDFファイルの出力先ディレクトリ | `Download` |
| `--all` | `-a` | 確認なしですべてのURLを処理 | `false` |
| `--max NUM` | `-m NUM` | 処理するURLの最大数 | `1000` |
| `--depth NUM` | `-d NUM` | クロールする深さ（レベル） | `1` |
| `--debug` | - | デバッグモード（一時ファイルを保持） | `false` |
| `--wait NUM` | - | ページ間の待機時間（秒） | `1` |

## オプションの詳細

### 出力先ディレクトリ (`--output`, `-o`)

PDFファイルの保存先を指定します。指定したディレクトリが存在しない場合は自動的に作成されます。

```bash
./download_and_pdf.sh --output docs_pdf https://example.com/docs
```

### すべて処理 (`--all`, `-a`)

このオプションを指定すると、各URLの処理前に確認を求めず、すべてのURLを自動的に処理します。大量のURLがある場合に便利です。

```bash
./download_and_pdf.sh --all https://example.com
```

### 最大URL数 (`--max`, `-m`)

処理するURLの最大数を制限します。サイトが非常に大きい場合や、テスト目的で少数のページだけを処理したい場合に便利です。

```bash
./download_and_pdf.sh --max 10 https://example.com
```

### クロール深さ (`--depth`, `-d`)

ウェブクローラーが追跡するリンクの深さを指定します。値が大きいほど、より多くのページが収集されます。

```bash
./download_and_pdf.sh --depth 3 https://example.com
```

### デバッグモード (`--debug`)

一時ファイル（sitemap.xml、urls.txt）を処理後も保持します。問題のトラブルシューティングに役立ちます。

```bash
./download_and_pdf.sh --debug https://example.com
```

### 待機時間 (`--wait`)

各ページの処理間の待機時間（秒）を指定します。サーバーに過度な負荷をかけないようにするために使用します。

```bash
./download_and_pdf.sh --wait 3 https://example.com
```

## 複数のオプションの組み合わせ

複数のオプションを組み合わせて使用できます：

```bash
./download_and_pdf.sh --all --max 50 --depth 2 --output my_docs --wait 2 https://example.com
```

上記の例では：
- 確認なしですべてのURLを処理 (`--all`)
- 最大50ページまで処理 (`--max 50`)
- クロール深さを2レベルに設定 (`--depth 2`)
- PDFを `my_docs` ディレクトリに保存 (`--output my_docs`)
- ページ処理間に2秒の待機時間を設定 (`--wait 2`)

## 対話モード

`--all` オプションを指定しない場合、スクリプトは各URLを処理する前に確認を求めます。

処理中に以下のオプションが表示されます：
- `y`：現在のURLを処理
- `n`：現在のURLをスキップ
- `a`：残りのすべてのURLを処理（それ以降の確認なし）
- `q`：処理を中止して終了

## 出力ファイル名

変換されたPDFファイルは、元のURLから生成された名前で保存されます。URLの特殊文字（`/`, `?`, `&`, `=` など）はアンダースコア (`_`) に置き換えられます。

例：
- URL: `https://example.com/docs/page.html`
- PDF名: `example.com_docs_page.html.pdf`

## エラー処理

スクリプトは以下のような場合にエラーメッセージを表示します：
- 必要なツール（curl, wget, grep, sed, awk, Google Chrome）がインストールされていない
- ベースURLが指定されていない
- URLの収集に失敗した
- PDF変換に失敗した

## 終了ステータス

スクリプトは処理完了後、成功したPDF変換数と失敗した数、合計処理時間を表示します。
