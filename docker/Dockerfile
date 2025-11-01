FROM ubuntu:22.04
WORKDIR /app

COPY entrypoint-execute-scripts-startup.sh /app/entrypoint-execute-scripts-startup.sh
COPY docker-entrypoint.d /docker-entrypoint.d
RUN ls -la /docker-entrypoint.d

ENTRYPOINT ["/app/entrypoint-execute-scripts-startup.sh"]
