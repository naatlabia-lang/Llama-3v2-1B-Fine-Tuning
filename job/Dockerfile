FROM python:3.11-slim

ARG TORCH_DEVICE=cpu   # cpu | cu121
ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && pip install -r /app/requirements.txt

RUN if [ "$TORCH_DEVICE" = "cpu" ]; then \
      pip install --extra-index-url https://download.pytorch.org/whl/cpu \
        torch==2.4.1+cpu torchvision==0.19.1+cpu torchaudio==2.4.1+cpu ; \
    elif [ "$TORCH_DEVICE" = "cu121" ]; then \
      pip install --extra-index-url https://download.pytorch.org/whl/cu121 \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 torchaudio==2.4.1+cu121 ; \
    else \
      echo "Valor TORCH_DEVICE inválido (usa cpu|cu121)"; exit 1; \
    fi

COPY src/ /app/
CMD ["python", "main.py"]
