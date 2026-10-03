import os
from pathlib import Path

from flask import Flask, jsonify
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

app = Flask(__name__)

if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": os.getenv("OTEL_SERVICE_NAME", "python-demo"),
                "deployment.environment": os.getenv("ENVIRONMENT", "dev"),
            }
        )
    )
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/readyz")
def readyz():
    return jsonify(status="ready")


@app.get("/persistent")
def persistent():
    """Increment a per-pod counter stored on its EBS-backed claim."""
    data_file = Path(os.getenv("PERSISTENCE_FILE", "/tmp/python-demo-count"))
    data_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        count = int(data_file.read_text())
    except FileNotFoundError:
        count = 0
    count += 1
    data_file.write_text(str(count))
    return jsonify(pod=os.getenv("HOSTNAME", "local"), persistent_request_count=count)


@app.get("/")
def index():
    with tracer.start_as_current_span("demo.request") as span:
        span.set_attribute("demo.message", "hello from python")
        return jsonify(
            message="Hello from the Python EKS demo",
            service=os.getenv("OTEL_SERVICE_NAME", "python-demo"),
            trace_export_enabled=bool(os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
        )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
