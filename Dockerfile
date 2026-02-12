# 1. Build stage
FROM maven:3.9.11-eclipse-temurin-21-alpine AS build
WORKDIR /app

# Copy pom.xml và tải dependencies trước (cache tốt hơn)
COPY .m2/settings.xml /root/.m2/settings.xml
COPY pom.xml .

# Copy source code và build
COPY src ./src
RUN mvn package -DskipTests -B

# 2. Runtime stage
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

ARG USER_ID=1001
ARG GROUP_ID=1001

# Tạo group và user với ID cụ thể
RUN addgroup -g $GROUP_ID -S appgroup && \
    adduser -u $USER_ID -S appuser -G appgroup

# Create logs directory with appropriate permissions
RUN mkdir -p /app/logs \
    && chown -R appuser:appgroup /app

# Copy only the JAR from build stage
COPY --from=build /app/target/*.jar app.jar

USER appuser

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]
