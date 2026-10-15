# Amazon S3 Tables のリカバリ手法を検証してみた（スナップショット巻き戻し・Parquet退避）

Amazon S3 Tables のデータを書き間違えたとき、どうやって元に戻すのか。
この記事では、次の3つの方法を実際に試し、できたことと限界を整理します。

- **レプリケーション**: テーブルをもう1つのテーブルバケットに複製しておく。
- **スナップショットの巻き戻し**: Iceberg のスナップショットを使って、テーブルを過去の状態に戻す。
- **Parquet 退避**: 日ごとのデータを S3 に Parquet で書き出しておき、そこから復元する。

テーブル自体を誤って削除した場合は、別の記事で扱います。

## この記事の結論

| 起きたこと                | 使う方法                       | 戻せる範囲               |
| ------------------------- | ------------------------------ | ------------------------ |
| データを書き間違えた      | スナップショットの巻き戻し     | 5日（120時間）以内       |
| 5日より前の状態に戻したい | Parquet 退避からの復元         | 退避した日まで           |
| テーブルを削除した        | レプリカからの復帰（別の記事） | レプリカに残っている状態 |

## 検証環境

CloudFormation テンプレート3本で環境を作りました。
テンプレートは、リポジトリの `templates/` にあります。

| テンプレート                 | 作るもの                                                                                     |
| ---------------------------- | -------------------------------------------------------------------------------------------- |
| `s3tables-basic.yaml`        | テーブルバケット、レプリカ用テーブルバケット、レプリケーション設定、テーブル `sample_events` |
| `glue-rollback-job.yaml`     | スナップショットに巻き戻す Glue ジョブ                                                       |
| `athena-parquet-backup.yaml` | 退避先の S3 バケット、Athena ワークグループ、退避データを読む外部テーブル                    |

テーブル `sample_events` の列は、`event_id`、`event_time`、`message` の3つです。
`event_time` を日単位でパーティションしています。
リージョンは ap-northeast-1 です。レプリカは、同じリージョンのテーブルバケットに作っています。

Athena でテーブルを読むときは、データソースに `s3tablescatalog/s3tables-backup-demo` を選びます。
Lake Formation の権限は、テンプレートで `IAM_ALLOWED_PRINCIPALS` に付与しています。

## レプリケーションを確認する

CloudFormation でスタックを作成し、テーブルが作られたことを確認しました。
Athena で次のクエリを実行すると、結果は0件です。

```sql
SELECT * FROM "backup_demo"."sample_events" LIMIT 10;
```

1件目を追加します。

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
  'evt-0001',
  TIMESTAMP '2026-10-01 00:00:00',
  '10月1日のデータ'
);
```

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |

2件目を追加します。

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
  'evt-0002',
  TIMESTAMP '2026-10-02 00:00:00',
  '10月2日のデータ'
);
```

レプリカ側でも、同じ2件が読めることを確認します。
データソースは `s3tablescatalog/s3tables-backup-demo-replica` に切り替えます。

```sql
SELECT * FROM "backup_demo"."sample_events" LIMIT 10;
```

レプリカのテーブルは、レプリケーションがサービスとして自動で作ります。
CloudFormation の管理外なので、Lake Formation の権限はテンプレートに書けません。
レプリカができたあとに、手動で付与します。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws lakeformation grant-permissions --region ap-northeast-1 \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --permissions ALL \
  --resource "{\"Table\":{\"CatalogId\":\"${ACCOUNT_ID}:s3tablescatalog/s3tables-backup-demo-replica\",\"DatabaseName\":\"backup_demo\",\"Name\":\"sample_events\"}}"
```

## スナップショットで巻き戻す

### 誤ったデータを入れる

意図しないデータを書き込んでしまった、という状況を作ります。

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
  'evt-0003',
  TIMESTAMP '2026-10-03 00:00:00',
  '意図せぬ書き込み'
);
```

スナップショットを確認します。
書き込みのたびに1件ずつ増え、3件あります。

```sql
SELECT snapshot_id, committed_at, operation
FROM "backup_demo"."sample_events$snapshots"
ORDER BY committed_at DESC;
```

