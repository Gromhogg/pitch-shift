#!/bin/bash
# Pitch Shift Pro keys, for the owner. People email for a key; this makes one, and you email it back.
#
#   tools/pro-keys.sh new "their name or email"   makes a key, prints it, and adds it to the list
#   tools/pro-keys.sh list                         every key made so far (date, name, key)
#   tools/pro-keys.sh check KEY                    says whether a key works, and who it was made for
#
# The keys are checked by the app on its own (no internet). They come from a secret kept in
# ~/Library/Application Support/Pitch Shift Keys/secret.txt, made here the first time (only you can read it). Never put
# it in git or send it to anyone: anyone with it can make keys. build.sh puts it into the app when it builds, so a build
# on this Mac locks the paid parts. Keep a copy of that folder somewhere safe (a USB stick): without the secret, new
# builds can't check the keys already sent out. The list of keys made is issued.txt in the same folder.
#
# Checks only: "key SERIAL" prints the key for a serial number (5 characters) without listing it, and
# "test [FILE]" checks the fixed examples in tools/pro-keys-test.txt (the app checks the same file with --pro-test).
# PITCH_SHIFT_KEYS_DIR=/some/folder uses another folder instead of the real one.
#
# A key: 25 characters in 5 groups, from 23456789ABCDEFGHJKMNPQRSTUVWXYZ (no 0, 1, I, L or O). The first 5 are a serial
# number; the next 16 come from HMAC-SHA-256 of "PSPRO2:" + serial with the secret (each from two bytes, modulo 31);
# the last 4 are a typo check from SHA-256 of "PSPRO1:" + the first 21. Must match Sources/Pro.swift (ProKey).
# Needs only what every Mac has (bash, openssl, shasum).
set -euo pipefail

ALPHABET=23456789ABCDEFGHJKMNPQRSTUVWXYZ
DIR="${PITCH_SHIFT_KEYS_DIR:-$HOME/Library/Application Support/Pitch Shift Keys}"
SECRET_FILE="$DIR/secret.txt"
ISSUED="$DIR/issued.txt"
OPENSSL=/usr/bin/openssl
[[ -x $OPENSSL ]] || OPENSSL=openssl

# The character at a place in the alphabet (0 ... 30).
char() { printf '%s' "${ALPHABET:$1:1}"; }

