#!/usr/bin/env bash
# Generate the two ZITADEL bootstrap secrets and seal them against the
# repo's sealed-secrets public key. Plaintext never touches the repo or the
# terminal. See zitadel/SECRETS.md.
#
# Usage: scripts/seal-zitadel-secrets.sh [path-to-public-key.pem]
set -euo pipefail

cd "$(dirname "$0")/.."
CERT="${1:-sealed-secrets-public-key.pem}"

if [ ! -f "$CERT" ]; then
  echo "error: $CERT not found — run scripts/fetch-sealing-cert.sh first" >&2
  exit 1
fi
for tool in kubectl kubeseal openssl; do
  command -v "$tool" > /dev/null || { echo "error: $tool not installed" >&2; exit 1; }
done

# ZITADEL requires a masterkey of exactly 32 characters.
MASTERKEY=$(openssl rand -base64 32 | head -c 32)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
ZITADEL_DB_PASSWORD=$(openssl rand -hex 24)

kubectl create secret generic zitadel-masterkey \
  --namespace=zitadel \
  --from-literal=masterkey="$MASTERKEY" \
  --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" -o yaml \
  > zitadel/sealed-zitadel-masterkey.yaml

# Password of the first human. Without it ZITADEL inserts its documented
# `Password1!` and creates an immediately usable IAM_OWNER account. Random, so
# nobody knows it — and nobody needs it: §5.3 creates the administrator you use.
FIRST_ADMIN_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)!7"

kubectl create secret generic zitadel-first-admin \
  --namespace=zitadel \
  --from-literal=password="$FIRST_ADMIN_PASSWORD" \
  --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" -o yaml \
  > zitadel/sealed-zitadel-first-admin.yaml

kubectl create secret generic zitadel-db-credentials \
  --namespace=zitadel \
  --from-literal=postgresPassword="$POSTGRES_PASSWORD" \
  --from-literal=password="$ZITADEL_DB_PASSWORD" \
  --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" -o yaml \
  > zitadel/sealed-zitadel-db-credentials.yaml

echo "Wrote zitadel/sealed-zitadel-masterkey.yaml"
echo "Wrote zitadel/sealed-zitadel-first-admin.yaml"
echo "Wrote zitadel/sealed-zitadel-db-credentials.yaml"
echo "Commit both files — Argo CD will reconcile the zitadel-base Application."
