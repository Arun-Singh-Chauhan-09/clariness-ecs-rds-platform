FROM prom/alertmanager:v0.35.0
COPY alertmanager.local.yml alertmanager.aws.yml /etc/alertmanager/
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