# The 4-character typo check for the first 21 characters.
check_part() {
  local hex n out="" i
  hex=$(printf '%s' "PSPRO1:$1" | shasum -a 256 | cut -c1-8)
  n=$(( 16#$hex % 923521 ))
  for i in 1 2 3 4; do
    out="$(char $(( n % 31 )))$out"
    n=$(( n / 31 ))
  done
  printf '%s' "$out"
}

# The 16-character secret part for a serial, from the secret.
secret_part() {
  local serial=$1 secret=$2 hex out="" i
  hex=$(printf '%s' "PSPRO2:$serial" | "$OPENSSL" dgst -sha256 -hmac "$secret" | awk '{print $NF}')
  [[ ${#hex} == 64 ]] || { echo "openssl didn't work" >&2; exit 1; }
  for ((i = 0; i < 16; i++)); do
    out="$out$(char $(( 16#${hex:$(( i * 4 )):4} % 31 )))"
  done
  printf '%s' "$out"
}

# "ABCDEFGHJK..." -> "ABCDE-FGHJK-..."
grouped() { printf '%s' "$1" | sed -E 's/(.{5})/\1-/g; s/-$//'; }

# What was typed, in capitals, with dashes, spaces and anything else that isn't a letter or digit gone.
raw() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9'; }

make_key() {
  local serial=$1 secret=$2 body
  body="$serial$(secret_part "$serial" "$secret")"
  grouped "$body$(check_part "$body")"
}

# A random serial number: 5 characters from the alphabet (bytes 248 and up are skipped, so each is equally likely).
random_serial() {
  local serial="" byte
  for byte in $(head -c 64 /dev/urandom | od -An -tu1); do
    (( byte < 248 )) || continue
    serial="$serial$(char $(( byte % 31 )))"
    [[ ${#serial} == 5 ]] && break
  done
  [[ ${#serial} == 5 ]] || { random_serial; return; }
  printf '%s' "$serial"
}

# The secret's text (spaces and line ends taken out).
read_secret() { tr -d ' \t\r\n' < "$SECRET_FILE"; }

# Makes the folder and the secret the first time (32 random bytes as 64 hex characters, only you can read them).
ensure_secret() {
  if [[ ! -s $SECRET_FILE ]]; then
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    (umask 077; "$OPENSSL" rand -hex 32 > "$SECRET_FILE")
    chmod 600 "$SECRET_FILE"
    echo "Made a new secret in $SECRET_FILE (keep a copy somewhere safe; never share it)." >&2
  fi
}

# typo / wrong / good, for a key as typed.
verdict() {
  local key body secret
  key=$(raw "$1")
  if [[ ${#key} != 25 || -n $(printf '%s' "$key" | tr -d "$ALPHABET") ]]; then echo typo; return; fi
  body=${key:0:21}
  [[ $(check_part "$body") == "${key:21:4}" ]] || { echo typo; return; }
  secret=$2
  [[ $(secret_part "${key:0:5}" "$secret") == "${key:5:16}" ]] && echo good || echo wrong
}

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

command=${1:-}
case $command in
  new)
    name=${2:-}
    [[ -n $name ]] || { echo 'Use: tools/pro-keys.sh new "their name or email"' >&2; exit 1; }
    ensure_secret
    secret=$(read_secret)
    serial=$(random_serial)
    while [[ -f $ISSUED ]] && grep -q -- "  $serial-" "$ISSUED"; do serial=$(random_serial); done  # never the same twice
    key=$(make_key "$serial" "$secret")
    (umask 077; printf '%s  %s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$name" "$key" >> "$ISSUED")
    chmod 600 "$ISSUED"
    echo "$key"
    echo "Added to $ISSUED" >&2
    ;;
  list)
    if [[ -s $ISSUED ]]; then cat "$ISSUED"; else echo "No keys made yet."; fi
    ;;
  check)
    [[ -n ${2:-} ]] || { echo "Use: tools/pro-keys.sh check KEY" >&2; exit 1; }
    [[ -s $SECRET_FILE ]] || { echo "No secret yet in $SECRET_FILE, so no key can work." >&2; exit 1; }
    case $(verdict "$2" "$(read_secret)") in
      typo) echo "That key has a typo (or isn't 25 characters)."; exit 1 ;;
      wrong) echo "That key doesn't work: it wasn't made with this Mac's secret."; exit 1 ;;
      good)
        key=$(grouped "$(raw "$2")")
        found=$( { [[ -f $ISSUED ]] && grep -F -- "$key" "$ISSUED"; } || true)
        echo "That key works.${found:+ Made: $found}"
        ;;
    esac
    ;;
  key)
    serial=$(raw "${2:-}")
    [[ ${#serial} == 5 && -z $(printf '%s' "$serial" | tr -d "$ALPHABET") ]] || { echo "Use: tools/pro-keys.sh key SERIAL (5 characters from $ALPHABET)" >&2; exit 1; }
    [[ -s $SECRET_FILE ]] || { echo "No secret yet in $SECRET_FILE" >&2; exit 1; }
    make_key "$serial" "$(read_secret)"
    echo
    ;;
  test)
    file=${2:-$(dirname "$0")/pro-keys-test.txt}
    secret=$(awk '$1 == "secret" { print $2 }' "$file")
    [[ -n $secret ]] || { echo "No secret line in $file" >&2; exit 1; }
    good=0 bad=0
    while read -r serial expected; do
      [[ -z $serial || $serial == \#* || $serial == secret ]] && continue
      made=$(make_key "$serial" "$secret")
      if [[ $made == "$expected" && $(verdict "$made" "$secret") == good && $(verdict "$made" "${secret}x") == wrong ]]; then
        good=$(( good + 1 ))
      else
        bad=$(( bad + 1 ))
        echo "different: $serial made $made, the file says $expected"
      fi
    done < "$file"
    echo "pro-keys test: $good of $(( good + bad )) keys match"
    [[ $bad == 0 && $good -gt 0 ]]
    ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown: $command" >&2; usage 1 ;;
esac
