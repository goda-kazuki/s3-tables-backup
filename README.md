# s3-tables-backup

Amazon S3 Tables のバックアップについてのブログ記事と、検証用テンプレートを管理するリポジトリ。

- `article-backup-methods.md` 1本目の記事（Markdown）。バックアップ方法（レプリケーション、スナップショット、Parquet 退避）
- `article-table-recovery.md` 2本目の記事（Markdown）。テーブルを削除したときの、レプリカからの復帰
- `templates/` CloudFormation / AWS SAM テンプレート
- `images/` 記事で使う画像

## テンプレートの内容

`templates/s3tables-basic.yaml` は次のリソースを作成する。

- テーブルバケット `s3tables-backup-demo`、名前空間 `backup_demo`
- テーブル `sample_events`（Iceberg）。`event_time` を日単位（`day`）でパーティションする
- レプリカ用テーブルバケット `s3tables-backup-demo-replica`（同一リージョン）
- レプリケーション用の IAM ロールと、テーブルバケット単位のレプリケーション設定
- Lake Formation の権限。元の名前空間とテーブルに `IAM_ALLOWED_PRINCIPALS`（IAM の権限だけで制御するグループ）へ全権限を付与する

## デプロイ

IAM ロールを作成するため、`CAPABILITY_IAM` が必要。

```bash
aws cloudformation deploy \
  --template-file templates/s3tables-basic.yaml \
  --stack-name s3tables-backup-demo \
  --capabilities CAPABILITY_IAM \
  --region ap-northeast-1
```

注意点は次のとおり。

- パーティション仕様やスキーマの変更はテーブルの置換になる。テーブル名が固定のため、既存スタックの更新は名前の衝突で失敗する。データが不要なら、スタックを削除して作り直す。
- スタック削除の直後に同名のテーブルバケットを作ると、移行状態で失敗することがある。数分待ってから再実行する。
- `sam validate --lint` は、同梱のスキーマが古く、テーブルバケットのレプリケーション設定を認識せずエラーになる。CloudFormation 本体では受理される。

## クエリ（Athena）

データソースに `s3tablescatalog/s3tables-backup-demo` を選んで実行する。既定の `AwsDataCatalog` のままでは `backup_demo` が見つからない。

```sql
SELECT * FROM "backup_demo"."sample_events" LIMIT 10;
```

## レプリカ側の Lake Formation 権限

レプリカのテーブルと名前空間は、レプリケーションがサービスとして自動作成する。CloudFormation の管理外のため、権限はテンプレートに含められない。レプリカが作成されたあとに、手動で付与する。

付与したあとは、データソース `s3tablescatalog/s3tables-backup-demo-replica` で同じクエリを実行できる。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-1

aws lakeformation grant-permissions --region "$REGION" \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo-replica\",\"DatabaseName\":\"backup_demo\",\"Name\":\"sample_events\"}}"
```

### 権限の削除

付与した権限を取り消す。同じ引数で `revoke-permissions` を実行する。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-1

aws lakeformation revoke-permissions --region "$REGION" \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo-replica\",\"DatabaseName\":\"backup_demo\",\"Name\":\"sample_events\"}}"
```

現在の付与状況は、次のコマンドで確認できる。

```bash
aws lakeformation list-permissions --region "$REGION" \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo-replica\",\"DatabaseName\":\"backup_demo\",\"Name\":\"sample_events\"}}" \
  --query "PrincipalResourcePermissions[].[Principal.DataLakePrincipalIdentifier,Permissions]" --output text
```

元のテーブルの権限（`IAM_ALLOWED_PRINCIPALS`）は、テンプレートで管理しているため、スタックを削除すると自動で取り消される。

## 削除

S3 Tables は課金対象のため、検証後はスタックを削除する。

レプリカテーブルは CloudFormation の管理外のため、残っているとレプリカ用テーブルバケットを削除できず、スタックの削除が失敗する見込みである。次の順に実行する。この手順はドキュメントに基づくもので、まだ実際には試していない。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-1
REPLICA_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/s3tables-backup-demo-replica"

