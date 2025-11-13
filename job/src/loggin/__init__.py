# loggin/__init__.py
from .gcp_logger import GCPLogger

def init_logger(name: str = "ray-app", **kwargs):
    return GCPLogger(name=name, **kwargs).init()
