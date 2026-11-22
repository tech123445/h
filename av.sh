#!/usr/bin/env bash
# A.sh - standalone Word Count runner for an already installed Hadoop.
# Start HDFS and YARN first. Compiles against the Hadoop version currently installed.

set -Eeuo pipefail
command -v hadoop >/dev/null 2>&1 || { echo "ERROR: hadoop not found. Run source ~/.bashrc"; exit 1; }
command -v javac >/dev/null 2>&1 || { echo "ERROR: javac not found. A JDK is required."; exit 1; }

WORK="$HOME/hadoop-wordcount-standalone"
SRC="$WORK/src"
BUILD="$WORK/build"
JAR="$WORK/wordcount.jar"
mkdir -p "$SRC" "$BUILD" "$WORK/input"

cat > "$SRC/WordMapper.java" <<'JAVA'
import java.io.IOException;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Mapper;
public class WordMapper extends Mapper<Object, Text, Text, IntWritable> {
    private final IntWritable one = new IntWritable(1);
    private final Text word = new Text();
    public void map(Object key, Text value, Context context) throws IOException, InterruptedException {
        String[] words = value.toString().toLowerCase().split("\\s+");
        for (String w : words) {
            w = w.replaceAll("[^a-z0-9]", "");
            if (!w.isEmpty()) { word.set(w); context.write(word, one); }
        }
    }
}
JAVA
cat > "$SRC/SumReducer.java" <<'JAVA'
import java.io.IOException;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Reducer;
public class SumReducer extends Reducer<Text, IntWritable, Text, IntWritable> {
    private final IntWritable result = new IntWritable();
    public void reduce(Text key, Iterable<IntWritable> values, Context context) throws IOException, InterruptedException {
        int sum = 0;
        for (IntWritable v : values) sum += v.get();
        result.set(sum); context.write(key, result);
    }
}
JAVA
cat > "$SRC/WordCount.java" <<'JAVA'
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;
public class WordCount {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Usage: WordCount <input> <output>"); System.exit(2);
        }
        Job job = Job.getInstance(new Configuration(), "Word Count");
        job.setJarByClass(WordCount.class);
        job.setMapperClass(WordMapper.class);
        job.setCombinerClass(SumReducer.class);
        job.setReducerClass(SumReducer.class);
        job.setOutputKeyClass(Text.class);
        job.setOutputValueClass(IntWritable.class);
        FileInputFormat.addInputPath(job, new Path(args[0]));
        FileOutputFormat.setOutputPath(job, new Path(args[1]));
        System.exit(job.waitForCompletion(true) ? 0 : 1);
    }
}
JAVA

echo "Hadoop version:"
hadoop version | head -n 2
echo "Compiling Word Count against this Hadoop installation..."
rm -rf "$BUILD"; mkdir -p "$BUILD"
javac -classpath "$(hadoop classpath)" -d "$BUILD" "$SRC"/*.java
jar -cf "$JAR" -C "$BUILD" .

cat > "$WORK/input/input.txt" <<'EOF'
hello hadoop
hello world
hadoop world
EOF
IN="/user/$USER/wordcount_input"
OUT="/user/$USER/wordcount_output"
hdfs dfs -mkdir -p "$IN"
hdfs dfs -put -f "$WORK/input/input.txt" "$IN/"
hdfs dfs -rm -r -f "$OUT" >/dev/null 2>&1 || true
hadoop jar "$JAR" WordCount "$IN" "$OUT"
echo
hdfs dfs -cat "$OUT/part-r-00000"
echo "======================================="
