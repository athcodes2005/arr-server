#!/bin/sh
set -eu

ROOT_DIR="${1:-$(pwd)}"

set_xml_url_base() {
  file="$1"
  base="$2"

  if [ ! -f "$file" ]; then
    echo "skip: $file does not exist"
    return
  fi

  sed -i "s|<UrlBase>.*</UrlBase>|<UrlBase>${base}</UrlBase>|" "$file"
  echo "updated: $file -> $base"
}

set_bazarr_base_url() {
  file="$1"
  base="$2"

  if [ ! -f "$file" ]; then
    echo "skip: $file does not exist"
    return
  fi

  sed -i "s|^  base_url:.*$|  base_url: '${base}'|" "$file"
  echo "updated: $file -> $base"
}

set_xml_url_base "$ROOT_DIR/configs/prowlarr/config.xml" "/prowlarr"
set_xml_url_base "$ROOT_DIR/configs/sonarr/config.xml" "/sonarr"
set_xml_url_base "$ROOT_DIR/configs/radarr/config.xml" "/radarr"
set_bazarr_base_url "$ROOT_DIR/configs/bazarr/config/config.yaml" "/bazarr"
