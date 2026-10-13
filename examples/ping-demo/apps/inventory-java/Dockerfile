# Ping demo inventory service -- Java 21 (JDK only), packaged as an ordinary versioned executable jar
# (Main-Class in the MANIFEST, no Implementation-Title), so the agent's autoname derives "inventory"
# from `java -jar /app/inventory-<version>.jar`. The runtime is a jlink'd JRE (HotSpot, glibc) to keep
# the image small; the launcher is still `java`. The extra modules keep the runtime attachable:
# java.instrument + java.logging are what OBI's Java agent (TLS telemetry) needs -- without
# java.logging the attach fails with "return code: 102" -- and jdk.attach/jcmd/management are kept
# for the usual attach/diagnostics tooling.
ARG VERSION=0.4.0
FROM eclipse-temurin:21-jdk AS build
ARG VERSION
WORKDIR /src
COPY Main.java .
RUN javac -d /classes Main.java \
 && mkdir /out && jar --create --file /out/inventory-${VERSION}.jar --main-class Main -C /classes . \
 && jlink --add-modules "$(jdeps --print-module-deps --ignore-missing-deps /out/inventory-${VERSION}.jar),jdk.crypto.ec,java.instrument,java.logging,jdk.attach,jdk.unsupported,jdk.management,jdk.jcmd" \
          --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output /jre \
 && keytool -genkeypair -alias ping -keyalg EC -groupname secp256r1 -dname CN=ping -validity 3650 \
          -storetype PKCS12 -keystore /out/tls.p12 -storepass changeit -keypass changeit \
 && /jre/bin/java --list-modules

FROM debian:12-slim
ARG VERSION
ENV JAVA_HOME=/opt/java PATH=/opt/java/bin:$PATH
COPY --from=build /jre /opt/java
WORKDIR /app
COPY --from=build /out/inventory-${VERSION}.jar /out/tls.p12 /app/
# The ENTRYPOINT is exec-form, so the jar name is spelled out; keep it in step with VERSION.
ENV PORT=8000 ROLE=inventory PROFILE=healthy USE_TLS=0 CPU_SHARE=0
EXPOSE 8000
# allowRestrictedHeaders=host lets HttpClient set the logical Host header (also set in code).
ENTRYPOINT ["java", "-XX:+UseSerialGC", "-Xmx192m", "-Djdk.httpclient.allowRestrictedHeaders=host", "-jar", "/app/inventory-0.4.0.jar"]