# 1. レプリカ側の Lake Formation 権限を取り消す（上の「権限の削除」）

# 2. レプリカテーブルと名前空間を削除する
aws s3tables delete-table --region "$REGION" \
  --table-bucket-arn "$REPLICA_ARN" --namespace backup_demo --name sample_events
aws s3tables delete-namespace --region "$REGION" \
  --table-bucket-arn "$REPLICA_ARN" --namespace backup_demo

# 3. スタックを削除する
aws cloudformation delete-stack \
  --stack-name s3tables-backup-demo \
  --region "$REGION"
```

## スナップショットへの巻き戻し（Glue ジョブ）

`templates/glue-rollback-job.yaml` は、S3 Tables のテーブルを指定したスナップショットの状態に巻き戻す Glue ETL ジョブを作成する。
先に `s3tables-basic.yaml` をデプロイしておく。ジョブは Spark の Iceberg プロシージャ `rollback_to_snapshot` を実行する。Athena では実行できない。

- ジョブのスクリプトは `templates/glue/rollback_to_snapshot.py`。テンプレートと別に、手動でアップロードする。
- スクリプトは S3 Tables と AWS 分析サービスの統合（`s3tablescatalog`）経由で接続する。
- このテンプレートとスクリプトは、まだ実際には実行していない。IAM 権限が不足していた場合は、エラーを見て追加する。

### デプロイとスクリプトのアップロード

```bash
aws cloudformation deploy \
  --template-file templates/glue-rollback-job.yaml \
  --stack-name s3tables-backup-demo-glue \
  --capabilities CAPABILITY_IAM \
  --region ap-northeast-1

BUCKET=$(aws cloudformation describe-stacks --stack-name s3tables-backup-demo-glue \
  --region ap-northeast-1 \
  --query "Stacks[0].Outputs[?OutputKey=='ScriptBucketName'].OutputValue" --output text)

aws s3 cp templates/glue/rollback_to_snapshot.py \
  "s3://${BUCKET}/scripts/rollback_to_snapshot.py"
```

### 実行

`--snapshot_id` を省略すると、スナップショット一覧と行数を出力するだけで、テーブルは変更しない（ドライラン）。
先にドライランで一覧を確認し、そのあと巻き戻す。

```bash
# ドライラン（変更しない。 CloudWatch Logs でスナップショットID一覧が出力される）
aws glue start-job-run --region ap-northeast-1 \
  --job-name s3tables-backup-demo-rollback

# 巻き戻し（snapshot_id は Athena の "$snapshots" で確認した値）
aws glue start-job-run --region ap-northeast-1 \
  --job-name s3tables-backup-demo-rollback \
  --arguments '{"--snapshot_id":"8927807603977148722"}'

# 結果の確認（run-id は start-job-run の出力）
aws glue get-job-run --region ap-northeast-1 \
  --job-name s3tables-backup-demo-rollback --run-id <run-id>
