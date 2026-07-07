# terraform_remote_state_check.sh

S3 バックエンドに保存された**他チーム管理の Terraform リモートステート**を、`terraform_remote_state` データソース経由で実際に読み取り、データソース定義の動作確認および output キーの検索・選択・値取得を行う検証用スクリプトです。

- **対象環境**: RHEL9 (EC2), bash 5.x, Terraform 1.x, AWS CLI v2, jq
- **バージョン**: 1.3.0

## 安全方針(読み取り専用)

本スクリプトは他チームのリモートステートの**確認・検証専用**です。以下の保護をスクリプト自体が強制するため、AWS リソースの作成や他チームのリモートステートの書き換えは行われません。

| 保護 | 内容 |
|---|---|
| ローカルステート強制 | ステートは常に一時作業ディレクトリ内のローカルステートを使用します。指定した .tf ファイルに `backend` 定義が含まれていても、自動生成される `backend_override.tf`(`backend "local"`)によりローカルステートに強制上書きされ、リモートステートへの書き込みは構成上不可能です。 |
| 危険な .tf の入力拒否 | `--terraform-data-source-file` で渡されたファイルに `resource` / `module` ブロックが含まれる場合、リソースを作成し得るためパラメータエラー(exit 2)で即中止します。 |
| plan 検証つき apply | 無条件の `apply -auto-approve` は行いません。`terraform plan -out` → `terraform show -json` で plan 内容を検査し、リソースの作成・変更・削除が 1 件でも含まれる場合は中止します。許可されるのはデータソースの読み取り(read / no-op)と output の更新のみで、検証済みの plan ファイルだけを apply します。 |

AWS に対する操作は以下の**読み取り系 API のみ**です。

- `sts get-caller-identity`(認証確認)/ `sts assume-role`(`--role-arn` 指定時の権限確認)
- `s3api head-object`(単一ステート指定時の権限確認)
- `s3api list-objects-v2`(バケット全体参照モードでの一覧取得)
- Terraform の `terraform_remote_state` データソースによるステートファイルの GetObject(読み取り)

apply が書き込むのは一時作業ディレクトリ内のローカル `terraform.tfstate` のみで、終了時に自動削除されます(`--keep-workdir` 指定時を除く)。

## 動作モード

### A) データソースコード検証モード

`--terraform-data-source-file` で既存の `terraform_remote_state` データソース定義(.tf)を渡し、その定義が実際に動作するかを確認します。1 ファイルにつき 1 つの `terraform_remote_state` 定義が必要です。

### B) パラメータ生成モード(単一ステート)

`--bucket` / `--state-key` / `--region` からデータソース定義を自動生成して読み取ります。

### C) バケット全体参照モード

`--state-key` を**省略**すると、リモートステートを管理している S3 バケットに配置されている**全ファイル**を参照対象として、1 ファイルにつき 1 つの `terraform_remote_state` データソースを一括生成します。

- フォルダマーカー(キー末尾が `/` のオブジェクト)は除外されます。
- 拡張子が `.tfstate` でないファイルも対象に含めますが、その旨を警告表示します(ステートファイルでない場合は読み取りに失敗します)。

いずれのモードでも、以下を組み合わせられます。

- `--output-key` : 指定キーの値を直接取得
- `--search` : キー候補を検索し、番号選択して値を取得
- どちらも未指定の場合は、取得可能な output キー一覧を表示

## データソースの命名ルール(モードC)

データソース名は `--name-template` で指定するテンプレートから生成されます。

**デフォルト: `INFRA_{dir1}_{dir2}`**
(INFRA(固定文字列)\_ステートファイルが保管されているバケットの第 1 階層ディレクトリ名\_第 2 階層ディレクトリ名)

| プレースホルダ | 意味 |
|---|---|
| `{dir1}` `{dir2}` `{dir3}` | ステートファイルキーの第 1〜第 3 階層のディレクトリ名 |
| `{basename}` | ファイル名(`.tfstate` 拡張子を除く) |

生成例(デフォルトテンプレートの場合):

| S3 キー | データソース名 |
|---|---|
| `network/prod/terraform.tfstate` | `INFRA_network_prod` |
| `network/terraform.tfstate` | `INFRA_network` |
| `terraform.tfstate`(ルート直下) | `INFRA` |
| `app/dev/db/terraform.tfstate` | `INFRA_app_dev`(第 3 階層以降は無視) |

命名時の自動補正:

- Terraform 識別子に使えない文字(日本語・記号等)は `_` に置換
- 空要素による連続 `_` は 1 つに詰め、末尾の `_` は除去
- 生成名が重複した場合は連番(`_2`, `_3` ...)を付与して警告表示

## 使用方法

```
./terraform_remote_state_check.sh [オプション]
```

### 必須パラメータ(モードB/C の場合)

| オプション | 説明 |
|---|---|
| `--bucket <name>` | リモートステートの S3 バケット名 |
| `--region <region>` | AWS リージョン(例: `ap-northeast-1`) |
| `--state-key <key>` | リモートステートファイルのキー(例: `network/terraform.tfstate`)。省略時はモードCとしてバケット内の全ファイルを対象にします。 |

