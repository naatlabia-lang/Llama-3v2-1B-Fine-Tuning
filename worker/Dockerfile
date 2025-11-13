FROM python:3.11.14-slim
ENV PYTHONUNBUFFERED=1 GLOG_logtostderr=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN pip install -U pip && pip install -r /tmp/requirements.txt
COPY /src/loggin /opt/loggin
ENV PYTHONPATH="/opt:${PYTHONPATH}"
CMD ["python","-c","import torch;import ray;print('Torch', torch.__version__)"]