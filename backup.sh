#!/usr/bin/env bash

#### DEBUG ####
# set -x
#### DEBUG ####

####### CONFIG START #######
CONFIG_FILE=~/.ftp_backup

TAR_DIRS="/"
TAR_EXCLUDE_DIRS="/dev /lost+found /media /mnt /proc /run /sys /tmp /var/lock /var/run /var/tmp"

# where to create temp directory and files
TMP_DIR="/tmp"

# how many files to keep
FTP_FILE_COUNT=5

# optional tar options
TAR_OPT=""

# load sensitive data
if [ ! -f $CONFIG_FILE ]; then
	echo "No config file ($CONFIG_FILE) given - quit!"
	exit 1
fi
. $CONFIG_FILE

# config file may contains
#FTP_HOST="ftp.example.com"
#FTP_USER="ftp_user"
#FTP_PASS="ftp_pass"
#FTP_DIR="/base"
#MYSQL_USER="mysqlUser"
#MYSQL_PASS="mysqlPass"
#ENC_PASS_FILE="/root/.ftp_backup_pass"

####### CONFIG   END #######

TS_START=$(date +'%s')
CURR_DIR=$PWD
DATE_STRING=$(date +'%F')
BACKUP_DIR="${TMP_DIR}/ftp_backup-${DATE_STRING}"
PREFIX=${BACKUP_PREFIX:-$(hostname1 2>/dev/null || echo "backup")}
FILE_NAME="${PREFIX}-${DATE_STRING}"
UPLOAD_FILENAME=""

# add backup dir to exclude dirs - to be safe
TAR_EXCLUDE_DIRS="$BACKUP_DIR $TAR_EXCLUDE_DIRS"

TMP_TAR_OPT="${TAR_OPT}"
OPENSSL_OPT="aes-256-cbc -e -salt -pass file:${ENC_PASS_FILE}"
TMP_BACKUP_FILE=""

function check_commands() {

	# list of mandatory binaries
	needed_binaries="tar ftp"
	
	# check for list of mandatory binaries
	for binary in $needed_binaries; do
		binary_check=$(which $binary 2>/dev/null)
		if [ "x${binary_check}" = "x" ]; then
			echo "No '${binary}' binary found which is mandatory - quit!"
			exit 1
		fi
	done
}

function calculate_size() {
	file_name=$1
	file_size=$(du -h $file_name 2>/dev/null | awk '{print $1}')
	if [ "x${file_size}" = "x" ]; then
		echo "unknown"
	else
		echo "$file_size"
	fi
}

function calculate_pretty_duration() {
	duration=$1

	if [ "$duration" -lt 60 ]; then
		echo "${duration} second(s)"
	elif [ "$duration" -lt 3600 ]; then
		((minutes=duration/60))
		((seconds=duration%60))
		echo "${minutes} minute(s) ${seconds} second(s)"
	else
		((hours=duration/3600))
		((minutes=(duration-(hours*3600))/60))
		((seconds=(duration-(hours*3600))%60))
		echo "${hours} hour(s) ${minutes} minute(s) ${seconds} second(s)"
	fi
}

function clean_up_temp_dir() {
	if [ -d $BACKUP_DIR ]; then
		echo -n "Cleaning temp-dir '${BACKUP_DIR}': "
		rm -rf ${BACKUP_DIR}
		if [ -d $BACKUP_DIR ]; then
			echo "unable to delete temp dir - exit!"
			exit 1
		fi
		echo "done."
	fi
}

function flush_mysql() {

	# check if mysql command is available
	mysql_binary=`which mysql 2>/dev/null`
	if [ "x${mysql_binary}" = "x" ]; then
		echo "No 'mysql' binary found - no flushing."
		return
	fi

	# check for mysql user/ pass
	flush_user=${MYSQL_USER:-$USER}
	flush_pass=
	if [ "x${MYSQL_USER}" = "x" ]; then
		echo "Using current user '${flush_user}' and no password for flushing - may not working."
	else
		if [ "x${MYSQL_PASS}" = "x" ]; then
			echo "No mySql password set for flushing - may not working."
		else
			flush_pass="--password=${MYSQL_PASS}"
		fi
	fi

	echo -n "Flushing mySql with user '${flush_user}': "
	mysql_output=$(mysql -u $flush_user $flush_pass -e 'flush tables;' 2>&1)
	mysql_success=$?
	if [ "$mysql_success" -gt 0 ]; then
		echo "unsuccessful!"
		echo -e "\tError-report:\n\t\t${mysql_output}"
	else
		echo "done."
	fi
}

