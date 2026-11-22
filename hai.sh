#!/usr/bin/env bash
# ============================================================================
# HADOOP 3.2.3 + JAVA 8 + WORDCOUNT - AUTO SETUP FOR UBUNTU
# Exact Hadoop download source requested:
#   https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz
#
# Usage:
#   bash hadoop_wordcount_huawei_auto.sh
#   bash hadoop_wordcount_huawei_auto.sh /path/to/your.txt
#
# Does not modify an existing Hadoop installation or /etc/profile.
# Runs an actual Java MapReduce job in standalone (local) mode: no SSH/HDFS/YARN.
# Repairs common issues automatically; cannot fix a blocked network, no disk
# space, lack of permissions, or other problems outside the script's control.
# ============================================================================
set -Eeuo pipefail

HADOOP_VERSION='3.2.3'
HADOOP_URL='https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz'
HADOOP_SHA512='46bfbbec3a80dec4d4775e807a981260cac8719964d45663eb8215adcd716b90ef3225d4fe781bcce02ea15e5d2155733bfe0f41f985f2b15297f61abbeb2979'
WORK_DIR="${HADOOP_WORDCOUNT_WORKDIR:-$HOME/hadoop-wordcount-lab}"
TOOLS_DIR="$HOME/.local/opt"
JAVA8_TARGET="$TOOLS_DIR/temurin8-hadoop-lab"
INPUT_FILE="$WORK_DIR/input/input.txt"
OUTPUT_DIR="$WORK_DIR/output"
CLASS_DIR="$WORK_DIR/classes"
CONF_DIR="$WORK_DIR/hadoop-conf"
TEMP_DIR=''
LOG_FILE=''