| #   | snapshot_id         | committed_at                | operation |
| --- | ------------------- | --------------------------- | --------- |
| 1   | 4956787010492519892 | 2026-10-14 07:48:20.968 UTC | append    |
| 2   | 8927807603977148722 | 2026-10-14 07:30:14.339 UTC | append    |
| 3   | 2354428253123851466 | 2026-10-14 07:29:08.581 UTC | append    |

上から順に、evt-0003、evt-0002、evt-0001 を入れた直後のスナップショットです。
戻したい先は、evt-0002 を入れた直後の2番目です。

### Glue ジョブで巻き戻す

Athena では、スナップショットへの巻き戻しはできません。
Spark の Iceberg プロシージャ `rollback_to_snapshot` を、Glue ジョブで実行します。

事前に、テンプレートのデプロイと、スクリプトのアップロードが必要です。

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

まず、`--snapshot_id` を付けずに実行します。
このときは、スナップショットの一覧を出力するだけで、テーブルは変更しません。
出力は、CloudWatch Logs の `/aws-glue/jobs/output` に出ます。

```bash
aws glue start-job-run --region ap-northeast-1 \
  --job-name s3tables-backup-demo-rollback
```

```text
+-------------------+-----------------------+---------+
|snapshot_id        |committed_at           |operation|
+-------------------+-----------------------+---------+
|4956787010492519892|2026-10-14 07:48:20.968|append   |
|8927807603977148722|2026-10-14 07:30:14.339|append   |
|2354428253123851466|2026-10-14 07:29:08.581|append   |
+-------------------+-----------------------+---------+
```

Athena で見た一覧と同じです。
次に、戻したいスナップショットの ID を指定して、巻き戻します。

```bash
aws glue start-job-run --region ap-northeast-1 \
  --job-name s3tables-backup-demo-rollback \
  --arguments '{"--snapshot_id":"8927807603977148722"}'
```

ジョブが成功したら、テーブルの中身を確認します。
evt-0003 が消えています。

```sql
SELECT * FROM "backup_demo"."sample_events" LIMIT 10;
```

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |

### 修正したデータを入れ直す

巻き戻したあとに、正しいデータを入れ直します。

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
  'evt-0003',
  TIMESTAMP '2026-10-03 00:00:00',
  '10月3日のデータ'
);
```

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0003 | 2026-10-03 00:00:00.000000 | 10月3日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |
| 3   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |

レプリカ側も、同じ状態になっていました。
スナップショットでの巻き戻しと、そのあとの修正ができることを確認できました。

## スナップショットの保持期間と限界

スナップショットは、デフォルトで5日（120時間）保持されます。
巻き戻しができるのは、5日以内です。
設定は、次のコマンドで確認できます。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3tables get-table-maintenance-configuration \
  --region ap-northeast-1 \
  --table-bucket-arn arn:aws:s3tables:ap-northeast-1:${ACCOUNT_ID}:bucket/s3tables-backup-demo \
  --namespace backup_demo \
  --name sample_events \
  --query "configuration.icebergSnapshotManagement.settings.icebergSnapshotManagement"
```

```json
{
  "minSnapshotsToKeep": 1,
  "maxSnapshotAgeHours": 120
}
```

保持期間を無闇に延ばすと、メタデータファイルが大きくなります。
公式ドキュメントでは、レプリケーションでは、500MB を超えるメタデータファイルはサポートされません。
そのため、5日より前に戻したい場合は、S3 に退避する方法も考えます。

なお、公式ドキュメントには、レプリカ側のスナップショット保持期間を、元のテーブルと別に設定できるとあります。
そのため、元のテーブルをデフォルトの5日にし、レプリカ側だけを長くする方法も考えられます。

ただし、AWS サポートに確認したところ、レプリカ側のメタデータファイルが 500MB を超えた場合も、サポートされないとのことでした。
レプリカ側でも、保持期間を延ばすほどメタデータが大きくなります。
そのため、保持期間を多少延ばすことはできても、数か月といった長期間は難しそうです。
長期間の保持が必要な場合は、次の Parquet 退避のように、スナップショットに依存しない形で残します。

## 日ごとの差分を Parquet で S3 に退避する

### 退避の方針

日ごとの差分を、Athena の `UNLOAD` で S3 に Parquet として出力します。
差分とは、その日の `event_time` の行だけです。
復元するときは、日付を指定して、その日までの退避データでテーブル全体を置き換えます。

