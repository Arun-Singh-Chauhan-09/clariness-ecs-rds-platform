#!/bin/sh
# Alertmanager does not expand environment variables in its config, so the
# AWS variant is rendered here from SNS_TOPIC_ARN / AWS_REGION at start-up.
set -eu
MODE="${ALERTMANAGER_MODE:-local}"
OUT=/tmp/alertmanager.yml

if [ "$MODE" = "aws" ]; then
  : "${SNS_TOPIC_ARN:?SNS_TOPIC_ARN must be set}"
  : "${AWS_REGION:?AWS_REGION must be set}"
  sed -e "s|__SNS_TOPIC_ARN__|${SNS_TOPIC_ARN}|g" \
      -e "s|__AWS_REGION__|${AWS_REGION}|g" \
      /etc/alertmanager/alertmanager.aws.yml > "$OUT"
else
  cp /etc/alertmanager/alertmanager.local.yml "$OUT"
fi

exec /bin/alertmanager --config.file="$OUT" --storage.path=/alertmanager "$@"
