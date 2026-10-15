# Amazon S3 Tables のバックアップ方法を試してみた。レプリケーション、スナップショット、Parquet 退避

## テーブルの作成とレプリケーションの確認

CloudFormation を実行して、テーブルが作成されたことを確認。

Athenaでクエリも確認済み

以下クエリで結果０になることを確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

まずは1レコード追加する

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0001',
TIMESTAMP '2026-10-01 00:00:00',
'10月1日のデータ'
);
```

結果

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |

次のレコードを追加

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0002',
TIMESTAMP '2026-10-02 00:00:00',
'10月2日のデータ'
);
```

レプリケーション先で以下クエリを実行すると、レプリケーション元と同じ２レコードの存在を確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

## スナップショットからの巻き戻し

誤ったデータを投入

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0003',
TIMESTAMP '2026-10-03 00:00:00',
'意図せぬ書き込み'
);
```

以下のクエリでスナップショットを確認

```sql
SELECT snapshot_id, committed_at, operation
FROM "backup_demo"."sample_events$snapshots"
ORDER BY committed_at DESC;
```

結果
３件追加されていることを確認

| #   | snapshot_id         | committed_at                | operation |
| --- | ------------------- | --------------------------- | --------- |
| 1   | 4956787010492519892 | 2026-10-14 07:48:20.968 UTC | append    |
| 2   | 8927807603977148722 | 2026-10-14 07:30:14.339 UTC | append    |
| 3   | 2354428253123851466 | 2026-10-14 07:29:08.581 UTC | append    |

Glue Job を実行

```bash
aws glue start-job-run --region ap-northeast-1 \
--job-name s3tables-backup-demo-rollback
```

ジョブの結果

```text
+-------------------+-----------------------+---------+
|snapshot_id        |committed_at           |operation|
+-------------------+-----------------------+---------+
|4956787010492519892|2026-10-14 07:48:20.968|append   |
|8927807603977148722|2026-10-14 07:30:14.339|append   |
|2354428253123851466|2026-10-14 07:29:08.581|append   |
+-------------------+-----------------------+---------+
```

巻き戻しの実行

```bash
aws glue start-job-run --region ap-northeast-1 \
--job-name s3tables-backup-demo-rollback \
--arguments '{"--snapshot_id":"8927807603977148722"}'
```

成功後にクエリで確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

結果（evt-0003が消えていることを確認）

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |

修正したデータを投入

```sql
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0003',
TIMESTAMP '2026-10-03 00:00:00',
'10月3日のデータ'
);
```

確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

結果

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0003 | 2026-10-03 00:00:00.000000 | 10月3日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |
| 3   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |

レプリカ側も同じ状態になっていることを確認しました。
これでスナップショットからの巻き戻しと、その後の修正ができることを確認しました。

## スナップショットの保持期間と限界

スナップショットはデフォルトでは5日(120時間)保持されるので、5日以内であれば巻き戻しが可能です。

確認方法

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3tables get-table-maintenance-configuration \
--region ap-northeast-1 \
--table-bucket-arn arn:aws:s3tables:ap-northeast-1:${ACCOUNT_ID}:bucket/s3tables-backup-demo \
--namespace backup_demo \
--name sample_events \
--query "configuration.icebergSnapshotManagement.settings.icebergSnapshotManagement"
```

レスポンス

```json
{
  "minSnapshotsToKeep": 1,
  "maxSnapshotAgeHours": 120
}
```

スナップショットの時間を無闇に伸ばすと、メタデータファイルの大きさが大きくなり、500MBを超えるとレプリケーションが失敗するようになります。
公式ドキュメントにも、「500MBを超えるメタデータファイルはサポートされない」と書かれています。

そのため、S3に退避するような形も考えてみます。

## 日ごとの差分を Parquet で S3 に退避する

日ごとの差分（その日の event_time の行だけ）を、Athena の UNLOAD で S3 に Parquet として出力します。
復元するときは、日付を指定して、その日までの退避データでテーブル全体を置き換えます。

