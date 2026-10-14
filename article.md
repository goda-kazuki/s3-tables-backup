# タイトル

とりあえず要点メモ

CloudFormation を実行して、テーブルが作成されたことを確認。

Athenaでクエリも確認済み

以下クエリで結果０になることを確認
SELECT * FROM "backup_demo"."sample_events" limit 10;

まずは1レコード追加する
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0001',
TIMESTAMP '2026-10-01 00:00:00',
'10月1日のデータ'
);

結果

# event_id event_time message

1 evt-0001 2026-10-01 00:00:00.000000 10月1日のデータ

次のレコードを追加
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0002',
TIMESTAMP '2026-10-02 00:00:00',
'10月2日のデータ'
);

レプリケーション先で以下クエリを実行すると、レプリケーション元と同じ２レコードの存在を確認
SELECT * FROM "backup_demo"."sample_events" limit 10;

誤ったデータを投入
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0003',
TIMESTAMP '2026-10-03 00:00:00',
'意図せぬ書き込み'
);

以下のクエリでスナップショットを確認
SELECT snapshot_id, committed_at, operation
FROM "backup_demo"."sample_events$snapshots"
ORDER BY committed_at DESC;

結果
３件追加されていることを確認

# snapshot_id committed_at operation

1 4956787010492519892 2026-10-14 07:48:20.968 UTC append
2 8927807603977148722 2026-10-14 07:30:14.339 UTC append
3 2354428253123851466 2026-10-14 07:29:08.581 UTC append

Glue Job を実行
aws glue start-job-run --region ap-northeast-1 \
--job-name s3tables-backup-demo-rollback

ジョブの結果

+-------------------+-----------------------+---------+
|snapshot_id |committed_at |operation|
+-------------------+-----------------------+---------+
|4956787010492519892|2026-10-14 07:48:20.968|append |
|8927807603977148722|2026-10-14 07:30:14.339|append |
|2354428253123851466|2026-10-14 07:29:08.581|append |
+-------------------+-----------------------+---------+

巻き戻しの実行

aws glue start-job-run --region ap-northeast-1 \
--job-name s3tables-backup-demo-rollback \
--arguments '{"--snapshot_id":"8927807603977148722"}'

成功後にクエリで確認
SELECT * FROM "backup_demo"."sample_events" limit 10;

結果（evt-0003が消えていることを確認）

# event_id event_time message

1 evt-0001 2026-10-01 00:00:00.000000 10月1日のデータ
2 evt-0002 2026-10-02 00:00:00.000000 10月2日のデータ

修正したデータを投入
INSERT INTO "backup_demo"."sample_events" (event_id, event_time, message)
VALUES (
'evt-0003',
TIMESTAMP '2026-10-03 00:00:00',
'10月3日のデータ'
);

確認
SELECT * FROM "backup_demo"."sample_events" limit 10;

結果

# event_id event_time message

1 evt-0003 2026-10-03 00:00:00.000000 10月3日のデータ
2 evt-0002 2026-10-02 00:00:00.000000 10月2日のデータ
3 evt-0001 2026-10-01 00:00:00.000000 10月1日のデータ

これでスナップショットからの巻き戻しと、その後の修正ができることを確認しました。

スナップショットはデフォルトでは5日(120時間)保持されるので、5日以内であれば巻き戻しが可能です。

確認方法
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3tables get-table-maintenance-configuration \
--region ap-northeast-1 \
--table-bucket-arn arn:aws:s3tables:ap-northeast-1:${ACCOUNT_ID}:bucket/s3tables-backup-demo \
--namespace backup_demo \
--name sample_events \
--query "configuration.icebergSnapshotManagement.settings.icebergSnapshotManagement"

レスポンス
{
"minSnapshotsToKeep": 1,
"maxSnapshotAgeHours": 120
}
