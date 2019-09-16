#!/bin/bash
# Before running this script, log in with the "oc" command,
# create a project with one of the JBoss Web Server Apache Tomcat images
# wait for a pod with Tomcat to run and run this script passing the running pod name
#
# Author - Michael Greenberg mgreenbe@redhat.com
PROGNAME=$(basename $0)
USAGE="Usage: ${PROGNAME} pod-name"
if [ $# -eq 0 ];then
	echo ${USAGE}
	exit 2
fi

ORIGDIR=${PWD}
TMPDIR=$(mktemp --suffix=.tomcat -d)
trap "exit 1" TERM
export TOP_PID=$$
PODNAME=$1

clean_exit() {
	if [ -n "${TMPDIR}" -a -d "${TMPDIR}" ];then
		cd ${ORIGDIR}
		rm -rf ${TMPDIR}
	fi
	if [ $1 -ne 0 ];then
		kill -s TERM ${TOP_PID}
	fi
}

check_for_text() {
	grep -q "$1" "$2"
	ret=$?
	if [ ${ret} -ne 0 ];then
		echo "Unable to find \"$1\" in $2"
		clean_exit 1
	fi
}

create_configmap() {
	oc create configmap $1 --from-file=$2
	if [ $? -ne 0 ];then
		echo "${PROGNAME}: Unable to create configmap \"$1\" from \"$2\""
		clean_exit 1
	fi
}

oc rsync ${PODNAME}:/opt/webserver/conf ${TMPDIR} --no-perms
if [ $? -ne 0 ];then
	echo "${PROGNAME}: unable to copy /opt/webserver/conf files from pod ${PODNAME}"
	clean_exit 1
fi

cd ${TMPDIR}/conf
# update Tomcat server settings to reload newly installed applications
sed -i.bak -e 's/autoDeploy="false"/autoDeploy="true"/' \
	-e 's/deployOnStartup="false"/deployOnStartup="true"/' server.xml
check_for_text 'deployOnStartup="true"' server.xml
check_for_text 'autoDeploy="true"' server.xml
sed -i.bak -e '/<Context/s/>/ reloadable="true">/' \
	-e '/WatchedResource.*WEB-INF\/web.xml/a <WatchedResource>WEB-INF\/classes<\/WatchedResource>' context.xml
check_for_text 'reloadable="true"' context.xml
check_for_text 'WEB-INF/classes' context.xml

# create configmaps from the updated Tomcat configuration files
create_configmap cm-server-xml server.xml
create_configmap cm-context-xml context.xml


# add the new configmaps to the deployment config
DEPLOYMENT_CONFIG=$(oc describe pod ${PODNAME} | grep deploymentConfig | sed "s/.*=//")
if [ -z "${DEPLOYMENT_CONFIG}" ];then
	echo "${PROGNAME}: Unable to determine deployment config"
	clean_exit 1
fi
oc set volume dc/${DEPLOYMENT_CONFIG} --add --name=vol-server-xml --mount-path /opt/webserver/conf/server.xml --sub-path server.xml --source='{"configMap":{"name":"cm-server-xml","defaultMode":420,"items":[{"key":"server.xml","path":"server.xml"}]}}'
oc set volume dc/${DEPLOYMENT_CONFIG} --add --name=vol-context-xml --mount-path /opt/webserver/conf/context.xml --sub-path context.xml --source='{"configMap":{"name":"cm-context-xml","defaultMode":420,"items":[{"key":"context.xml","path":"context.xml"}]}}'

clean_exit 0
