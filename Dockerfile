FROM openjdk:17-jdk-slim

WORKDIR /app
# Install curl (needed for HEALTHCHECK)
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Copy the JAR file
COPY target/eureka-server-*.jar app.jar

# Expose port
EXPOSE 8761

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8761/actuator/health || exit 1

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]
