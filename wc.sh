#!/bin/bash

mkdir -p ~/wordcount

cd ~/wordcount

cat > input.txt <<'EOF'
hello world
hello hadoop
hadoop mapreduce
hello world
EOF

cat > mapper.py <<'EOF'
#!/usr/bin/env python3
import sys

for line in sys.stdin:
    words = line.strip().split()
    for word in words:
        print(word + "\t1")
EOF

cat > reducer.py <<'EOF'
#!/usr/bin/env python3
import sys

current_word = None
count = 0

for line in sys.stdin:
    word, value = line.strip().split("\t")
    value = int(value)

    if current_word == word:
        count += value
    else:
        if current_word is not None:
            print(current_word, count)

        current_word = word
        count = value

if current_word is not None:
    print(current_word, count)
EOF

chmod +x mapper.py reducer.py

hdfs dfs -mkdir -p /input

hdfs dfs -put -f input.txt /input/

hdfs dfs -cat /input/input.txt

hdfs dfs -rm -r -f /output

hadoop jar $HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.2.3.jar \
-input /input/input.txt \
-output /output \
-mapper "python3 mapper.py" \
-reducer "python3 reducer.py" \
-files mapper.py,reducer.py

hdfs dfs -cat /output/part-00000