### 任意パラメータ

| オプション | 説明 |
|---|---|
| `--terraform-data-source-file <path>` | `terraform_remote_state` データソース定義(.tf)ファイル(モードA) |
| `--data-source-name <name>` | データソース名(既定: `remote_state`)。モードCでは `--output-key` の対象データソースの絞り込み(同名キーが複数ある場合の指定)に使用します。 |
| `--name-template <tpl>` | モードCでのデータソース名テンプレート(既定: `INFRA_{dir1}_{dir2}`) |
| `--output-key <key>` | 取得対象の output キー |
| `--search <string>` | output キーの検索文字列(部分一致・大文字小文字無視) |
| `--role-arn <arn>` | assume role に利用する Role ARN |
| `--external-id <id>` | assume role に必要な External ID |
| `--profile <name>` | AWS プロファイル名 |
| `--switchback-shell-path <path>` | スイッチバック用シェルのパス(`source` で読み込み) |
| `--auto-switchback` | 権限不足時に自動スイッチバックして継続する |
| `--no-auto-switchback` | 権限不足時は警告して終了する(既定) |
| `--common-sh-path <path>` | 外部 common.sh のパス(省略時は内蔵の共通関数で動作) |
| `--output-dir <dir>` | 結果をレポートファイルとして出力するディレクトリ(存在しない場合は自動作成)。キー一覧・値取得のいずれの結果も内容に応じたレポート形式で出力します。 |
| `--report-format <fmt>` | `--output-dir` 指定時のファイル形式(既定: `text`)。`text`(整形レポート .txt)/ `csv`(Excel 取り込み向け .csv)/ `both`(両方)。 |
| `--excel` | `--report-format csv` の別名(Excel 取り込み向け CSV を出力) |
| `--json-expand` | output の取得値が JSON 構造(オブジェクト/配列)の場合に、JSON のキーと値へ深掘りして表示・出力する |
| `--debug` | 生成コード・実行コマンド・terraform 出力を表示する |
| `--keep-workdir` | 終了時に一時作業ディレクトリを削除しない |
| `--help` | ヘルプを表示する |

`--output-key` と `--search` は同時に指定できません。`--external-id` は `--role-arn` との併用が必須です。

## 実行例

```bash
# 1) 既存の .tf 定義ファイルの動作確認 (キー一覧を表示)
./terraform_remote_state_check.sh --terraform-data-source-file ./remote_state.tf

# 2) パラメータ指定で特定の output キーを直接取得
./terraform_remote_state_check.sh --bucket team-a-tfstate --state-key network/terraform.tfstate \
    --region ap-northeast-1 --output-key vpc_id

# 3) 検索文字列でキー候補を表示し、番号選択して値を取得
./terraform_remote_state_check.sh --bucket team-a-tfstate --state-key network/terraform.tfstate \
    --region ap-northeast-1 --search subnet

# 4) バケット内の全ステートファイルを一括参照し、キー一覧を表示 (モードC)
#    例: network/prod/terraform.tfstate -> data.terraform_remote_state.INFRA_network_prod
./terraform_remote_state_check.sh --bucket team-a-tfstate --region ap-northeast-1

# 5) モードCで命名テンプレートを変更して一括参照
./terraform_remote_state_check.sh --bucket team-a-tfstate --region ap-northeast-1 \
    --name-template 'RS_{dir1}_{dir2}_{basename}'

# 6) assume role + 自動スイッチバックを併用
./terraform_remote_state_check.sh --bucket team-a-tfstate --state-key network/terraform.tfstate \
    --region ap-northeast-1 --role-arn arn:aws:iam::123456789012:role/tfstate-read \
    --external-id my-external-id \
    --auto-switchback --switchback-shell-path /opt/tools/switchback_aws.sh
```

### モードCでの output キー一覧表示・値取得

キー一覧はデータソースごとにグループ化して表示されます。

```
==================================================================
 terraform_remote_state データソース検証結果: 成功
==================================================================
  データソース: 2 件 / output キー合計: 3 件

  ■ data.terraform_remote_state.INFRA_network_prod  (key: network/prod/terraform.tfstate)
      - vpc_id
      - subnet_ids

  ■ data.terraform_remote_state.INFRA_app_dev  (key: app/dev/terraform.tfstate)
      - vpc_id
==================================================================
```

- `--search` は全データソース横断で検索し、「キー名(データソース名)」形式の候補から番号選択します。
- `--output-key` で同名キーが複数のデータソースに存在する場合はエラーになるため、`--data-source-name` で対象を指定してください。

```bash
./terraform_remote_state_check.sh --bucket team-a-tfstate --region ap-northeast-1 \
    --output-key vpc_id --data-source-name INFRA_network_prod
```

## ファイル出力(レポート機能)

`--output-dir <dir>` を指定すると、画面表示に加えて結果を指定ディレクトリへレポートファイルとして出力します(ディレクトリが存在しない場合は自動作成)。出力される内容は動作モードに応じて次の 2 種類です。

