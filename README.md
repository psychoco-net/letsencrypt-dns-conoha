[English](README.en.md) | 日本語

# letsencrypt-dns-conoha

ConoHa VPS 上で Let's Encrypt のワイルドカード証明書を、DNS-01 認証 + ConoHa
DNS API で自動取得・更新するためのスクリプトです。

[k2snow/letsencrypt-dns-conoha](https://github.com/k2snow/letsencrypt-dns-conoha)（MIT）
の fork です。主な変更点は、**ConoHa API v3**（`c3j1`）への対応（従来の v2
`tyo1` / `tyo2` に加えて）、DNS 伝播待ちの堅牢化、ロギングの追加です。

## 元リポジトリからの変更点

- `CNH_REGION` による **API v2 / v3 の自動切り替え**（`tyo1`/`tyo2` は v2、
  それ以外は v3）。
- **`.env` による設定**（元の `conoha_id` ファイル方式から変更）。
- **権威ネームサーバへのポーリングによる伝播待ち**（固定 `sleep` を廃止）。
  対象ゾーンの権威 NS を解決し、TXT レコードが**全ての権威 NS**で見えるまで待機
  します（ACME バリデータが参照するのは権威 NS のため）。タイムアウトあり。
- **最長サフィックスマッチ**による ConoHa DNS ドメイン一覧との照合。サブドメイン
  証明書や多段 TLD（`co.jp`、`ne.jp` など）でも正しい登録ゾーンを特定します。
- API 呼び出しの **HTTP ステータスチェック**と、トークン・ドメイン ID の
  **早期検証**（fail-fast）。設定ミスがハングせず即座に表面化します。
- タイムスタンプ付きの `conoha_dns.log` への **ロギング**。
- 廃止された certbot の `--manual-public-ip-logging-ok` フラグは**使用しません**
  （certbot 2.0 で削除済み）。

## 必要なもの

- ConoHa VPS アカウント（対象ドメインを ConoHa DNS で管理していること）
- certbot（新しめのバージョン。削除済みの `--manual-public-ip-logging-ok`
  フラグを使わない構成で動作確認）
- `jq`
- `dig`（RHEL 系では `bind-utils` に含まれます）
- bash 4 以上（`mapfile` を使用）

AlmaLinux 9 でのインストール例:

```
sudo dnf install -y certbot jq bind-utils
```

## セットアップ

1. スクリプトをサーバに配置します（例: `/etc/letsencrypt/conoha/`）。
2. テンプレートから認証情報ファイルを作成し、編集します:

   ```
   cp .env.example .env
   $EDITOR .env
   ```

3. フックスクリプトに実行権限を付与します:

   ```
   chmod +x create_conoha_dns_record.sh delete_conoha_dns_record.sh
   ```

### `.env` の項目

| 変数             | 説明                                                                |
| ---------------- | ------------------------------------------------------------------- |
| `CNH_REGION`     | ConoHa VPS 3.0（API v3）は `c3j1`、VPS 2.0 は `tyo1` / `tyo2`        |
| `CNH_TENANT_ID`  | コントロールパネル「API」ページのテナント（プロジェクト）ID         |
| `CNH_USERNAME`   | API ユーザー名（`gncu...` の値）。「API ユーザー」欄から取得         |
| `CNH_PASSWORD`   | API ユーザー作成時に設定したパスワード                              |

> `.env` は git の追跡対象外です。実際の認証情報をコミットしないでください。

## 使い方

### Dry run（ステージング検証）

```
sudo certbot certonly \
  --dry-run \
  --manual \
  --agree-tos \
  --no-eff-email \
  --preferred-challenges dns-01 \
  --server https://acme-v02.api.letsencrypt.org/directory \
  -d "<ベースドメイン名>" \
  -d "*.<ベースドメイン名>" \
  -m "<メールアドレス>" \
  --manual-auth-hook /etc/letsencrypt/conoha/create_conoha_dns_record.sh \
  --manual-cleanup-hook /etc/letsencrypt/conoha/delete_conoha_dns_record.sh
```

### 証明書の取得

上記コマンドから `--dry-run` を外して実行します。

### 更新

```
sudo certbot renew --dry-run   # 検証
sudo certbot renew             # 実行
```

certbot は証明書とともにフック設定を保存するため、`renew` 時は同じフックが自動的に
再利用されます。

## ファイル構成

| ファイル                      | 役割                                                  |
| ----------------------------- | ----------------------------------------------------- |
| `create_conoha_dns_record.sh` | `--manual-auth-hook`: TXT 作成と伝播待ち              |
| `delete_conoha_dns_record.sh` | `--manual-cleanup-hook`: TXT レコードの削除           |
| `conoha_dns_api_v2.sh`        | ConoHa API v2（`tyo1`/`tyo2`）用の関数群              |
| `conoha_dns_api_v3.sh`        | ConoHa API v3（`c3j1`）用の関数群                     |
| `.env.example`                | 認証情報のテンプレート（`.env` にコピーして使用）     |

## 補足

- `*.example.com` の証明書取得時、certbot は auth フックを**2回**呼び出します
  （同じ名前 `_acme-challenge.example.com` で値が異なる）。検証中は2つの TXT
  レコードが共存しますが、これは正常な動作です。
- `conoha_dns.log` は時間とともに肥大化しますが、スクリプトがサイズ超過時に
  世代ローテートします（`.env` の `LOG_MAX_BYTES` / `LOG_GENERATIONS` で調整可。
  既定は 1 MiB・3 世代）。総容量は `LOG_MAX_BYTES × (世代数+1)` で頭打ちです。
- `_acme-challenge` が **CNAME**（acme-dns 等の委任に使用）の場合は削除しないで
  ください。削除して安全なのは使い捨ての TXT レコードのみです。

## ライセンス

MIT License（[LICENSE](LICENSE) 参照）。Original work Copyright (c) k2snow.
