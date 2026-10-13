#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

CLASSPATH="$ROOT/build/classes:$ROOT/build/test-classes"
for test_class in \
  com.bree.raw.CodecTest \
  com.bree.raw.SocketDiscoveryTest \
  com.bree.raw.GeneratedCoverageTest \
  com.bree.raw.GeneratedModelTest \
  com.bree.raw.StreamModeTest \
  com.bree.raw.LifecycleTest \
  com.bree.raw.ErgonomicsTest \
  com.bree.internal.UnixTransportTest \
  com.bree.ResourceApiTest \
  com.bree.BrowserPointerFrameTest
do
  java -ea -cp "$CLASSPATH" "$test_class"
done

java -ea \
  -cp "$ROOT/build/bree-java-sdk.jar:$ROOT/build/consumer-test-classes" \
  com.bree.consumer.ExternalJarConsumerTest
