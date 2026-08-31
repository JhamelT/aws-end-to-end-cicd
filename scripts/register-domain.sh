#!/usr/bin/env bash
# Register a domain through Route 53 Domains (always us-east-1) and wait for the
# hosted zone. Contact details come from environment variables so nothing
# personal is committed.
#
#   FIRST_NAME=... LAST_NAME=... EMAIL=... PHONE="+1.5555555555" \
#   ADDRESS="..." CITY="..." STATE="MD" ZIP="..." COUNTRY="US" \
#   scripts/register-domain.sh jhamelthorne.cloud
set -euo pipefail

DOMAIN="${1:?usage: register-domain.sh <domain>}"
for v in FIRST_NAME LAST_NAME EMAIL PHONE ADDRESS CITY STATE ZIP COUNTRY; do
  [[ -n "${!v:-}" ]] || { echo "missing \$$v" >&2; exit 1; }
done

echo "==> checking availability of ${DOMAIN}"
AVAIL="$(aws route53domains check-domain-availability --region us-east-1 --domain-name "$DOMAIN" --query Availability --output text)"
echo "    ${AVAIL}"
[[ "$AVAIL" == "AVAILABLE" ]] || exit 1

CONTACT="$(cat <<EOF
{"FirstName":"${FIRST_NAME}","LastName":"${LAST_NAME}","ContactType":"PERSON","AddressLine1":"${ADDRESS}",
 "City":"${CITY}","State":"${STATE}","CountryCode":"${COUNTRY}","ZipCode":"${ZIP}","PhoneNumber":"${PHONE}","Email":"${EMAIL}"}
EOF
)"

echo "==> registering ${DOMAIN} (1 year, auto-renew off, privacy on)"
OP="$(aws route53domains register-domain --region us-east-1 \
  --domain-name "$DOMAIN" --duration-in-years 1 --no-auto-renew \
  --admin-contact "$CONTACT" --registrant-contact "$CONTACT" --tech-contact "$CONTACT" \
  --privacy-protect-admin-contact --privacy-protect-registrant-contact --privacy-protect-tech-contact \
  --query OperationId --output text)"
echo "    operation ${OP}"

echo "==> waiting for registration to complete (typically 5-15 min)"
while true; do
  STATUS="$(aws route53domains get-operation-detail --region us-east-1 --operation-id "$OP" --query Status --output text)"
  echo "    $(date +%H:%M:%S) ${STATUS}"
  case "$STATUS" in
    SUCCESSFUL) break ;;
    ERROR|FAILED) aws route53domains get-operation-detail --region us-east-1 --operation-id "$OP"; exit 1 ;;
  esac
  sleep 30
done

echo "==> hosted zone"
aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].{Id:Id,Name:Name}' --output table
