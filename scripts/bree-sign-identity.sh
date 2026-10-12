#!/usr/bin/env bash
# Prints the codesign identity for local Bree builds: the self-signed
# "Bree Local Code Signing" certificate when it is in the keychain, else "-" (ad hoc).
# A stable certificate keeps the designated requirement (and so macOS TCC grants)
# the same across rebuilds; ad hoc signing changes the cdhash on every build.
if /usr/bin/security find-identity -p codesigning 2>/dev/null | grep -q '"Bree Local Code Signing"'; then
  echo "Bree Local Code Signing"
else
  echo "-"
fi
