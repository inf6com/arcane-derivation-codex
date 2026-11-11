# inf6.com Website

https://inf6.com/ の公開ファイル。

## 構成

| ファイル | 内容 |
|---|---|
| `index.html` | **公開中のページ。** これが正本 |
| `mission-page.html` | 2026-04 に書かれた「知のサバイバルコンパス」の理念ページ。未公開 |
| `legal.html` | 特定商取引法などの表記 |
| `screen1..5.jpeg` | 旧スクリーンショット |
| `screenshots/*.png` | WWW 掲載用の現行スクリーンショット |
| `inf6.png` / `icon-*.png` / `favicon*` | Arcane Derivation Codex のアプリアイコン一式 |
| `manifest.webmanifest` | ホーム画面追加用アイコン設定 |

## 公開手順

Azure DevOps pipeline `inf6-www-ci` から、お名前.com のレンタルサーバへ FTP で転送する。

- 転送先: FTPログイン直下の `inf6.com/`（サーバー上の `/home/r3895622/public_html/inf6.com/`）
- FTP アカウントはコントロールパネルの「ファイル管理」で作成する
- 接続情報は Azure DevOps の secret variables に置き、リポジトリには入れない

必要な pipeline 変数:

| 変数 | 内容 |
|---|---|
| `WWW_FTP_HOST` | FTP ホスト |
| `WWW_FTP_USER` | FTP ユーザー |
| `WWW_FTP_PASSWORD` | FTP パスワード（secret） |
| `WWW_FTP_REMOTE_DIR` | 省略時は `inf6.com`（FTPログイン直下からの相対パス） |

ローカル確認:

```sh
python3 scripts/validate_www.py
```

CD 実行:

```sh
WWW_FTP_HOST=... WWW_FTP_USER=... WWW_FTP_PASSWORD=... WWW_FTP_REMOTE_DIR=inf6.com bash scripts/deploy_www_ftp.sh
```

FTP 変数が未設定の場合、CD は明示エラーで停止する。未設定のまま成功扱いにしない。

## 注意

- このリポジトリを作る前、サイトはバージョン管理されていなかった。
  公開中の内容は稼働中のサーバからの取得物を初期コミットとしている
- `mission-page.html` は公開中の `index.html` とは別系統。差し替えると
  サイトが全面刷新になるため、意図を確認してから使う
