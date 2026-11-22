#!/bin/bash

java -version

cd ~

wget https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz

tar -xvzf hadoop-3.2.3.tar.gz

mv hadoop-3.2.3 hadoop

cat >> ~/.bashrc <<'EOF'
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export HADOOP_HOME=$HOME/hadoop
export HADOOP_INSTALL=$HADOOP_HOME
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
export HADOOP_MAPRED_HOME=$HADOOP_HOME
export HADOOP_COMMON_HOME=$HADOOP_HOME
export HADOOP_HDFS_HOME=$HADOOP_HOME
export YARN_HOME=$HADOOP_HOME
EOF

source ~/.bashrc

hadoop version

echo 'export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64' >> $HADOOP_HOME/etc/hadoop/hadoop-env.sh

cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<'EOF'
<configuration>
<property>
<name>fs.defaultFS</name>
<value>hdfs://localhost:9000</value>
</property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<EOF
<configuration>
<property>
<name>dfs.replication</name>
<value>1</value>
</property>
<property>
<name>dfs.namenode.name.dir</name>
<value>file://$HOME/hadoopdata/namenode</value>
</property>
<property>
<name>dfs.datanode.data.dir</name>
<value>file://$HOME/hadoopdata/datanode</value>
</property>
</configuration>
EOF

cp $HADOOP_HOME/etc/hadoop/mapred-site.xml.template $HADOOP_HOME/etc/hadoop/mapred-site.xml

cat > $HADOOP_HOME/etc/hadoop/mapred-site.xml <<'EOF'
<configuration>
<property>
<name>mapreduce.framework.name</name>
<value>yarn</value>
</property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/yarn-site.xml <<'EOF'
<configuration>
<property>
<name>yarn.nodemanager.aux-services</name>
<value>mapreduce_shuffle</value>
</property>
</configuration>
EOF

echo localhost > $HADOOP_HOME/etc/hadoop/workers

sudo apt update
sudo apt install openssh-server openssh-client -y

sudo service ssh start

ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa

cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

chmod 600 ~/.ssh/authorized_keys

ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null

hdfs namenode -format

start-dfs.sh

start-yarn.sh

jps
