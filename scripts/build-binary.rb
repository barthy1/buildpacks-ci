#!/usr/bin/env ruby
# encoding: utf-8

require 'yaml'
require 'digest'
require 'fileutils'

def add_ssh_key_and_update(dir, repo)
  File.write("/tmp/git_ssh_key",ENV['GIT_SSH_KEY'])
  system(<<-HEREDOC)
    eval "$(ssh-agent)"
    mkdir -p ~/.ssh
    ssh-keyscan -t rsa github.com > ~/.ssh/known_hosts

    set +x
    chmod 600 /tmp/git_ssh_key
    ssh-add -D
    ssh-add /tmp/git_ssh_key
    set -x
    cd #{dir}
    git checkout #{repo}
    git pull -r
  HEREDOC
end

def is_automated(binary)
  automated = %w(composer godep glide nginx node)
  return automated.include? binary
end

def ci_skip_for(binary)
  return !is_automated(binary)
end

# We read the <binary>-builds.yml file from the ./builds-yaml directory
# and the <binary>-built.yml from the ./built-yaml directory. This is because
# we want to use a specific version of builds.yml, but the latest version of
# built.yml

#get latest version of <binary>-built.yml
built_dir    = File.join(Dir.pwd, 'built-yaml')
add_ssh_key_and_update(built_dir, "binary-builds-test")

binary_name  = ENV['BINARY_NAME']
builds_dir   = File.join(Dir.pwd, 'builds-yaml')
builds_yaml_artifacts = File.join(Dir.pwd, 'builds-yaml-artifacts')
builds_path  = File.join(builds_dir, "#{binary_name}-builds.yml")

builds       = YAML.load_file(builds_path)
built        = YAML.load_file(File.join(built_dir, "#{binary_name}-built.yml"))

latest_build = builds[binary_name].shift
built[binary_name].push latest_build

unless latest_build
  puts "There are no new builds for #{binary_name} requested."
  exit
end

if binary_name == "composer" then
  download_url = "https://getcomposer.org/download/#{latest_build['version']}/composer.phar"
  system("curl #{download_url} -o binary-builder/composer-#{latest_build['version']}.phar") or raise "Could not download composer.phar"
  FileUtils.cp_r(Dir["binary-builder/*"], "binary-builder-artifacts/")
  FileUtils.mkdir_p('binary-builder-artifacts/final-artifact/')
  FileUtils.cp_r('binary-builder-artifacts/composer.phar', 'binary-builder-artifacts/final-artifact/')
else
  flags = "--name=#{binary_name}"
  latest_build.each_pair do |key, value|
    if key == 'md5' || key == 'sha256'
      @verification_type = key
      @verification_value = value
    elsif key == 'gpg-signature'
      @verification_type = key
      @verification_value = "\n#{value}"
    end
    flags << %( --#{key}="#{value}")
  end

  Dir.chdir('binary-builder') do
    @binary_builder_output = `./bin/binary-builder #{flags}`
    raise "Could not build" unless $?.success?
    if Dir.exist?("/tmp/x86_64-linux-gnu/")
      system('tar -zcf build.tgz -C /tmp ./x86_64-linux-gnu/') or raise "Could not create tar"
    end
  end
  FileUtils.cp_r(Dir["binary-builder/*.tgz"], "binary-builder-artifacts/")
  FileUtils.mkdir_p('binary-builder-artifacts/final-artifact/')
  FileUtils.cp_r('binary-builder-artifacts/build.tgz', 'binary-builder-artifacts/final-artifact/')
end

/^Source URL:\s(.*)$/.match(@binary_builder_output)
source_url = $1

ext = binary_name == "composer" ? "*.phar" : "-*.tgz"
filename = Dir["binary-builder/#{binary_name + ext}"].first
md5sum   = Digest::MD5.file(filename).hexdigest
shasum   = Digest::SHA256.file(filename).hexdigest
git_msg  = "Build #{binary_name} - #{latest_build['version']}\n\nfilename: #{filename}, md5: #{md5sum}, sha256: #{shasum}"
git_msg += "\n\nsource url: #{source_url}, #{@verification_type}: #{@verification_value}"
git_msg += "\n\n[ci skip]" if builds[binary_name].empty? && ci_skip_for(binary_name)

add_ssh_key_and_update(builds_dir,"binary-builds")
files_to_add=""

#don't change behavior for non-automated builds
if !is_automated(binary_name)
  File.write(builds_path, builds.to_yaml)
  files_to_add += "#{builds_path} "
end

built[binary_name][-1]["timestamp"] = Time.now.utc.to_s
built_output = File.join(builds_dir, "#{binary_name}-built.yml")
File.write(built_output, built.to_yaml)
files_to_add += built_output

Dir.chdir(builds_dir) do
  exec(<<-EOF)
    git config --global user.email "cf-buildpacks-eng@pivotal.io"
    git config --global user.name "CF Buildpacks Team CI Server"
    git add #{files_to_add}
    git commit -m "#{git_msg}"
    rsync -a #{builds_dir}/ #{builds_yaml_artifacts}
  EOF
end