退避先のバケットとワークグループは、templates/athena-parquet-backup.yaml で作成します。

```sql
UNLOAD (
SELECT
event_id,
CAST(event_time AS varchar) AS event_time,
message,
CAST(date(event_time) AS varchar) AS dt
FROM "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
WHERE event_time >= TIMESTAMP '2026-10-01 00:00:00'
AND event_time < TIMESTAMP '2026-10-02 00:00:00'
)
TO 's3://s3tables-backup-demo-export-{アカウントID}-ap-northeast-1/backup/sample_events/'
WITH (
format = 'PARQUET',
compression = 'SNAPPY',
partitioned_by = ARRAY['dt']
);
```

10/2 のデータの場合は、日付を変更

```sql
WHERE event_time >= TIMESTAMP '2026-10-02 00:00:00'
AND event_time < TIMESTAMP '2026-10-03 00:00:00'
```

10/3 のデータの場合は、日付を変更

```sql
WHERE event_time >= TIMESTAMP '2026-10-03 00:00:00'
AND event_time < TIMESTAMP '2026-10-04 00:00:00'
```

これで、日ごとのデータをS3に退避することができました。

### event_time を文字列で出している理由

event_time をそのまま出すと、次のエラーになります。

```text
NOT_SUPPORTED: Incorrect timestamp precision for timestamp(6); the configured precision is MILLISECONDS; column name: event_time
```

Iceberg のタイムスタンプはマイクロ秒精度ですが、Athena の UNLOAD が Parquet に書けるのはミリ秒精度までです。
CAST(event_time AS timestamp(3)) で変換すると通りますが、ミリ秒より細かい桁は切り捨てられます。
たとえば 00:00:00.123456 も 00:00:00.123567 も、00:00:00.123 になります。
これではバックアップとして不十分なので、文字列（例: 2026-10-01 00:00:00.123456）にして出します。
復元するときに CAST(event_time AS timestamp(6)) で元の型に戻すと、マイクロ秒まで戻ります。

### 同じ日を再実行すると重複する

同じ日の UNLOAD を再実行すると、上書きではなく、同じフォルダにファイルが増えます。
そのまま読むと行が重複します。
退避し直すときは、先に対象日のフォルダを削除します。

```bash
aws s3 rm s3://s3tables-backup-demo-export-{アカウントID}-ap-northeast-1/backup/sample_events/dt=2026-10-01/ --recursive
```

### 退避データの確認

パーティションを読み込みたいので、
ワークグループは s3tables-backup-demo、データソースは AwsDataCatalog、データベースは backup_demo_archive、カタログはなしで、クエリを実行する。

```sql
MSCK REPAIR TABLE backup_demo_archive.sample_events_archive;
```

データソースが s3tablescatalog/s3tables-backup-demo のままだと、
「Unsupported DDL query for S3 table buckets」というエラーになります。
MSCK REPAIR TABLE は、AwsDataCatalog で実行します。

同じ状態で、以下のクエリを実行し、３行のデータが取得できることを確認する。

```sql
SELECT dt, event_id, event_time, message
FROM backup_demo_archive.sample_events_archive
ORDER BY dt;
```

## 退避データから特定の日に復元する

