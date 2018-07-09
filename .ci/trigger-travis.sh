#!/bin/sh -f

USER=Kong
REPO=kong-distributions
TOKEN=$1
MESSAGE=",\"message\": \"Triggered by upstream build of Kong/kong commit "`git rev-parse --short HEAD`"\""

body="{
\"request\": {
  \"branch\":\"master\",
  \"config\": {
    \"merge_mode\": \"deep_merge\",
    \"env\": {
      \"matrix\": [
        \"BUILD_RELEASE=true PLATFORM=centos:6\",
        \"BUILD_RELEASE=true PLATFORM=centos:7\",
        \"BUILD_RELEASE=true PLATFORM=debian:7\",
        \"BUILD_RELEASE=true PLATFORM=debian:8\",
        \"BUILD_RELEASE=true PLATFORM=debian:9\",
        \"BUILD_RELEASE=true PLATFORM=ubuntu:12.04.5\",
        \"BUILD_RELEASE=true PLATFORM=ubuntu:14.04.2\",
        \"BUILD_RELEASE=true PLATFORM=ubuntu:16.04\",
        \"BUILD_RELEASE=true PLATFORM=amazonlinux\",
        \"BUILD_RELEASE=true PLATFORM=alpine\"
      ]
    }
  }
  $MESSAGE
}}"

## For debugging:
echo "USER=$USER"
echo "REPO=$REPO"
echo "TOKEN=$TOKEN"
echo "MESSAGE=$MESSAGE"
echo "BODY=$body"
# It does not work to put / in place of %2F in the URL below.  I'm not sure why.
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Travis-API-Version: 3" \
  -H "Authorization: token ${TOKEN}" \
  -d "$body" \
  https://api.travis-ci.com/repo/${USER}%2F${REPO}/requests \
    | tee /tmp/travis-request-output.$$.txt

if grep -q '"@type": "error"' /tmp/travis-request-output.$$.txt; then
    exit 1
fi
if grep -q 'access denied' /tmp/travis-request-output.$$.txt; then
    exit 1
fi