function start_backup() {
	echo -n "Creating new temp dir '${BACKUP_DIR}': "
	mkdir $BACKUP_DIR
	echo "done."

	cd $BACKUP_DIR
	tar_filename="${FILE_NAME}.tar"
	if [ -f "$tar_filename" ]; then
		rm -f ${tar_filename}
	fi

        EXCLUDE_DIRS=""
	for exclude_dir in ${TAR_EXCLUDE_DIRS}
	do
		EXCLUDE_DIRS="${EXCLUDE_DIRS} --exclude=${exclude_dir}"
	done

	echo -n "Tar-ing directories: "
	tar_output=$(tar -c ${TMP_TAR_OPT} -f ${tar_filename} ${EXCLUDE_DIRS} ${TAR_DIRS} 2>&1)
	tar_success=$?
	# 0 'successful exit'
	# 1 'Some files differ' - e.q. 'file changed while reading' - is O.K. for us
	if [ "$tar_success" -gt 1 ]; then
		UPLOAD_FILENAME=
		echo "unsuccessful!"
		echo -e "Error-report:\n$tar_output"
		exit 2
	else
		UPLOAD_FILENAME=$tar_filename
		UPLOAD_FILE_SIZE=$(calculate_size ${UPLOAD_FILENAME})
		echo "done (upload-file: '${UPLOAD_FILENAME}' | ${UPLOAD_FILE_SIZE})."
	fi
}

function encrypt_file() {
	cd $BACKUP_DIR

	tar_file=$UPLOAD_FILENAME
	out_file="${tar_file}.enc"

	# check if at least a base file is existing
	if [[ "x${tar_file}" = "x" || ( ! -f $tar_file ) ]]; then
		echo "No valid tar-file '${tar_file}' found - quit!"
		exit 1
	fi

	# check for encryption pass file
	if [ "x${ENC_PASS_FILE}" = "x" ]; then
		echo "No ecryption passphrase file set - no ecryption is used."
		return 0
	fi

	# check if pass file is existing
	if ! [ -f $ENC_PASS_FILE ]; then
		echo "Specified encryption passphrase file is not existing - no ecryption is used."
		return 0
	fi

	echo -n "Encrypting '${tar_file}': "
	enc_output=$(openssl ${OPENSSL_OPT} -in ${tar_file} -out ${out_file} 2>&1)
	enc_success=$?
	if [ "$enc_success" -gt 0 ]; then
		UPLOAD_FILENAME=
		echo "unsuccessful!"
		echo -e "\tError-report:\n\t\t${enc_output}"
		exit 2
	else
		UPLOAD_FILENAME=$out_file
		UPLOAD_FILE_SIZE=$(calculate_size ${UPLOAD_FILENAME})
		echo "done (upload-file: '${UPLOAD_FILENAME}' | ${UPLOAD_FILE_SIZE})."
	fi

}

function clean_up_ftp() {
	cd $BACKUP_DIR
	echo -n "Loading backups on ftp host '${FTP_HOST}' in directory '${FTP_DIR}': "
	ftp_dir_listing=$(ftp -n ${FTP_HOST} 2> ftp_upload.log << EOFTP
ascii
user $FTP_USER $FTP_PASS
mkdir $FTP_DIR
cd $FTP_DIR
dir
quit
EOFTP
	)
	echo "done."

	# switch separator - and remember old one
	OLD_IFS=$IFS
	IFS=$(echo -en "\n\b")

	FTP_FILES=()
	for ftp_listing_line in $ftp_dir_listing; do

		listing_file=$(echo $ftp_listing_line | awk '{print $9}')
		if [ "x${listing_file}" != "x" ]; then
			FTP_FILES+=($listing_file)
		fi
	done
	IFS=$OLD_IFS

	# check if files needs to be deleted
	if [ "${#FTP_FILES[@]}" -lt "$FTP_FILE_COUNT" ]; then
		echo "No files on ftp server needs to be deleted ($((${#FTP_FILES[@]} + 1)) | $FTP_FILE_COUNT)"
		return
	fi

	# deleting old files
	for ftp_file in "${FTP_FILES[@]:0:((${#FTP_FILES[@]} - $FTP_FILE_COUNT + 1))}"; do
	        echo -n "Deleting '$ftp_file' on ftp server: "
		ftp_delete=$(ftp -n ${FTP_HOST} 2>&1 > ftp_upload.log << EOFTP
ascii
user $FTP_USER $FTP_PASS
cd $FTP_DIR
del $ftp_file
quit
EOFTP
	)

		echo "done."
	done
}

function start_upload() {
	cd $BACKUP_DIR
	echo -n "Starting uploading '$UPLOAD_FILENAME': "
	ftp_upload=$(ftp -n ${FTP_HOST} 2>&1 > ftp_upload.log << EOFTP
ascii
user $FTP_USER $FTP_PASS
mkdir $FTP_DIR
cd $FTP_DIR
del $UPLOAD_FILENAME
put $UPLOAD_FILENAME
quit
EOFTP
	)
	echo "done."
}

echo "Started backup at: $(date +'%H:%M:%S %Z')."

# check for at least needed commands
check_commands

# clean-up temp dir - if already exists
clean_up_temp_dir

# flush mysql if accessible
flush_mysql

# start backup
start_backup

# encrypt data
encrypt_file

# clean-up existing files
clean_up_ftp

# start ftp upload
start_upload

cd $CURR_DIR

# finally clean-up temp dir
clean_up_temp_dir

TS_FINISH=$(date +'%s')
((DURATION = TS_FINISH - TS_START))
PRETTY_DURATION=$(calculate_pretty_duration ${DURATION})
echo "Finished backup at: $(date +'%H:%M:%S') - took ${PRETTY_DURATION} (${DURATION} sec.)."
