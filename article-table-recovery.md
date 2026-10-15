# Amazon S3 Tables のテーブルを削除してみた。レプリカからの復帰と、同名で作り直したときのレプリケーション失敗

1本目の記事「Amazon S3 Tables のリカバリ手法を検証してみた（スナップショット巻き戻し・Parquet退避）」では、データを書き間違えた場合の戻し方を確認しました。
この記事では、テーブル自体を誤って削除した場合を確認します。
テーブルを削除すると、スナップショットも一緒に失われるため、スナップショットでは戻せません。

前提は、1本目の記事と同じ構成です。
テーブルバケットは、同じリージョンのレプリカ用テーブルバケットに、バケット単位でレプリケーションしています。

## この記事の結論

- 元のテーブルを削除しても、レプリカのテーブルとデータは残ります。
- 削除したテーブルを元に戻すコマンドは、見つかりませんでした。
- レプリカは読み取り専用です。元のテーブルを同じスキーマで作り直し、レプリカからデータを入れ直します。
- 作り直しを先にすると、レプリケーションが失敗します。**先にレプリカの古いテーブルの名前を変える**と、避けられます。

## 準備

以降のコマンドで使う変数を定義します。
新しいシェルを開くと、変数は消えます。
空のままだと、`Invalid endpoint: https://s3tables..amazonaws.com` というエラーになります。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-1
SRC_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/s3tables-backup-demo"
REPLICA_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/s3tables-backup-demo-replica"
```

## 検証用のテーブルを作成する

1本目で使った `sample_events` は残しておきたいので、検証用のテーブル `delete_test` を作ります。
列は、`id` と `note` の2つです。

```bash
aws s3tables create-table --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --namespace backup_demo --name delete_test \
  --format ICEBERG \
  --metadata '{"iceberg":{"schema":{"fields":[{"name":"id","type":"string","required":true},{"name":"note","type":"string"}]}}}'
```

Athena から書き込めるように、Lake Formation の権限を付与します。
`IAM_ALLOWED_PRINCIPALS` は、Lake Formation では絞らず、IAM の権限だけで制御するためのグループです。
このグループに、全権限を付与します。

```bash
aws lakeformation grant-permissions --region "$REGION" \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo\",\"DatabaseName\":\"backup_demo\",\"Name\":\"delete_test\"}}"
```

1件投入します。
ワークグループは `s3tables-backup-demo`、データソースは `s3tablescatalog/s3tables-backup-demo` を選びます。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."delete_test"
  (id, note)
VALUES ('1', '削除テスト用');
```

### レプリカができるまで待つ

レプリカができるまで、数分かかります。
それまでにレプリカを読むと、次のエラーになります。

```text
ICEBERG_INVALID_METADATA: Table is missing [metadata_location] property
```

次のコマンドで、状態が `completed` になるまで待ちます。

```bash
TABLE_ARN=$(aws s3tables get-table --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --namespace backup_demo --name delete_test \
  --query tableARN --output text)

aws s3tables get-table-replication-status --region "$REGION" --table-arn "$TABLE_ARN"
```

### レプリカを読めるようにする

レプリカを読むには、レプリカ側のテーブルにも、Lake Formation の権限が必要です。

```bash
aws lakeformation grant-permissions --region "$REGION" \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo-replica\",\"DatabaseName\":\"backup_demo\",\"Name\":\"delete_test\"}}"
```

データソースを `s3tablescatalog/s3tables-backup-demo-replica` にして、同じ1件があることを確認します。

```sql
SELECT * FROM "s3tablescatalog/s3tables-backup-demo-replica"."backup_demo"."delete_test";
```

| #   | id  | note         |
| --- | --- | ------------ |
| 1   | 1   | 削除テスト用 |

## 元のテーブルを削除しても、レプリカは残る

元のテーブルを削除します。

```bash
aws s3tables delete-table --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --namespace backup_demo --name delete_test
```

元のテーブルは消えますが、レプリカは、テーブルもデータも残っていました。
レプリカは、誤ったテーブル削除に対するバックアップとして使えます。

削除したテーブルを元に戻すコマンドは、探しましたが見つかりませんでした。

```bash
aws s3tables help | grep -i -E "restore|undelete|recover"
```

## 最初の復元の試み（失敗する順序）

### レプリカからテーブルを作り直す

レプリカは読み取り専用で、元のテーブルに昇格させることはできません。
そこで、元のテーブルを同じスキーマで作り直し、レプリカからデータを入れ直します。

まず、先ほどの `create-table` と同じコマンドで、同じスキーマのテーブルを作り直します。
作り直したテーブルにも、Lake Formation の権限を付与します。
権限のコマンドは、元のテーブルに付与したものと同じです。

そのあと、レプリカからデータを入れ直します。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."delete_test"
  (id, note)
SELECT id, note
FROM "s3tablescatalog/s3tables-backup-demo-replica"."backup_demo"."delete_test";
```

データは、ちゃんと戻りました。

### 追加で書き込むと、レプリケーションが失敗する

作り直したテーブルに、追加で書き込みます。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."delete_test"
  (id, note)
VALUES ('2', '追加書き込みでレプリケートされるのか');
```

この書き込みは、レプリカに反映されませんでした。
レプリケーションの状態を見ると、`failed` になっています。

```text
"replicationStatus": "failed",
"failureMessage": "A table with an identical name already exists at the destination."
```

作り直したテーブルは、別のテーブルとして扱われます。
そのため、レプリカ側に残っている同名のテーブルとぶつかります。
復元は成功しても、作り直したテーブルには、バックアップがない状態になります。

