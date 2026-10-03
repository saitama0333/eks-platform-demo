package com.example.eksdemo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.exporter.otlp.trace.OtlpGrpcSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.BatchSpanProcessor;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

public final class DemoApplication {
    private static final int PORT = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
    private static final String OTEL_ENDPOINT = System.getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    private static final String SERVICE_NAME = System.getenv().getOrDefault("OTEL_SERVICE_NAME", "java-demo");
    private static final Tracer TRACER = configureTelemetry().getTracer("eks-java-demo");

    private DemoApplication() {}

    static String greeting() {
        return "Hello from the Java Maven EKS demo";
    }

    private static OpenTelemetry configureTelemetry() {
        if (OTEL_ENDPOINT == null || OTEL_ENDPOINT.isBlank()) {
            return GlobalOpenTelemetry.get();
        }

        OtlpGrpcSpanExporter exporter = OtlpGrpcSpanExporter.builder()
                .setEndpoint(OTEL_ENDPOINT)
                .setTimeout(Duration.ofSeconds(5))
                .build();
        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
                .setResource(Resource.getDefault().toBuilder()
                        .put(AttributeKey.stringKey("service.name"), SERVICE_NAME)
                        .put(AttributeKey.stringKey("deployment.environment"),
                                System.getenv().getOrDefault("ENVIRONMENT", "dev"))
                        .build())
                .addSpanProcessor(BatchSpanProcessor.builder(exporter).build())
                .build();
        return OpenTelemetrySdk.builder().setTracerProvider(tracerProvider).buildAndRegisterGlobal();
    }

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", PORT), 0);
        server.createContext("/healthz", exchange -> respond(exchange, 200, "{\"status\":\"ok\"}"));
        server.createContext("/readyz", exchange -> respond(exchange, 200, "{\"status\":\"ready\"}"));
        server.createContext("/", exchange -> {
            Span span = TRACER.spanBuilder("demo.request").startSpan();
            try (var scope = span.makeCurrent()) {
                span.setAttribute("demo.message", greeting());
                respond(exchange, 200, "{\"message\":\"" + greeting() + "\",\"service\":\"" + SERVICE_NAME + "\"}");
            } finally {
                span.end();
            }
        });
        server.start();
        System.out.println("Java demo listening on port " + PORT);
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] response = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, response.length);
        try (var output = exchange.getResponseBody()) {
            output.write(response);
        }
    }
}
