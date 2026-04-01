#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-textures}"
MAX_DIMENSION="${MAX_DIMENSION:-4096}"
JPEG_QUALITY="${JPEG_QUALITY:-85}"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Directory not found: $ROOT_DIR" >&2
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick ('magick') is required." >&2
  exit 1
fi

human_bytes() {
  awk '
    function human(x) {
      split("B KB MB GB TB", u, " ")
      for (i = 1; x >= 1024 && i < 5; i++) x /= 1024
      return sprintf("%.2f %s", x, u[i])
    }
    { print human($1) }
  '
}

total_before=0
total_after=0
processed=0

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

while IFS= read -r -d '' file; do
  ext="${file##*.}"
  ext_lc="${ext:l}"
  before_size=$(stat -f '%z' "$file")
  total_before=$((total_before + before_size))
  processed=$((processed + 1))

  tmp_file="$tmp_dir/${processed}.${ext_lc}"
  identify_data=$(magick identify -format '%w|%h|%[opaque]|%k|%r' "$file")
  IFS='|' read -r width height opaque color_count class_desc <<< "$identify_data"
  needs_resize=0
  if (( width > MAX_DIMENSION || height > MAX_DIMENSION )); then
    needs_resize=1
  fi

  common_args=(
    "$file"
    -auto-orient
    -strip
    -filter Lanczos
    -resize "${MAX_DIMENSION}x${MAX_DIMENSION}>"
  )

  case "$ext_lc" in
    jpg|jpeg)
      magick "${common_args[@]}" \
        -sampling-factor 4:2:0 \
        -interlace Plane \
        -quality "$JPEG_QUALITY" \
        "$tmp_file"
      ;;
    png)
      if [[ "$class_desc" == PseudoClass* ]]; then
        magick "${common_args[@]}" \
          -colors 256 \
          PNG8:"$tmp_file"
      elif [[ "$opaque" == "True" ]]; then
        magick "${common_args[@]}" \
          -alpha off \
          -define png:format=png24 \
          -define png:compression-level=9 \
          -define png:compression-filter=5 \
          -define png:compression-strategy=1 \
          "$tmp_file"
      else
        magick "${common_args[@]}" \
          -define png:format=png32 \
          -define png:compression-level=9 \
          -define png:compression-filter=5 \
          -define png:compression-strategy=1 \
          "$tmp_file"
      fi
      ;;
    *)
      echo "Skipping unsupported file: $file"
      continue
      ;;
  esac

  after_size=$(stat -f '%z' "$tmp_file")

  if (( after_size < before_size )); then
    mv "$tmp_file" "$file"
    final_size=$after_size
    result_label="optimized"
  elif (( needs_resize == 1 )); then
    mv "$tmp_file" "$file"
    final_size=$after_size
    result_label="resized"
  else
    rm -f "$tmp_file"
    final_size=$before_size
    result_label="kept"
  fi

  total_after=$((total_after + final_size))

  printf '%s | %sx%s | %s -> %s | %s\n' \
    "$file" \
    "$width" \
    "$height" \
    "$(printf '%s\n' "$before_size" | human_bytes)" \
    "$(printf '%s\n' "$final_size" | human_bytes)" \
    "$result_label"
done < <(find "$ROOT_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | sort -z)

echo
printf 'Processed: %d\n' "$processed"
printf 'Total: %s -> %s\n' \
  "$(printf '%s\n' "$total_before" | human_bytes)" \
  "$(printf '%s\n' "$total_after" | human_bytes)"
