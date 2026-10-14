# s3-tables-backup

Amazon S3 Tables のバックアップについてのブログ記事と、検証用テンプレートを管理するリポジトリ。

- `article.md` 記事（Markdown）
- `templates/` CloudFormation / AWS SAM テンプレート
- `images/` 記事で使う画像

## テンプレートのデプロイ

`templates/s3tables-basic.yaml` は、テーブルバケット `s3tables-backup-demo`、名前空間 `backup_demo`、テーブル `sample_events` を作成する。

```bash
# デプロイ
aws cloudformation deploy \
  --template-file templates/s3tables-basic.yaml \
  --stack-name s3tables-backup-demo
```

### 削除

S3 Tables は課金対象のため、検証後はスタックを削除する。

```bash
aws cloudformation delete-stack \
  --stack-name s3tables-backup-demo \
  --region ap-northeast-1
```
