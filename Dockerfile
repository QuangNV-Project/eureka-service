# 1. Build stage
FROM maven:3.9.11-eclipse-temurin-21-noble AS build
WORKDIR /app

# Copy pom.xml và tải dependencies trước (cache tốt hơn)
COPY .m2/settings.xml /root/.m2/settings.xml
COPY pom.xml .
RUN mvn dependency:go-offline

# Copy source code và build
COPY src ./src
RUN mvn clean package -DskipTests

# 2. Runtime stage
FROM openjdk:21-jdk-slim
WORKDIR /app

# Copy only the JAR from build stage
COPY --from=build /app/target/*.jar app.jar

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]
