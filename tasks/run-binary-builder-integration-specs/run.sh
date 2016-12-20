#!/bin/bash -l

set -o errexit
set -o nounset
set -o pipefail

set -x

pushd binary-builder
  if [ ! -z "$RUBYGEM_MIRROR" ]; then
    gem sources --clear-all --add "${RUBYGEM_MIRROR}"
  fi
  gem install bundler --no-ri --no-rdoc

  if [ ! -z "$RUBYGEM_MIRROR" ]; then
    bundle config mirror.https://rubygems.org "${RUBYGEM_MIRROR}"
  fi

  bundle install --jobs="$(nproc)"
  exclude=""
  if [ ${EXCLUDE_ON_PPC64LE-false} = "true" ]; then
    exclude="--tag ~exclude_on_ppc64le"
  fi

  if [ "${RUN_ORACLE_PHP_TESTS-false}" = "true" ]; then
    apt-get update && apt-get -y install awscli
    BINARY_BUILDER_PLATFORM=${BINARY_BUILDER_PLATFORM} BINARY_BUILDER_OS_NAME=${BINARY_BUILDER_OS_NAME} bundle exec rspec spec/integration/${SPEC_TO_RUN}_spec.rb ${exclude}
  else
    BINARY_BUILDER_PLATFORM=${BINARY_BUILDER_PLATFORM} BINARY_BUILDER_OS_NAME=${BINARY_BUILDER_OS_NAME} bundle exec rspec spec/integration/${SPEC_TO_RUN}_spec.rb ${exclude} --tag ~run_oracle_php_tests
  fi
popd