退避先の S3 バケットとワークグループは、`templates/athena-parquet-backup.yaml` で作成します。

```bash
aws cloudformation deploy \
  --template-file templates/athena-parquet-backup.yaml \
  --stack-name s3tables-backup-demo-athena \
  --region ap-northeast-1
```

退避先は、次のレイアウトになります。

```text
s3://s3tables-backup-demo-export-<ACCOUNT_ID>-ap-northeast-1/backup/sample_events/dt=2026-10-01/*.parquet
```

### 1日分を退避する

10/1 のデータを退避します。
ワークグループは `s3tables-backup-demo`、データソースは `s3tablescatalog/s3tables-backup-demo` です。
`<ACCOUNT_ID>` は、自分のアカウント ID に置き換えます。

```sql
UNLOAD (
  SELECT
    event_id,
    CAST(event_time AS varchar) AS event_time,
    message,
    CAST(date(event_time) AS varchar) AS dt
  FROM "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
  WHERE event_time >= TIMESTAMP '2026-10-01 00:00:00'
    AND event_time <  TIMESTAMP '2026-10-02 00:00:00'
)
TO 's3://s3tables-backup-demo-export-<ACCOUNT_ID>-ap-northeast-1/backup/sample_events/'
WITH (
  format = 'PARQUET',
  compression = 'SNAPPY',
  partitioned_by = ARRAY['dt']
);
```

10/2 を退避するときは、`WHERE` の日付だけを変えます。

```sql
WHERE event_time >= TIMESTAMP '2026-10-02 00:00:00'
  AND event_time <  TIMESTAMP '2026-10-03 00:00:00'
```

10/3 も同じです。

```sql
WHERE event_time >= TIMESTAMP '2026-10-03 00:00:00'
  AND event_time <  TIMESTAMP '2026-10-04 00:00:00'
```

これで、日ごとのデータを S3 に退避できました。

### event_time を文字列で出している理由

`event_time` をそのまま出すと、次のエラーになります。

```text
NOT_SUPPORTED: Incorrect timestamp precision for timestamp(6); the configured precision is MILLISECONDS; column name: event_time
```

Iceberg のタイムスタンプはマイクロ秒精度です。
一方、Athena の `UNLOAD` が Parquet に書けるのは、ミリ秒精度までです。

`CAST(event_time AS timestamp(3))` で変換するとエラーは消えますが、ミリ秒より細かい桁は失われます。
たとえば、00:00:00.123456 も 00:00:00.123499 も、00:00:00.123 になります。
これではバックアップとして不十分です。

そこで、文字列（例: `2026-10-01 00:00:00.123456`）にして出します。
復元するときに `CAST(event_time AS timestamp(6))` で戻せば、マイクロ秒まで元どおりになります。

### 同じ日を再実行すると重複する

同じ日の `UNLOAD` を再実行すると、上書きではなく、同じフォルダにファイルが増えます。
そのまま読むと、行が重複します。
退避し直すときは、先に対象日のフォルダを削除します。

```bash
aws s3 rm s3://s3tables-backup-demo-export-<ACCOUNT_ID>-ap-northeast-1/backup/sample_events/dt=2026-10-01/ --recursive
```

### 退避データを確認する

退避したフォルダを Athena から読めるように、パーティションを読み込みます。
次の条件で実行します。

- ワークグループ: `s3tables-backup-demo`
- データソース: `AwsDataCatalog`
- データベース: `backup_demo_archive`
- カタログ: なし

```sql
MSCK REPAIR TABLE backup_demo_archive.sample_events_archive;
```

データソースが `s3tablescatalog/s3tables-backup-demo` のままだと、「Unsupported DDL query for S3 table buckets」というエラーになります。
`MSCK REPAIR TABLE` は、必ず `AwsDataCatalog` で実行します。

同じ条件のまま、次のクエリで、3行取得できることを確認します。

```sql
SELECT dt, event_id, event_time, message
FROM backup_demo_archive.sample_events_archive
ORDER BY dt;
```

## 退避データから特定の日に復元する

### 誤ったデータを入れる

復元を試すために、誤ったデータを入れます。
データソースは `s3tablescatalog/s3tables-backup-demo` です。
テーブルは4行になります。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
  (event_id, event_time, message)
