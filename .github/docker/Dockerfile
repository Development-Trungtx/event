# Context is .ci-output, containing only the tested Spring Boot JAR and build outputs.
# Dependabot updates this tag+digest; review runtime updates through CI.
FROM eclipse-temurin:21-jre-jammy@sha256:1eac8b8fee11ca7d6725a48bc5d41992ed1561504ebae25490d2d062847e8269
WORKDIR /app
COPY --chown=10001:10001 app.jar /app/app.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
