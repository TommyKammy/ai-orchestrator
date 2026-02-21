FROM n8nio/n8n:2.8.3

USER root

COPY n8n/locales/ja.partial.json /opt/n8n-locales/ja.partial.json
COPY docker/n8n-ja/patch-locale.js /opt/n8n-locales/patch-locale.js

RUN node /opt/n8n-locales/patch-locale.js /opt/n8n-locales/ja.partial.json

USER node
