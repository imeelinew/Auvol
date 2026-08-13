#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"
project_file="${0:A:h:h}/mac/Auvol.xcodeproj/project.pbxproj"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Invalid marketing version: $version"
    exit 64
fi
if [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Build number must be a positive integer: $build"
    exit 64
fi

ruby - "$project_file" "$version" "$build" <<'RUBY'
path, version, build = ARGV
contents = File.binread(path)
build_count = contents.scan(/CURRENT_PROJECT_VERSION = [^;]+;/).length
abort "Unexpected CURRENT_PROJECT_VERSION entry count: #{build_count}" unless build_count == 2
marketing_count = 0
contents.gsub!(/(INFOPLIST_FILE = Auvol\/Info\.plist;.*?MARKETING_VERSION = )[^;]+;/m) do
  marketing_count += 1
  "#{$1}#{version};"
end
abort "Unexpected app-target MARKETING_VERSION entry count: #{marketing_count}" unless marketing_count == 2
contents.gsub!(/CURRENT_PROJECT_VERSION = [^;]+;/, "CURRENT_PROJECT_VERSION = #{build};")
File.binwrite(path, contents)
RUBY

print "Auvol version set to ${version} (${build})"
