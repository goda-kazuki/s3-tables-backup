# s3-tables-backup

Amazon S3 Tables のバックアップについてのブログ記事と、検証用テンプレートを管理するリポジトリ。

- `article.md` 記事（Markdown）
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
