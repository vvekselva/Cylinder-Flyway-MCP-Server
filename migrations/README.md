# Governed migrations

The Docker build populates this directory with the exact governed V1–V17 files from frozen CylinderManagement commit:

`3ae6e61442132d94a307275b08dd65fcef228d89`

The files are downloaded and Git-blob-SHA verified by `scripts/fetch-migrations.sh` using `migration-manifest.csv`.

Do not manually edit the generated migration SQL files in the container image.
