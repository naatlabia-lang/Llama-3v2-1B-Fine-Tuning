# /opt/logging_setup.py
import logging, os, sys, socket

class GCPLogger:
    def __init__(self, name: str | None = None, level: int = logging.INFO, labels: dict | None = None):
        self.name = name or os.getenv("LOG_NAME", "ray-app")
        self.level = level
        self.labels = labels or {}
        self._handler = self._build_handler()
        self._configured = False

    def _build_handler(self):
        try:
            from google.cloud import logging as gcl
            client = gcl.Client()
            return gcl.handlers.CloudLoggingHandler(client, name=self.name)
        except Exception:
            return logging.StreamHandler(sys.stdout)

    def init(self):
        if self._configured:
            return self.get_logger()
        fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"
        root = logging.getLogger()
        root.handlers.clear()
        root.setLevel(self.level)
        root.addHandler(self._handler)
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(logging.Formatter(fmt))
        root.addHandler(sh)
        ctx = {
            "project": os.getenv("GOOGLE_CLOUD_PROJECT", ""),
            "region": os.getenv("REGION", ""),
            "cluster": os.getenv("RAY_CLUSTER_NAME", ""),
            "node": socket.gethostname(),
        }
        ctx.update(self.labels)
        logging.getLogger("boot").info(f"logging ready | {ctx}")
        self._configured = True
        return self.get_logger()

    def get_logger(self, logger_name: str | None = None):
        return logging.getLogger(logger_name or __name__)
    
    
