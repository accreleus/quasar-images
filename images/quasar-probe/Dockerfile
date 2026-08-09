# Minimal template image — proves the P4 agent-side build path end to end.
# Deliberately trivial and fast: no package installs, just a labelled scratch-ish layer.
FROM alpine:3.20
ARG QUASAR_PROBE_TAG=unset
LABEL org.quasar.image="quasar-probe" \
      org.quasar.built-by="node-agent template build (P4)" \
      org.quasar.probe-tag="${QUASAR_PROBE_TAG}"
RUN echo "quasar-probe template build ok" > /quasar-probe.txt
CMD ["cat", "/quasar-probe.txt"]
