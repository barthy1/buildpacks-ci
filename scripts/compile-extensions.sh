#!/bin/bash

set -e

echo "Using ruby version `ruby -v`"
cd compile-extensions
bundle
bundle exec rspec
