FROM us-docker.pkg.dev/vertex-ai/training/ray-cpu.2-47.py311:latest

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY /src/loggin /opt/loggin

ENV PYTHONPATH="/opt:${PYTHONPATH}"
