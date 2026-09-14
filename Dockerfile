# syntax=docker/dockerfile:1.7

FROM maven:3.9.11-eclipse-temurin-21-alpine AS dependencies

WORKDIR /app

COPY pom.xml .

RUN --mount=type=cache,id=eureka-service-maven-repository,target=/root/.m2/repository \
    --mount=type=secret,id=maven_settings,target=/root/.m2/settings.xml,required=true \
    mvn -s /root/.m2/settings.xml -B -ntp dependency:go-offline

FROM dependencies AS test

COPY src ./src

RUN --mount=type=cache,id=eureka-service-maven-repository,target=/root/.m2/repository \
    --mount=type=secret,id=maven_settings,target=/root/.m2/settings.xml,required=true \
    mvn -s /root/.m2/settings.xml -B -ntp test

FROM dependencies AS package

COPY src ./src

RUN --mount=type=cache,id=eureka-service-maven-repository,target=/root/.m2/repository \
    --mount=type=secret,id=maven_settings,target=/root/.m2/settings.xml,required=true \
    mvn -s /root/.m2/settings.xml -B -ntp -DskipTests package

FROM eclipse-temurin:21-jre-alpine AS runtime

WORKDIR /app

RUN addgroup -S appgroup \
    && adduser -S appuser -G appgroup \
    && mkdir -p /app/logs \
    && chown -R appuser:appgroup /app

COPY --from=package --chown=appuser:appgroup /app/target/*.jar /app/app.jar

USER appuser

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