## 失敗からの直し方

### レプリカの古いテーブルの名前を変える

レプリカの古いテーブルの名前を、`rename-table` で変えます。

```bash
VERSION_TOKEN=$(aws s3tables get-table-metadata-location --region "$REGION" \
  --table-bucket-arn "$REPLICA_ARN" --namespace backup_demo --name delete_test \
  --query versionToken --output text)

aws s3tables rename-table --region "$REGION" \
  --table-bucket-arn "$REPLICA_ARN" --namespace backup_demo --name delete_test \
  --new-name delete_test_old --version-token "$VERSION_TOKEN"
```

名前を変えたあとに、再試行のきっかけになるかを見るため、もう1件書き込みました。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."delete_test"
  (id, note)
VALUES ('3', 'レプリケート失敗し、レプリケート先のテーブル名を変更した後にトライ');
```

名前は変わりましたが、10分待っても `failed` のままで、再試行されませんでした。
公式ドキュメントには、原因を直せば自動で再試行されると書かれています。
今回は、その動きを確認できませんでした。

### レプリケーション設定を入れ直す

そこで、バケットのレプリケーション設定を、同じ内容で入れ直しました。

```bash
VT=$(aws s3tables get-table-bucket-replication --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --query versionToken --output text)

aws s3tables get-table-bucket-replication --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --query configuration --output json > replication.json

aws s3tables put-table-bucket-replication --region "$REGION" \
  --table-bucket-arn "$SRC_ARN" --version-token "$VT" --configuration file://replication.json
```

数分後に、レプリカ側に `delete_test` が新しく作られ、状態が `completed` になりました。
失敗中に書き込んだ id=2 と id=3 も、すべてレプリカに反映されています。

| テーブル                     | 中身                                           |
| ---------------------------- | ---------------------------------------------- |
| 元の delete_test             | 3 件（id=1 の復元分、id=2、id=3）              |
| 新しいレプリカの delete_test | 3 件（元と同じ）                               |
| 名前を変えた delete_test_old | 1 件（id=1。削除前の状態）                     |

## 安全な復元の順序

今回は、作り直しを先にして、衝突しました。
テーブルの削除から復元するときは、次の順序が安全です。

1. レプリカの古いテーブルの名前を変える。
2. 名前を変えたレプリカのテーブルに、Lake Formation の権限を付与する。
3. 元のテーブルを、同じスキーマで作り直す。
4. 作り直したテーブルに、Lake Formation の権限を付与する。
5. 名前を変えたレプリカから、データを入れ直す。
6. レプリケーションの状態が `completed` になることを確認する。

この順序で、もう一度試しました。
レプリカの古いテーブルは、`delete_test_bk` に名前を変えています。

1. 元の `delete_test` を削除する。
2. レプリカの `delete_test` を、`delete_test_bk` に名前を変える。
3. 元の `delete_test` を、同じスキーマで作り直す。
4. `delete_test_bk` から、データを入れ直す。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."delete_test"
  (id, note)
SELECT id, note
FROM "s3tablescatalog/s3tables-backup-demo-replica"."backup_demo"."delete_test_bk";
```

結果は、次のとおりです。

- レプリケーションの状態は、`failed` にならず、`pending` から `completed` になりました。
- 作り直した直後に、レプリカ側にも `delete_test` が新しく作られました。`completed` になるまで、約7分かかりました。
- 入れ直した3件が、元とレプリカの両方にあります。
- 復元のあとに追加で書き込んだ1件も、数分でレプリカに反映されました。

同じ名前で作り直したときの失敗は、この順序で避けられます。

作り直したテーブルと、名前を変えたテーブルには、Athena から読むための Lake Formation の権限を付け直す必要があります。

## まとめ

- テーブルを誤って削除しても、レプリカは残ります。レプリカからデータを入れ直して、元のテーブルを作り直せます。
- 削除したテーブルを戻す専用のコマンドは、見つかりませんでした。
- 同じ名前で作り直すと、レプリケーションが失敗します。レプリカの古いテーブルの名前を先に変えると、避けられます。
- 復元のあとは、レプリケーションの状態が `completed` になることを確認します。

## 注意点

- レプリカは読み取り専用です。元のテーブルに昇格させることはできないため、作り直して、データを入れ直します。
- 作り直したテーブルは、別のテーブルです。ARN とテーブル ID が変わり、スナップショットの履歴は新しく始まります。メンテナンス設定やタグなども、設定し直します。
- 作り直しや名前の変更のたびに、Lake Formation の権限を付け直します。
- 復元の直後から `completed` になるまで、約7分かかりました。この間は、作り直したテーブルのバックアップが追いついていません。
- 名前を変えるだけでは再試行されず、10分待っても `failed` のままでした。名前を先に変えれば、設定の入れ直しは不要でした。それ以上待った場合に自動で直るかは、確認していません。
- 検証は、同じアカウントの同じリージョンで行いました。別のリージョンや別のアカウントへのレプリケーションは、試していません。

## 参考リンク

- [How S3 Tables replication works](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-how-replication-works.html)
- [Managing S3 Tables replication（レプリケーションの状態の確認）](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-managing.html)
- [rename-table（AWS CLI）](https://docs.aws.amazon.com/cli/latest/reference/s3tables/rename-table.html)
- [put-table-bucket-replication（AWS CLI）](https://docs.aws.amazon.com/cli/latest/reference/s3tables/put-table-bucket-replication.html)
