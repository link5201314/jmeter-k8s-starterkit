slave_array=(10.42.0.21 10.42.1.172 10.42.2.135); index=3 && while [ ${index} -gt 0 ]; do for slave in ${slave_array[@]}; do if echo 'test open port' 2>/dev/null > /dev/tcp/${slave}/1099; then echo ${slave}' ready' && slave_array=(${slave_array[@]/${slave}/}); index=$((index-1)); else echo ${slave}' not ready'; fi; done; echo 'Waiting for slave readiness'; sleep 2; done
echo "Installing needed plugins for master"
cd /opt/jmeter/apache-jmeter/bin
sh PluginsManagerCMD.sh install-for-jmx demoweb.jmx
echo "Done installing plugins, launching test"
mkdir -p /report/demoweb
JVM_ARGS=""
export JVM_ARGS
jmeter -Ghost=sbdemo.example.com -Gport=443 -Gprotocol=https -Gthreads=5 -Gduration=60 -Grampup=6 --reportatendofloadtests --reportoutputfolder /report/demoweb/report-demoweb.jmx-2026-03-01_123644  -Jjmeter.reportgenerator.overall_granularity=10000 -Jjmeter.reportgenerator.apdex_satisfied_threshold=1000 -Jjmeter.reportgenerator.apdex_tolerated_threshold=2000 -S /opt/jmeter/apache-jmeter/bin/jmeter-system.properties --logfile /report/demoweb/demoweb.jmx_2026-03-01_123644.jtl --nongui --testfile demoweb.jmx -Dserver.rmi.ssl.disable=true --remoteexit --remotestart 10.42.0.21,10.42.1.172,10.42.2.135 >> jmeter-master.out 2>> jmeter-master.err &
trap 'kill -10 1' EXIT INT TERM
java -jar /opt/jmeter/apache-jmeter/lib/jolokia-java-agent.jar start JMeter >> jmeter-master.out 2>> jmeter-master.err
echo "Starting load test at : Sun Mar  1 12:36:44 CST 2026" && wait
