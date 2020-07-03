#!/bin/bash -x
sed -i '1i $localHostName ${app_env}_${service_name}_INSTANCEHOSTNAME' /etc/rsyslog.conf
sed -i "s/INSTANCEHOSTNAME/$${HOSTNAME}/g" /etc/rsyslog.conf

##################################
#### Troubleshooting packages ####
##################################
apt-get -y update && apt-get -y upgrade
apt-get -y install python3 python3-pip awscli apt-transport-https openjdk-8-jre-headless uuid-runtime pwgen unzip

#####################
#### Graylog EBS ####
#####################
sleep 30
mkdir -p /var/lib/graylog
cat << EOF >> /etc/fstab
/dev/nvme1n1 /var/lib/graylog ext4 defaults 0 0
EOF
mount /dev/nvme1n1 /var/lib/graylog
mount -a

############################
#### Installing MongoDB ####
############################
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 9DA31620334BD75D9DCB49F368818C72E52529D4
echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.0.list
sudo apt-get -y update && sudo apt-get -y install mongodb-org

#####################################
####  Move Mongodb Config to EBS ####
#####################################
mkdir -p /var/lib/graylog/mongodb
chown -R mongodb:mongodb /var/lib/graylog/mongodb
sed -i 's|/var/lib/mongodb|/var/lib/graylog/mongodb|g' /etc/mongod.conf

##################################
#### Installing Elasticsearch ####
##################################
wget -q https://artifacts.elastic.co/GPG-KEY-elasticsearch -O myKey
sudo apt-key add myKey
echo "deb https://artifacts.elastic.co/packages/oss-6.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-6.x.list
sudo apt-get -y update && sudo apt-get -y install elasticsearch-oss

###########################################
####  Move Elasticsearch Config to EBS ####
###########################################
mkdir -p /var/lib/graylog/elasticsearch
chown -R elasticsearch:elasticsearch /var/lib/graylog/elasticsearch
sed -i 's|#cluster.name: my-application|cluster.name: graylog|g' /etc/elasticsearch/elasticsearch.yml
sed -i 's|/var/lib/elasticsearch|/var/lib/graylog/elasticsearch|g' /etc/elasticsearch/elasticsearch.yml
echo "action.auto_create_index: false" >> /etc/elasticsearch/elasticsearch.yml

############################
#### Installing Graylog ####
############################
wget https://packages.graylog2.org/repo/packages/graylog-3.2-repository_latest.deb
sudo dpkg -i graylog-3.2-repository_latest.deb
sudo apt-get -y update && sudo apt-get -y install graylog-server graylog-enterprise-plugins graylog-integrations-plugins graylog-enterprise-integrations-plugins

#############################
#### Configuring Graylog ####
#############################
GRAYLOG_PASSWORD=$(aws ssm get-parameter --name /${resource_pattern_ssm_name}/admin/password --with-decryption --region ${aws_region} | grep Value | cut -d '"' -f4)
GRAYLOG_PASSWORD_HASH=$(echo -n $GRAYLOG_PASSWORD | sha256sum | cut -d " " -f1)
sed -i "s/^root_password_sha2 .*$/root_password_sha2 = $GRAYLOG_PASSWORD_HASH/" /etc/graylog/server/server.conf
PASSWORD_SECRET=$(pwgen -N 1 -s 96)
sed -i "s/^password_secret .*$/password_secret = $PASSWORD_SECRET/" /etc/graylog/server/server.conf
echo "http_publish_uri = https://${my_graylog_server}" >> /etc/graylog/server/server.conf
echo "http_bind_address = 0.0.0.0:9000" >> /etc/graylog/server/server.conf

if [ "${app_env}" == "prod" ];then
  sed -i 's/size="50MB"/size="1500MB"/g' /etc/graylog/server/log4j2.xml
  sed -i 's/max="10"/max="60"/g' /etc/graylog/server/log4j2.xml
fi

sudo systemctl daemon-reload
sudo systemctl enable mongod.service && sudo systemctl restart mongod.service
sudo systemctl enable elasticsearch.service && sudo systemctl restart elasticsearch.service
sudo systemctl enable graylog-server.service && sudo systemctl restart graylog-server.service

################################
#### Configuring Log Rotate ####
################################
if [ "${app_env}" == "prod" ];then
cat > /etc/graylog/server/log_rotate.sh << "EOF"
#!/bin/bash -x
date=`date +"%d-%m-%y"`
for log_file in $(find /var/log/graylog-server/ -name 'server.log.*.gz');
do
aws s3 cp $${log_file} s3://${bucket}/logs/$${date}/;
done
EOF
  chmod +x /etc/graylog/server/log_rotate.sh
  echo "0 23 * * * /etc/graylog/server/log_rotate.sh" | tee -a /var/spool/cron/crontabs/root
  /usr/bin/crontab /var/spool/cron/crontabs/root
fi

