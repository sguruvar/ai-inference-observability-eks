FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl && \
    curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
EXPOSE 8080
CMD ["python", "server.py"]