VALUES ('evt-0004', TIMESTAMP '2026-10-03 00:00:00', '意図せぬ書き込み');
```

### 退避が揃っているか確認する

10/2 の状態に戻します。
その前に、10/2 までの退避が揃っているかを確認します。

```sql
SELECT dt, count(*) AS row_count
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02'
GROUP BY dt
ORDER BY dt;
```

| #   | dt         | row_count |
| --- | ---------- | --------- |
| 1   | 2026-10-01 | 1         |
| 2   | 2026-10-02 | 1         |

### 全行を削除する

10/2 の状態に戻すために、まず全行を削除します。
怖い操作ですが、`DELETE` も新しいスナップショットとして残ります。
5日以内であれば、前のスナップショットに巻き戻せます。

```sql
DELETE FROM "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events";
```

0件になったことを確認します。

```sql
SELECT * FROM "backup_demo"."sample_events" LIMIT 10;
```

### 退避データから入れ直す

10/2 までのデータを、退避先から戻します。
退避データの `event_time` は文字列なので、`timestamp(6)` に戻します。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
  (event_id, event_time, message)
SELECT event_id, CAST(event_time AS timestamp(6)), message
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02';
```

### 結果を確認する

スナップショットを確認します。
一覧は抜粋で、備考は手で付けています。

```sql
SELECT snapshot_id, committed_at, operation
FROM "backup_demo"."sample_events$snapshots"
ORDER BY committed_at DESC;
```

| #   | snapshot_id         | committed_at                | operation | 備考               |
| --- | ------------------- | --------------------------- | --------- | ------------------ |
| 1   | 7095604048887219495 | 2026-10-14 09:27:36.403 UTC | append    | 退避データから投入 |
| 2   | 346747367268830625  | 2026-10-14 09:26:17.259 UTC | delete    | 全行削除           |
| 3   | 7258320937650106173 | 2026-10-14 09:23:58.279 UTC | append    | 誤ったデータ投入   |

テーブルの中身を確認します。
evt-0003 と evt-0004 が消え、10/2 の状態に戻っています。

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |

`event_time` も、文字列から `timestamp(6)` に正しく戻りました。

## まとめ

- スナップショットは、5日（120時間）以内の巻き戻しに使えます。保持期間を延ばすと、メタデータが大きくなります。500MB を超えると、レプリケーションがサポートされません。これはレプリカ側でも同じなので、数か月といった長期間の保持は難しそうです。
- 5日より前の状態に戻すために、日ごとの差分を Athena の `UNLOAD` で S3 に Parquet として退避しました。
- 退避データがあれば、日付を指定して、テーブル全体をその日の状態に戻せます。退避データは、スナップショットに依存しません。
- 全行の削除や入れ直しも、スナップショットとして残ります。復元の操作に失敗しても、5日以内なら巻き戻せます。
- テーブル自体を誤って削除した場合は、スナップショットでは戻せません。レプリカからの復帰は、別の記事で扱います。

## 注意点

**退避の運用**

- 退避は `event_time` ベースの差分です。退避済みの日の行を後から更新または削除しても、退避データには反映されません。その日を再退避しないと、その日の状態を正確に再現できません。
- 退避は、その日が終わってから行います。日の途中に退避すると、残りの行が漏れます。
- 退避の漏れは、復元しても気づけません。復元の前に、退避済みの日の一覧（`dt` と行数）を確認します。
- 同じ日を再退避するときは、対象日のフォルダを先に削除します。
- 退避データの `event_time` は文字列です。退避データを直接調べるときは、`CAST` が必要です。

**今回の検証の範囲**

- 今回は、すべて手動で実行しました。日次の自動実行は、EventBridge Scheduler などで組む必要があります。
- 5日が経過したあとの復元は、実際には試していません。
- レプリカ側だけ保持期間を延ばす方法は、試していません。

## 参考リンク

- [How S3 Tables replication works（500MBの制限、スナップショットの保持）](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-how-replication-works.html)
- [UNLOAD（Athena）](https://docs.aws.amazon.com/athena/latest/ug/unload.html)
- [Querying Amazon S3 tables with Athena](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-integrating-athena.html)
- [Update Iceberg table data（Athena）](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-updating-iceberg-table-data.html)
