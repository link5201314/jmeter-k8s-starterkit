FROM python:3.11-slim

WORKDIR /workspace

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates bash tar gzip && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/kubectl \
    https://dl.k8s.io/release/v1.30.4/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl

RUN curl -fsSL https://get.helm.sh/helm-v3.16.1-linux-amd64.tar.gz -o /tmp/helm.tgz && \
    tar -xzf /tmp/helm.tgz -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm

COPY webapp/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY . /workspace

EXPOSE 8080

CMD ["uvicorn", "webapp.app.main:app", "--host", "0.0.0.0", "--port", "8080"]
