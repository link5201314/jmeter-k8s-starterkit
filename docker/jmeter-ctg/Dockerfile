FROM rbillon59/jmeter-k8s-base:5.6.3

ARG JMETER_PLUGINS_MANAGER_VERSION=1.10
ARG JPGC_CTG_VERSION=3.1.1
ARG JPGC_CMN_VERSION=0.9
ARG JOLOKIA_VERSION=2.2.9

USER root

# Download Concurrency Thread Group plugin jars directly from Maven Central at
# build time so the image has no runtime dependency on jmeter-plugins.org.
#
# Jars placed in lib/ext:
#   - jmeter-plugins-casutg   : Concurrency Thread Group (+ Arrivals Thread Group)
#   - jmeter-plugins-cmn-jmeter: common runtime dependency of casutg
#   - jmeter-plugins-manager  : optional – enables the GUI Plugin Manager tab
RUN set -eux; \
    JMETER_HOME=/opt/jmeter/apache-jmeter; \
    MAVEN="https://repo1.maven.org/maven2/kg/apc"; \
    JOLOKIA_MAVEN="https://repo1.maven.org/maven2/org/jolokia/jolokia-agent-jvm"; \
    curl -fsSL -o "$JMETER_HOME/lib/ext/jmeter-plugins-casutg-${JPGC_CTG_VERSION}.jar" \
      "${MAVEN}/jmeter-plugins-casutg/${JPGC_CTG_VERSION}/jmeter-plugins-casutg-${JPGC_CTG_VERSION}.jar"; \
    curl -fsSL -o "$JMETER_HOME/lib/ext/jmeter-plugins-cmn-jmeter-${JPGC_CMN_VERSION}.jar" \
      "${MAVEN}/jmeter-plugins-cmn-jmeter/${JPGC_CMN_VERSION}/jmeter-plugins-cmn-jmeter-${JPGC_CMN_VERSION}.jar"; \
    curl -fsSL -o "$JMETER_HOME/lib/ext/jmeter-plugins-manager-${JMETER_PLUGINS_MANAGER_VERSION}.jar" \
      "${MAVEN}/jmeter-plugins-manager/${JMETER_PLUGINS_MANAGER_VERSION}/jmeter-plugins-manager-${JMETER_PLUGINS_MANAGER_VERSION}.jar"; \
    curl -fsSL -o "$JMETER_HOME/lib/jolokia-java-agent.jar" \
      "${JOLOKIA_MAVEN}/${JOLOKIA_VERSION}/jolokia-agent-jvm-${JOLOKIA_VERSION}-javaagent.jar"; \
    find "$JMETER_HOME" -type f -name "*.sha1" -delete; \
    chown -R 1000:1000 /opt/jmeter

USER 1000
