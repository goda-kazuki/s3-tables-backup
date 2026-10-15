-- 指定した日の差分を、Parquet で S3 に退避する。
-- Athena のワークグループ s3tables-backup-demo で実行する。
--
-- 実行前に、次の 2 か所を書き換える。
--   1. event_time の範囲: 退避したい日の 0 時から翌日の 0 時まで
--   2. TO の <ACCOUNT_ID>: 自分のアカウント ID
--
-- dt はパーティション列。UNLOAD の仕様で、SELECT の最後に置く必要がある。
-- 出力は dt=YYYY-MM-DD/ のフォルダに分かれる。
--
-- event_time は Iceberg ではマイクロ秒精度（timestamp(6)）だが、Athena の Parquet 出力は
-- ミリ秒精度（timestamp(3)）しか書けない。そのまま出すと NOT_SUPPORTED エラーになる。
-- timestamp(3) に変換するとミリ秒未満が切り捨てられ、バックアップとして不十分になる。
-- そのため、マイクロ秒まで残る文字列（例: 2026-10-01 00:00:00.123456）にして出す。
-- 復元のときに CAST(event_time AS timestamp(6)) で元の型に戻す。
--
-- 同じ日を再実行すると、ファイルが増えて行が重複する。
-- 再退避の前に、dt=YYYY-MM-DD/ のフォルダを削除する。
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