say()  { printf '\n\033[1;34m[STEP] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[REPAIR] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; [[ -z "$LOG_FILE" ]] || printf 'Log file: %s\n' "$LOG_FILE" >&2; exit 1; }
cleanup() { [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
trap 'printf "\n[FAILED] Command at line %s: %s\nSee log: %s\n" "$LINENO" "$BASH_COMMAND" "$LOG_FILE" >&2' ERR

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  printf 'Usage: bash %s [optional-text-file]\n' "$(basename "$0")"
  printf 'Hadoop URL: %s\n' "$HADOOP_URL"
  printf 'Output: ~/hadoop-wordcount-lab/output/part-r-00000\n'
  exit 0
fi
[[ $# -le 1 ]] || die "Provide at most one input .txt file."
[[ "$(uname -s)" == 'Linux' ]] || die 'Run this script inside your Ubuntu/Linux VM.'
[[ -d "$HOME" && -w "$HOME" ]] || die 'Your home directory is not writable.'
for safe_dir in "$WORK_DIR" "$OUTPUT_DIR" "$CLASS_DIR" "$CONF_DIR"; do
  [[ ! -L "$safe_dir" ]] || die "Refusing to use a symlinked work directory: $safe_dir"
done
mkdir -p "$WORK_DIR" "$TOOLS_DIR"
LOG_FILE="$WORK_DIR/last_run.log"
# Best-effort persistent log, while continuing to display progress in Terminal.
if command -v tee >/dev/null 2>&1; then
  exec > >(tee "$LOG_FILE") 2>&1
fi
say 'Starting automatic Hadoop WordCount setup'
printf 'Requested Hadoop download: %s\n' "$HADOOP_URL"
printf 'Work directory: %s\n' "$WORK_DIR"

# 1) Install tiny system prerequisites only when truly missing.
install_apt() {
  local -a packages=("$@")
  local -a elevate=()
  command -v apt-get >/dev/null 2>&1 || die "Missing ${packages[*]} and apt-get is not available. Install them manually."
  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Missing ${packages[*]}; sudo is unavailable."
    elevate=(sudo)
  fi
  warn "Installing missing Ubuntu dependency/dependencies: ${packages[*]}"
  "${elevate[@]}" apt-get update -o Acquire::Retries=3 || die 'apt-get update failed (check Internet and apt repositories).'
  "${elevate[@]}" apt-get install -y -o DPkg::Lock::Timeout=120 "${packages[@]}" || die "Cannot install: ${packages[*]}."
}
missing=()
command -v tar >/dev/null 2>&1 || missing+=(tar)
command -v gzip >/dev/null 2>&1 || missing+=(gzip)
command -v sha512sum >/dev/null 2>&1 || missing+=(coreutils)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then missing+=(curl ca-certificates); fi
if ((${#missing[@]})); then install_apt "${missing[@]}"; fi

# Download with bounded retries and resume when the server allows it.
fetch() {
  local url="$1" out="$2" attempt
  for attempt in 1 2 3; do
    say "Downloading (attempt $attempt/3): $url"
    if command -v curl >/dev/null 2>&1; then
      if curl -fL --connect-timeout 25 --retry 2 --retry-delay 2 -C - -o "$out" "$url"; then return 0; fi
    else
      if wget -c --tries=3 --timeout=40 -O "$out" "$url"; then return 0; fi
    fi
    warn "Download attempt failed. Retrying from a clean file if necessary."
    rm -f -- "$out"
    sleep 2
  done
  return 1
}

# 2) Discover a Java 8 *JDK*, not merely a JRE; Hadoop 3.2.x requires Java 8.
find_java8() {
  local loc result
  for loc in "${JAVA_HOME:-}" "$JAVA8_TARGET" \
      "$HOME"/.sdkman/candidates/java/current "$HOME"/.sdkman/candidates/java/* \
      /usr/lib/jvm/* /opt/java/* /usr/local/java/*; do
    [[ -n "$loc" && -x "$loc/bin/java" && -x "$loc/bin/javac" && -x "$loc/bin/jar" ]] || continue
    result="$("$loc/bin/javac" -version 2>&1 || true)"
    if [[ "$result" == 'javac 1.8.'* || "$result" == 'javac 8'* ]]; then
      readlink -f "$loc"
      return 0
    fi
  done
  if command -v javac >/dev/null 2>&1; then
    result="$(javac -version 2>&1 || true)"
    if [[ "$result" == 'javac 1.8.'* || "$result" == 'javac 8'* ]]; then
      loc="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
      [[ -x "$loc/bin/java" && -x "$loc/bin/jar" ]] && { printf '%s\n' "$loc"; return 0; }
    fi
  fi
  return 1
}

# Private JDK setup avoids changing system defaults or requiring sudo.
install_java8() {
  local arch archive stage root
  case "$(uname -m)" in
    x86_64|amd64) arch='x64' ;;
    aarch64|arm64) arch='aarch64' ;;
    *) die 'Automatic Java 8 installation supports x86_64 or ARM64 only.' ;;
  esac
  warn 'Java 8 JDK is missing; downloading Eclipse Temurin JDK 8 (user-local, no sudo).'
  archive="$TEMP_DIR/temurin8.tar.gz"
  fetch "https://api.adoptium.net/v3/binary/latest/8/ga/linux/$arch/jdk/hotspot/normal/eclipse" "$archive" \
    || die 'Could not download Java 8. Check Internet and api.adoptium.net access.'
  tar -tzf "$archive" >/dev/null 2>&1 || die 'Downloaded Java 8 archive is corrupt; retry the script.'
  stage="$(mktemp -d "$TOOLS_DIR/.java8-stage.XXXXXXXX")"
  tar -xzf "$archive" -C "$stage" || die 'Could not extract Java 8 (disk full or corrupt download).'
  root="$(find "$stage" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$root" && -x "$root/bin/javac" && -x "$root/bin/java" ]] || die 'Java 8 archive did not contain a complete JDK.'
  if [[ -e "$JAVA8_TARGET" ]]; then
    JAVA8_TARGET="$TOOLS_DIR/temurin8-hadoop-lab-repaired"
    [[ ! -e "$JAVA8_TARGET" ]] || die 'Both Java 8 installation directories are unusable; inspect ~/.local/opt manually.'
  fi
  mv -- "$root" "$JAVA8_TARGET"
  rmdir "$stage" || true
  [[ "$("$JAVA8_TARGET/bin/javac" -version 2>&1)" == 'javac 1.8.'* ]] || die 'Installed JDK is not Java 8.'
  JAVA_HOME="$JAVA8_TARGET"
}

TEMP_DIR="$(mktemp -d "$WORK_DIR/.downloads.XXXXXXXX")"
if JAVA_FOUND="$(find_java8)"; then
  JAVA_HOME="$JAVA_FOUND"
  say "Reusing installed Java 8 JDK: $JAVA_HOME"
else
  install_java8
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
say "Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1)"

# 3) Reuse Hadoop from the VM when present. Never overwrite existing Hadoop.
find_hadoop() {
  local candidate binary
  for candidate in "${HADOOP_HOME:-}" \
      "$HOME/hadoop-3.2.3" "$HOME/.local/opt/hadoop-3.2.3" \
      "$HOME"/hadoop "$HOME"/hadoop-* /usr/local/hadoop /usr/local/hadoop-* /opt/hadoop /opt/hadoop-*; do
    [[ -n "$candidate" && -x "$candidate/bin/hadoop" && -d "$candidate/share/hadoop/mapreduce" ]] || continue
    (cd "$candidate" && pwd -P)
    return 0
  done
  if command -v hadoop >/dev/null 2>&1; then
    binary="$(readlink -f "$(command -v hadoop)")"
    candidate="$(dirname "$(dirname "$binary")")"
    if [[ -x "$candidate/bin/hadoop" && -d "$candidate/share/hadoop/mapreduce" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

install_hadoop() {
  local target archive stage
  target="$HOME/hadoop-$HADOOP_VERSION"
  if [[ -e "$target" ]]; then
    warn "Existing $target is incomplete or unusable; preserving it."
    target="$TOOLS_DIR/hadoop-$HADOOP_VERSION"
  fi
  if [[ -e "$target" ]]; then
    warn "$target also exists; preserving it and using a separate repaired installation."
    target="$TOOLS_DIR/hadoop-$HADOOP_VERSION-repaired"
  fi
  [[ ! -e "$target" ]] || die "Unable to safely install; the repaired directory also exists: $target"
  say "Installing Hadoop $HADOOP_VERSION from Huawei Cloud ONLY"
  archive="$TEMP_DIR/hadoop-$HADOOP_VERSION.tar.gz"
  local attempt ok=0
  for attempt in 1 2 3; do
    if ! fetch "$HADOOP_URL" "$archive"; then
      warn 'Hadoop mirror download failed; attempting recovery.'
      continue
    fi
    if printf '%s  %s\n' "$HADOOP_SHA512" "$archive" | sha512sum --check --status; then
      ok=1
      break
    fi
    warn 'Downloaded Hadoop archive failed SHA-512 integrity check; deleting it and retrying.'
    rm -f -- "$archive"
  done
  (( ok == 1 )) || die "Unable to fetch a verified Hadoop archive from $HADOOP_URL. Check network, free disk space, and the mirror."
  say 'Hadoop SHA-512 checksum verified.'
  stage="$(mktemp -d "$TOOLS_DIR/.hadoop-stage.XXXXXXXX")"
  if ! tar -xzf "$archive" -C "$stage"; then
    rm -rf -- "$stage"
    die 'Hadoop extraction failed (check free disk space and file permissions).'
  fi
  [[ -x "$stage/hadoop-$HADOOP_VERSION/bin/hadoop" ]] || die 'Hadoop extraction is incomplete.'
  mv -- "$stage/hadoop-$HADOOP_VERSION" "$target"
  rmdir "$stage"
  HADOOP_HOME="$target"
}

HADOOP_JUST_INSTALLED=0
if HADOOP_FOUND="$(find_hadoop)"; then
  HADOOP_HOME="$HADOOP_FOUND"
  say "Existing Hadoop found: $HADOOP_HOME (download and installation skipped)"
else
  warn 'Hadoop not found. Checking available disk space before installation.'
  free_kb="$(df -Pk "$HOME" | awk 'END {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 1600000 )); then
    die 'Less than ~1.6 GB is free. Free some disk space and run the script again.'
  fi
  install_hadoop
  HADOOP_JUST_INSTALLED=1
fi
export HADOOP_HOME
export PATH="$HADOOP_HOME/bin:$PATH"
HADOOP_BIN="$HADOOP_HOME/bin/hadoop"

# Make an isolated configuration copy. Fixes incorrect JAVA_HOME and accidentally
# inherited HDFS/YARN settings without modifying the user's original installation.
configure_hadoop() {
  mkdir -p "$CONF_DIR"
  [[ -d "$HADOOP_HOME/etc/hadoop" ]] || die "Missing Hadoop configuration: $HADOOP_HOME/etc/hadoop"
  cp -a "$HADOOP_HOME/etc/hadoop/." "$CONF_DIR/" || die 'Failed to create isolated Hadoop configuration.'
  chmod u+w "$CONF_DIR/hadoop-env.sh" || die 'Cannot update the isolated Hadoop environment file.'
  printf '\n# Added automatically for this WordCount script\nexport JAVA_HOME=%q\n' "$JAVA_HOME" >> "$CONF_DIR/hadoop-env.sh"
  export HADOOP_CONF_DIR="$CONF_DIR"
}
configure_hadoop
if ! "$HADOOP_BIN" version; then
  if (( HADOOP_JUST_INSTALLED == 1 )); then
    die 'New Hadoop installation cannot start; check the log and disk space.'
  fi
  warn 'The existing Hadoop does not start. Installing a separate verified Hadoop 3.2.3 copy.'
  install_hadoop
  export HADOOP_HOME
  export PATH="$HADOOP_HOME/bin:$PATH"
  HADOOP_BIN="$HADOOP_HOME/bin/hadoop"
  configure_hadoop
  "$HADOOP_BIN" version || die 'Hadoop still cannot start after clean installation.'
fi

# 4) Create the input and actual Java MapReduce application.
mkdir -p "$WORK_DIR/input"
if [[ $# -eq 1 ]]; then
  [[ -f "$1" && -r "$1" ]] || die "Input file does not exist or is unreadable: $1"
  if [[ "$(readlink -f -- "$1")" != "$(readlink -m -- "$INPUT_FILE")" ]]; then
    cp -- "$1" "$INPUT_FILE" || die "Could not copy input text file: $1"
  fi
  say "Using custom WordCount input file: $1"
elif [[ ! -f "$INPUT_FILE" ]]; then
  cat > "$INPUT_FILE" <<'TEXT'
hadoop is powerful
hadoop counts words
word count with hadoop
TEXT
  say "Sample input created: $INPUT_FILE"
else
  say "Using saved input file: $INPUT_FILE"
fi

cat > "$WORK_DIR/WordCount.java" <<'JAVA'
import java.io.IOException;
import java.util.StringTokenizer;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;

public class WordCount {
    public static class WordMapper extends Mapper<Object, Text, Text, IntWritable> {
        private final IntWritable one = new IntWritable(1);
        private final Text word = new Text();

        public void map(Object key, Text value, Context context)
                throws IOException, InterruptedException {
            StringTokenizer tokenizer = new StringTokenizer(value.toString());
            while (tokenizer.hasMoreTokens()) {
                word.set(tokenizer.nextToken());
                context.write(word, one);
            }
        }
    }

    public static class WordReducer extends Reducer<Text, IntWritable, Text, IntWritable> {
        public void reduce(Text key, Iterable<IntWritable> values, Context context)
                throws IOException, InterruptedException {
            int total = 0;
            for (IntWritable count : values) total += count.get();
            context.write(key, new IntWritable(total));
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Usage: WordCount <input-file> <output-directory>");
            System.exit(2);
        }
        Configuration conf = new Configuration();
        // Force standalone local mode even if this VM is set up for HDFS/YARN.
        conf.set("fs.defaultFS", "file:///");
        conf.set("mapreduce.framework.name", "local");
        Job job = Job.getInstance(conf, "WordCount Lab");
        job.setJarByClass(WordCount.class);
        job.setMapperClass(WordMapper.class);
        job.setCombinerClass(WordReducer.class);
        job.setReducerClass(WordReducer.class);
        job.setOutputKeyClass(Text.class);
        job.setOutputValueClass(IntWritable.class);
        FileInputFormat.addInputPath(job, new Path(args[0]));
        FileOutputFormat.setOutputPath(job, new Path(args[1]));
        System.exit(job.waitForCompletion(true) ? 0 : 1);
    }
}
JAVA

# 5) Resolve dependencies and compile. Retry with an explicit JAR classpath.
say 'Resolving Hadoop Java dependencies and compiling WordCount.java'
mkdir -p "$CLASS_DIR"
find "$CLASS_DIR" -type f -name '*.class' -delete
HADOOP_CP="$("$HADOOP_BIN" classpath --glob 2>/dev/null || true)"
if [[ -z "$HADOOP_CP" ]] || ! "$JAVA_HOME/bin/javac" -cp "$HADOOP_CP" -d "$CLASS_DIR" "$WORK_DIR/WordCount.java"; then
  warn 'Automatic classpath/compilation failed. Retrying using Hadoop library JAR files.'
  HADOOP_CP="$(find "$HADOOP_HOME/share/hadoop" -type f -name '*.jar' -printf '%p:' | sed 's/:$//')"
  [[ -n "$HADOOP_CP" ]] || die 'No Hadoop JAR dependencies found; installation may be incomplete.'
  "$JAVA_HOME/bin/javac" -cp "$HADOOP_CP" -d "$CLASS_DIR" "$WORK_DIR/WordCount.java" \
    || die 'Java compilation failed even after dependency recovery. Check the errors above.'
fi
"$JAVA_HOME/bin/jar" cf "$WORK_DIR/wordcount.jar" -C "$CLASS_DIR" . \
  || die 'Could not build wordcount.jar.'

# 6) MapReduce refuses to write into an existing output directory.
# This output folder is created solely for this lab. Do not touch HDFS or
# any directory outside ~/hadoop-wordcount-lab.
if [[ -e "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die "Unsafe existing output path: $OUTPUT_DIR"
  warn 'Removing previous *lab-only* output to prevent FileAlreadyExistsException.'
  rm -rf -- "$OUTPUT_DIR"
fi
say 'Running WordCount using Hadoop MapReduce (standalone / local mode)'
if ! "$HADOOP_BIN" jar "$WORK_DIR/wordcount.jar" WordCount "$INPUT_FILE" "$OUTPUT_DIR"; then
  warn 'MapReduce failed once. Cleaning partial lab output and retrying one time.'
  [[ ! -e "$OUTPUT_DIR" || ( -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ) ]] \
    || die 'Partial output is not a safe directory for cleanup.'
  [[ ! -d "$OUTPUT_DIR" ]] || rm -rf -- "$OUTPUT_DIR"
  "$HADOOP_BIN" jar "$WORK_DIR/wordcount.jar" WordCount "$INPUT_FILE" "$OUTPUT_DIR" \
    || die "MapReduce failed again. Check $LOG_FILE for the actual error."
fi

[[ -f "$OUTPUT_DIR/part-r-00000" ]] || die 'MapReduce finished but the expected output file is missing.'
printf '\n==================================================\n'
printf '             WORD COUNT RESULT\n'
printf '==================================================\n'
cat "$OUTPUT_DIR/part-r-00000"
printf '==================================================\n'
printf 'Hadoop:    %s\n' "$HADOOP_HOME"
printf 'Java 8:   %s\n' "$JAVA_HOME"
printf 'Java file: %s\n' "$WORK_DIR/WordCount.java"
printf 'JAR file:  %s\n' "$WORK_DIR/wordcount.jar"
printf 'Input:     %s\n' "$INPUT_FILE"
printf 'Output:    %s\n' "$OUTPUT_DIR/part-r-00000"
printf 'Log:       %s\n' "$LOG_FILE"
printf '\nSUCCESS! Hadoop WordCount executed.\n'