- **キー一覧レポート**(`--output-key` / `--search` 未指定時): データソースごとの output キー一覧
- **値取得レポート**(`--output-key` / `--search` 指定時): 選択キーの取得値

出力形式は `--report-format`(または `--excel`)で選択します。

| 形式 | 拡張子 | 内容 |
|---|---|---|
| `text`(既定) | `.txt` | 見出し・メタ情報付きの整形されたきれいなレポート |
| `csv` / `--excel` | `.csv` | Excel できれいに取り込める CSV。**UTF-8 BOM 付き・CRLF 改行**のため、Excel でダブルクリックするだけで文字化けせず列分割された状態で開けます。 |
| `both` | `.txt` と `.csv` | 両方を出力 |

ファイル名は実行時刻付きで、キー一覧は `keys_<日時>.(txt|csv)`、値取得は `value_<データソース名>_<キー名>_<日時>.(txt|csv)` の形式になります。

### JSON 値の深掘り表示(`--json-expand`)

取得した output 値が JSON 構造(オブジェクト/配列)の場合、`--json-expand` を指定すると値をそのまま表示するだけでなく、**JSON のキーと値へ深掘り**して「キーパス = 値」の形式で展開表示・出力します。ネストしたオブジェクトはドット区切り、配列はインデックス `[n]` で表現されます。

```
 取得値 (JSON):
   {
     "vpc": { "id": "vpc-123" },
     "subnets": [ "subnet-a", "subnet-b" ]
   }

 JSON 深掘り (キーパス = 値):
   vpc.id = "vpc-123"
   subnets[0] = "subnet-a"
   subnets[1] = "subnet-b"
```

CSV 形式かつ `--json-expand` 指定時は、深掘りしたキーパス単位で 1 行ずつ(`data_source, s3_key, output_key, json_path, value` 列)出力されるため、Excel 上でキーパスごとに値を扱えます。

```bash
# 値を Excel 取り込み向け CSV で出力しつつ、JSON はキーパス単位に展開
./terraform_remote_state_check.sh --bucket team-a-tfstate --state-key network/terraform.tfstate \
    --region ap-northeast-1 --output-key vpc_config \
    --output-dir ./reports --excel --json-expand

# キー一覧を text と csv の両方でレポート出力
./terraform_remote_state_check.sh --bucket team-a-tfstate --region ap-northeast-1 \
    --output-dir ./reports --report-format both
```

## 処理の流れ

1. パラメータ解析・整合性チェック
2. 必須コマンド(`aws` / `terraform` / `jq` / `mktemp`)の存在確認
3. AWS 認証確認(`aws sts get-caller-identity`。`aws login --remote` 実施済みかを実 API で確認)
4. AWS 操作権限確認(S3 head-object / list-objects-v2 / assume-role)。権限不足時は `--auto-switchback` 指定があればスイッチバック用シェルを `source` して再確認
5. 一時作業ディレクトリに Terraform コードを生成(`main.tf` / `backend_override.tf` / `outputs.tf`)
6. `terraform init` → `terraform plan`(リソース変更ゼロを検証)→ 検証済み plan の `apply` でリモートステートを実読み取り
7. output キー一覧の表示、または指定・選択されたキーの値を取得して表示(`--json-expand` 指定時は JSON 値をキーパス単位に深掘り)。`--output-dir` 指定時は結果をレポートファイル(text / csv)として出力
8. 一時作業ディレクトリを削除して終了

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 正常終了 |
| 2 | パラメータ不正 |
| 3 | AWS 認証エラー |
| 4 | 権限不足 |
| 5 | スイッチバック失敗 |
| 6 | Terraform 実行失敗 |
| 1 | その他のエラー |

## トラブルシューティング

- **初回実行時**は `--debug --keep-workdir` を付けて、生成された `main.tf` / `outputs.tf` と terraform の出力を確認することを推奨します。
- `terraform apply` が失敗した場合、ログから原因(権限不足 / 認証期限切れ / バケット・キー不存在 / 構文エラー)を自動で切り分けて表示します。
- モードCでバケット内にステートファイル以外のファイルが含まれていると読み取り全体が失敗します。その場合は `--state-key` で対象を個別に指定してください。

## 変更履歴

| バージョン | 内容 |
|---|---|
| 1.0.0 | 初版(モードA/B、検索・選択、assume role、スイッチバック対応) |
| 1.1.0 | 読み取り専用ガードを追加(`backend_override.tf` によるローカルステート強制、`resource` / `module` ブロックを含む .tf の入力拒否、plan のリソース変更ゼロ検証後の apply) |
| 1.2.0 | バケット全体参照モード(モードC)と命名テンプレート `--name-template`(既定: `INFRA_{dir1}_{dir2}`)を追加 |
| 1.3.0 | 結果のファイル出力機能を追加。`--output-dir` で出力先を指定し、`--report-format`(`text` / `csv` / `both`)・`--excel` できれいなレポート形式や Excel 取り込み向け CSV(UTF-8 BOM + CRLF)を選択可能に。`--json-expand` で JSON 構造の取得値をキーパス単位に深掘り表示・出力する機能を追加 |
