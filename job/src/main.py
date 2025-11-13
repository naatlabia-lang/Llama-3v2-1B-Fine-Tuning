# logging_setup.py (opcional, para pruebas locales)
import torch
from loggin import init_logger

if __name__ == "__main__":
    log = init_logger(name="ray-main")
    log.info("Main arrancó")
    print("Hola Mundo desde JOB.............")
    print("PyTorch:", torch.__version__, "| CUDA disponible:", torch.cuda.is_available())
