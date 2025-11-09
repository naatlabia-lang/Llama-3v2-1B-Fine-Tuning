from .gcp_logger import GCPLogger

__all__ = ["GCPLogger"]

def init_logger(*args, **kwargs):
    gl = GCPLogger(*args, **kwargs)
    gl.init()
    return gl.get_logger()