次に誤ったデータを入れてみます。テーブルは４行になります。
カタログはs3tablescatalog/s3tables-backup-demoを選択します。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
(event_id, event_time, message)
VALUES ('evt-0004', TIMESTAMP '2026-10-03 00:00:00', '意図せぬ書き込み');
```

10/2 のデータに戻したいと思うので
退避が揃っているか確認します。

```sql
SELECT dt, count(*) AS row_count
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02'
GROUP BY dt
ORDER BY dt;
```

結果

| #   | dt         | row_count |
| --- | ---------- | --------- |
| 1   | 2026-10-01 | 1         |
| 2   | 2026-10-02 | 1         |

10/2 のデータに戻すために、全行を削除します。
ちょっと怖いんですが、スナップショットがあるので、戻すことは可能です。
DELETE も新しいスナップショットとして残るため、5日以内であれば、前のスナップショットに巻き戻せます。
ただし、DELETE から次の INSERT までの間、テーブルは空になります。
他に読み書きする人がいない状態で行ってください。

```sql
DELETE FROM "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events";
```

レコードが0件になったことを確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

10/2 までのデータを退避先から戻します。

```sql
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
(event_id, event_time, message)
SELECT event_id, CAST(event_time AS timestamp(6)), message
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02';
```

レコードが2件になったことを確認

```sql
SELECT * FROM "backup_demo"."sample_events" limit 10;
```

スナップショットを確認

```sql
SELECT snapshot_id, committed_at, operation
FROM "backup_demo"."sample_events$snapshots"
ORDER BY committed_at DESC;
```

結果（抜粋してます）

| #   | snapshot_id         | committed_at                | operation | 備考                 |
| --- | ------------------- | --------------------------- | --------- | -------------------- |
| 1   | 7095604048887219495 | 2026-10-14 09:27:36.403 UTC | append    | バックアップから投入 |
| 2   | 346747367268830625  | 2026-10-14 09:26:17.259 UTC | delete    | 全行削除             |
| 3   | 7258320937650106173 | 2026-10-14 09:23:58.279 UTC | append    | 誤ったデータ投入     |

最後にテーブルの中身を確認すると、evt-0003 と evt-0004 が消え、10/2 の状態に戻っています。

| #   | event_id | event_time                 | message         |
| --- | -------- | -------------------------- | --------------- |
| 1   | evt-0001 | 2026-10-01 00:00:00.000000 | 10月1日のデータ |
| 2   | evt-0002 | 2026-10-02 00:00:00.000000 | 10月2日のデータ |

event_time も、文字列から timestamp(6) に正しく戻っています。

## まとめ

- スナップショットは、5日（120時間）以内の巻き戻しに使えます。保持期間を延ばすと、メタデータが大きくなり、500MBを超えるとレプリケーションが失敗します。
- 5日より前の状態に戻すために、日ごとの差分を Athena の UNLOAD で S3 に Parquet として退避しました。
- 退避データがあれば、日付を指定して、テーブル全体をその日の状態に戻せます。退避データはスナップショットに依存しません。
- 全行の削除や入れ直しも、スナップショットとして残ります。復元の操作に失敗しても、5日以内なら巻き戻せます。
- テーブル自体を誤って削除した場合は、スナップショットでは戻せません。レプリカからの復帰は、別の記事で扱います。

## 注意点

- 退避は event_time ベースの差分です。退避済みの日の行を後から更新または削除しても、退避データには反映されません。その日を再退避しないと、その日の状態を正確に再現できません。
- 退避は、その日が終わってから行います。日の途中に退避すると、残りの行が漏れます。
- 退避の漏れは、復元しても気づけません。復元の前に、退避済みの日の一覧（dt と行数）を確認します。
- DELETE と INSERT は別の文です。間で失敗するとテーブルが空になりますが、INSERT を再実行すれば戻ります。
- 同じ日を再退避するときは、対象日のフォルダを先に削除します。
- 退避データの event_time は文字列です。退避データを直接調べるときは、CAST が必要です。
- 今回は手動で実行しました。5日経過後の復元は、実際には試していません。日次の自動実行は、EventBridge Scheduler などで組む必要があります。

## 後片付け

S3 Tables とバケットは課金対象です。検証後は、スタックを削除します。
退避先のバケットは、空にしてからスタックを削除します。手順はリポジトリの README にあります。

## 参考リンク

- [How S3 Tables replication works（500MBの制限、スナップショットの保持）](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-how-replication-works.html)
- [UNLOAD（Athena）](https://docs.aws.amazon.com/athena/latest/ug/unload.html)
- [Querying Amazon S3 tables with Athena](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-integrating-athena.html)
- [Update Iceberg table data（Athena）](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-updating-iceberg-table-data.html)
