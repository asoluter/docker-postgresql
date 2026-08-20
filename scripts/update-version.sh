#!/usr/bin/env bash
set -eo pipefail

NEW_VERSION="${1}"
if [ -z "${NEW_VERSION}" ]; then
  NEW_VERSION=$(cat VERSION)
fi

if [ -z "${NEW_VERSION}" ]; then
  echo "Usage: ./scripts/update-version.sh <version>"
  exit 1
fi

OLD_VERSION=$(cat VERSION 2>/dev/null || echo "")
echo "${NEW_VERSION}" > VERSION

OLD_MAJOR=$(echo "${OLD_VERSION}" | cut -d. -f1)
NEW_MAJOR=$(echo "${NEW_VERSION}" | cut -d. -f1)

if [ -n "${OLD_MAJOR}" ] && [ "${OLD_MAJOR}" != "${NEW_MAJOR}" ]; then
  echo "Updating major version tags from :${OLD_MAJOR} to :${NEW_MAJOR}..."
  sed -i "s/asoluter\/postgresql:${OLD_MAJOR}/asoluter\/postgresql:${NEW_MAJOR}/g" README.md docker-compose.yml
fi

echo "Synced VERSION: ${NEW_VERSION} (Major: ${NEW_MAJOR})"
