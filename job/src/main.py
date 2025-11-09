import torch
from loggin import init_logger, GCPLogger

log = init_logger(name="ray-main")
log.info("Main arrancó")

print("Hola Mundo desde JOB.............")
print("PyTorch:", torch.__version__, "| CUDA disponible:", torch.cuda.is_available())