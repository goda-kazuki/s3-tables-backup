-- テーブルを、指定した日 D の状態に戻す。
-- 全行を削除し、退避データのうち dt が D 以下の行を入れ直す。D より後の日付のデータは入らない。
-- Athena のワークグループ s3tables-backup-demo で実行する。
-- Athena のエディタは 1 文ずつ実行する。下の 1 から 4 を、順に実行する。
--
-- 実行前に、D（下では 2026-10-02）を戻したい日に書き換える。2 と 4 の 2 か所にある。
--
-- S3 Tables のカタログと通常のカタログの両方を使うため、テーブル名はカタログ名から書く。
--   S3 Tables:  "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
--   退避データ:  "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"

-- 1. 退避データのパーティションを読み込む。
--    データソースを AwsDataCatalog にして実行する。S3 Tables のカタログのままだと、
--    "Unsupported DDL query for S3 table buckets" で拒否される。
--    退避したフォルダを増やしたときだけ必要。
MSCK REPAIR TABLE backup_demo_archive.sample_events_archive;

-- 2. 事前確認。D までの日が揃っているか、行数が想定どおりかを見る。
--    退避の漏れがあると、復元しても気づけないため、必ず確認する。
SELECT dt, count(*) AS row_count
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02'
GROUP BY dt
ORDER BY dt;

-- 3. 全行を削除する。
--    DELETE と 4 の INSERT は別の文のため、間で失敗するとテーブルが空になる。
--    その場合は、4 を再実行すれば戻る。
DELETE FROM "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events";

-- 4. D 以下の退避データを入れ直す。
--    退避データの event_time は文字列（マイクロ秒まで残る）なので、timestamp(6) に戻す。
INSERT INTO "s3tablescatalog/s3tables-backup-demo"."backup_demo"."sample_events"
  (event_id, event_time, message)
SELECT
  event_id,
  CAST(event_time AS timestamp(6)),
  message
FROM "AwsDataCatalog"."backup_demo_archive"."sample_events_archive"
WHERE dt <= '2026-10-02';
