FROM python:3.11-slim

WORKDIR /app
COPY server.py /app/server.py
COPY ui /app/ui

EXPOSE 8088
CMD ["python", "/app/server.py"]