```

出力は CloudWatch Logs の `/aws-glue/jobs/output` に出る。巻き戻し後は、Athena で `$snapshots` と件数を確認する。

### 削除

スクリプト用バケットは、空にしてからスタックを削除する。

```bash
aws s3 rm "s3://${BUCKET}" --recursive
aws cloudformation delete-stack --stack-name s3tables-backup-demo-glue --region ap-northeast-1
```

## Parquet への退避（Athena）

スナップショットの保持期間（120 時間）より前に戻せるよう、日ごとの差分を Athena の `UNLOAD` で S3 に Parquet として退避する。
設計は `docs/superpowers/specs/2026-10-14-parquet-backup-restore-design.md` にある。

`templates/athena-parquet-backup.yaml` は、退避の土台として次のリソースを作成する。
先に `s3tables-basic.yaml` をデプロイしておく。

- 退避データとクエリ結果を置く S3 バケット `s3tables-backup-demo-export-<アカウントID>-<リージョン>`。暗号化は SSE-S3、パブリックアクセスはブロックする。名前にアカウント ID とリージョンを含めるのは、S3 のバケット名が全世界で一意である必要があるため。
- Athena ワークグループ `s3tables-backup-demo`。結果の出力先を上のバケットの `athena-results/` に固定する。暗号化は SSE-S3 にする。

- Glue データベース `backup_demo_archive` と、退避データを読む外部テーブル `sample_events_archive`。`dt` を文字列のパーティション列にする。`event_time` は、退避が文字列なので `string` で定義する。

ワークグループの暗号化を SSE-KMS または CSE-KMS にすると、Athena から S3 Tables への書き込み（`INSERT` や `DELETE`）ができなくなる。
このため SSE-S3 にしている。

Lake Formation の権限は、このテンプレートでは付与しない。
このアカウントでは、新しい Glue データベースに `IAM_ALLOWED_PRINCIPALS` の権限が自動で付く。
同じ権限をテンプレートで作ると、`AlreadyExists` で失敗した。
アカウントの設定が異なり、Athena から参照できない場合は、権限を別途付与する。

### デプロイ

IAM ロールを作らないため、`--capabilities` は不要。

```bash
aws cloudformation deploy \
  --template-file templates/athena-parquet-backup.yaml \
  --stack-name s3tables-backup-demo-athena \
  --region ap-northeast-1
```

出力値（バケット名、`UNLOAD` の出力先、ワークグループ名）は、次のコマンドで確認できる。

```bash
aws cloudformation describe-stacks --stack-name s3tables-backup-demo-athena \
  --region ap-northeast-1 \
  --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output text
```

### 退避先のレイアウト

```
s3://s3tables-backup-demo-export-123456789012-ap-northeast-1/backup/sample_events/dt=2026-10-01/*.parquet
s3://s3tables-backup-demo-export-123456789012-ap-northeast-1/athena-results/
```

### 退避と復元

SQL は `templates/athena/` にある。Athena のワークグループ `s3tables-backup-demo` で、1 文ずつ実行する。

- `export_day.sql` 指定した日の差分を、Parquet で退避する。実行前に、`event_time` の範囲と `<ACCOUNT_ID>` を書き換える。
- `restore_to_date.sql` テーブルを、指定した日の状態に戻す。全行を `DELETE` し、`dt` が指定日以下の退避データを `INSERT` する。

注意点は次のとおり。

- `event_time` は文字列で退避する。Athena の `UNLOAD` は、Parquet にミリ秒精度のタイムスタンプしか書けず、Iceberg のマイクロ秒精度のままでは `NOT_SUPPORTED` エラーになる。`timestamp(3)` に変換するとミリ秒未満が切り捨てられるため、文字列にして、復元時に `timestamp(6)` に戻す。
- 同じ日を再実行すると、ファイルが増えて行が重複する。再退避の前に、`dt=YYYY-MM-DD/` のフォルダを削除する。
- `MSCK REPAIR TABLE` は、データソースを `AwsDataCatalog` にして実行する。S3 Tables のカタログのままだと、「Unsupported DDL query for S3 table buckets」で拒否される。
- 復元の `DELETE` と `INSERT` は別の文。間で失敗するとテーブルが空になる。`INSERT` を再実行すれば戻る。
- 退避は `event_time` ベースの差分。退避済みの日の行を後から更新しても、その日を再退避しないと反映されない。

### 削除

バケットは、空にしてからスタックを削除する。

```bash
BUCKET=$(aws cloudformation describe-stacks --stack-name s3tables-backup-demo-athena \
  --region ap-northeast-1 \
  --query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text)

aws s3 rm "s3://${BUCKET}" --recursive
aws cloudformation delete-stack --stack-name s3tables-backup-demo-athena --region ap-northeast-1
```
