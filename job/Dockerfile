FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 GLOG_logtostderr=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential && rm -rf /var/lib/apt/lists/*
COPY requirements-job.txt /tmp/requirements.txt
RUN pip install -U pip && pip install -r /tmp/requirements.txt
# Logging helper (opcional)
COPY /src/loggin /opt/loggin
ENV PYTHONPATH="/opt:${PYTHONPATH}"
CMD ["python","-c","import ray; print('Ray', ray.__version__)"]
