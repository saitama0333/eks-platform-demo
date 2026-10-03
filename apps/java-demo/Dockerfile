FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml ./
COPY src ./src
RUN mvn --batch-mode --no-transfer-progress clean package -DskipTests \
    && mvn --batch-mode --no-transfer-progress dependency:copy-dependencies \
      -DincludeScope=runtime -DoutputDirectory=target/dependency

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /workspace/target/eks-java-demo-1.0.0.jar /app/app.jar
COPY --from=build /workspace/target/dependency/ /app/lib/
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-cp", "/app/app.jar:/app/lib/*", "com.example.eksdemo.DemoApplication"]
