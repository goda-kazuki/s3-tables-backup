"""S3 Tables のテーブルを、指定したスナップショットの状態に巻き戻す Glue ジョブ。

--snapshot_id を指定しない場合は、スナップショット一覧と行数を表示するだけで、
テーブルは変更しない（ドライラン）。
--snapshot_id を指定した場合は、Iceberg の rollback_to_snapshot を実行する。
"""
import sys

from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession

REQUIRED_ARGS = ["account_id", "table_bucket_name", "namespace", "table_name"]
OPTIONAL_ARGS = ["snapshot_id"]

# getResolvedOptions は未指定の引数があるとエラーになるため、
# 任意引数は実際に渡されたものだけを解決対象に加える。
passed_optional = [k for k in OPTIONAL_ARGS if f"--{k}" in sys.argv]
args = getResolvedOptions(sys.argv, REQUIRED_ARGS + passed_optional)

CATALOG = "s3tables"
table = f"{args['namespace']}.{args['table_name']}"
qualified_table = f"{CATALOG}.{table}"

# S3 Tables と AWS 分析サービスの統合（s3tablescatalog）経由で接続する。
spark = (
    SparkSession.builder.appName("s3tables-rollback-to-snapshot")
    .config(
        "spark.sql.extensions",
        "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    )
    .config("spark.sql.defaultCatalog", CATALOG)
    .config(f"spark.sql.catalog.{CATALOG}", "org.apache.iceberg.spark.SparkCatalog")
    .config(
        f"spark.sql.catalog.{CATALOG}.catalog-impl",
        "org.apache.iceberg.aws.glue.GlueCatalog",
    )
    .config(
        f"spark.sql.catalog.{CATALOG}.glue.id",
        f"{args['account_id']}:s3tablescatalog/{args['table_bucket_name']}",
    )
    .config(
        f"spark.sql.catalog.{CATALOG}.warehouse",
        f"s3://{args['table_bucket_name']}/warehouse/",
    )
    .getOrCreate()
)


def show_state(label):
    print(f"===== {label} =====")
    spark.sql(
        f"SELECT snapshot_id, committed_at, operation "
        f"FROM {qualified_table}.snapshots ORDER BY committed_at DESC"
    ).show(truncate=False)
    count = spark.sql(f"SELECT count(*) AS row_count FROM {qualified_table}")
    count.show()


show_state("巻き戻し前")

if "snapshot_id" not in args:
    print("--snapshot_id が未指定のため、テーブルは変更しません。")
else:
    snapshot_id = int(args["snapshot_id"])
    print(f"スナップショット {snapshot_id} に巻き戻します。")
    spark.sql(
        f"CALL {CATALOG}.system.rollback_to_snapshot('{table}', {snapshot_id})"
    ).show(truncate=False)
    show_state("巻き戻し後")
