#!/bin/bash
# 사진을 Cloudinary에 업로드하고 URL 출력
# 사용법: ./upload.sh 파일경로 [파일경로2 ...]

set -e
source "$(dirname "$0")/.env"

for FILE in "$@"; do
  TIMESTAMP=$(date +%s)
  SIGNATURE_STR="timestamp=${TIMESTAMP}${CLOUDINARY_API_SECRET}"
  SIGNATURE=$(echo -n "$SIGNATURE_STR" | openssl dgst -sha1 | awk '{print $2}')

  echo "⬆️  업로드 중: $FILE"
  RESULT=$(curl -s -X POST \
    "https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/image/upload" \
    -F "file=@${FILE}" \
    -F "api_key=${CLOUDINARY_API_KEY}" \
    -F "timestamp=${TIMESTAMP}" \
    -F "signature=${SIGNATURE}")

  URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secure_url','ERROR'))")
  echo "✅  $URL"
done
