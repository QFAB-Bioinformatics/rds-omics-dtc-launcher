#!/usr/bin/env bash

###
#   Launcher script for the RDS Omics project Data Transfer Client (DTC)
#
#   Extends the DTC to having robust logging and notification features
#
#   Expects:
#       • to be run in the same directory as the DTC JAR artefact
#       • NFS share to data is setup as defined in configs (DTC itself will fail)
#       • firewall:
#           • internet access (for REST API and IM notification)
#           • port 25 for email notification
#           • DaRIS/Mediaflux port as defined in configs
#
#   Author: QFAB/Thom Cuddihy (https://github.com/thomcuddihy)
###

## Set variables
# Paths
LOG_DIR="/var/log/dtc"
SLACK_TOOLS="/home/t.cuddihy/slack_tools"
DTC_JAR_FILE="omics-mf-upload.jar"
STUDIES_FILE="dtc_studies.txt"

# Misc
RUN_MODES=(data metadata scan-only)
FROM_EMAIL="data.client@omics.data.edu.au (Data Transfer Client)"
CREATE_TAG="TRACE omics.mf.upload.daris.DarisUtil - Creating"

## Notification settings
## add entries to the array declaractions
# EMAIL
DAILY_EMAIL=("t.cuddihy@qfab.org")
UPLOAD_EMAIL=("t.cuddihy@qfab.org")
#ERROR_EMAIL=("dc-support@qriscloud.zendesk.com" "t.cuddihy@qfab.org")
ERROR_EMAIL=("t.cuddihy@qfab.org")
DEV_EMAIL=("t.cuddihy@qfab.org")

# SLACK
DAILY_CHANNEL=("#upload_logs")
UPLOAD_CHANNEL=("@thom")
ERROR_CHANNEL=("@thom")
DEV_CHANNEL=("@thom")

### Script functions

notify_script_error() {
    ## issue with the script, not the client -> notify devs!
    # usage: notify_script_error "this is the error"
    ERROR_MSG=${1}
    NOTIFY_TITLE="DTC launch script error"

    for EMAIL in "${DEV_EMAIL[@]}" do: 
        echo ${ERROR_MSG} | mail -s ${NOTIFY_TITLE} -r ${FROM_EMAIL} ${EMAIL}
    done

    for CHANNEL in "${DEV_CHANNEL[@]}" do: 
        ${SLACK_TOOLS}/postslack -C ${CHANNEL} -rt "${ERROR_MSG}" -c danger -H ${NOTIFY_TITLE}
    done

    echo $1 >&2 && exit 1
}

process_error() {
    # use awk to separate: column 3("INFO", "WARN", "ERROR", "TRACE", "DEBUG")
    # map it out to an array
    mapfile -t ERROR_REPORT < <(awk '$3 == "ERROR" { print $0 "\\n" }' ${LOG_FILE})

    # check array count
    if [ ${#ERROR_REPORT[@]} -eq 0 ]; then
        # No errors!
        echo "No errors detected for ${STUDY_NAME}"
        HAS_ERROR=0
    else
        # Ah, humbug. Something went wrong...
        HAS_ERROR=1
        echo "Errors detected for ${STUDY_NAME}"
    fi
}

process_data() {
    # this will be the hard one
    # only way is to extend the client to have a tag for new uploads and use cat/grep instead of awk
    mapfile -t DATA_REPORT < <(grep -i "${CREATE_TAG}" ${LOG_FILE})
    ## ^ need to suffix with newline to get notify to work as-is
}

process_summary() {
    mapfile -t INFO_REPORT < <(awk '$3 == "INFO" { print $0 "\\n" }' ${LOG_FILE})

    if [ ${#INFO_REPORT[@]} -eq 0 ]; then
        HAS_ERROR=1
        ## append to ERROR_REPORT: "INFO summary returned null"
    else
        ## ???
    fi
}

notify(){
    # if HAS_ERROR: send to... e.g.
    NOTIFY_EMAIL=...
    NOTIFY_CHANNEL=...
    # if HAS_ERROR: disable cron, gzip verbose log and send that instead of summary report

    # email:
    for EMAIL in "${NOTIFY_EMAIL[@]}" do: 
        echo -e "${INFO_REPORT[@]}" | mail -s "${SUBJECT}" -a "${LOG_FILE}" -r "${FROM_EMAIL}" ${EMAIL}
    done
    
    # slack: (can't use newlines in sendfiles, so send post and file)
    for CHANNEL in "${NOTIFY_CHANNEL[@]}" do: 
        ${SLACK_TOOLS}/postslack -T ${SLACK_TOKEN} -C ${CHANNEL} -rt "`echo ${INFO_REPORT[@]}`"
        ${SLACK_TOOLS}/sendslack -a ${SLACK_TOKEN} -c ${CHANNEL} -f "${LOG_FILE}" -t "${SUBJECT}"
    done
}

clean_log() {
    # converts verbose log to standard log, appends timecode
    # this file will be kept for record keeping
    CLEAN_LOG_FILE="${LOG_DIR}/${STUDY_NAME}_`date +%Y-%m-%d`"
    awk '{ if ($3 == "ERROR" || $3 == "INFO" || $3 == "WARN") print $0 "\\n" }' ${LOG_FILE} > ${CLEAN_LOG_FILE}
}

process_study() {
    # usage: process_study "CONF_PATH" "STUDY_NAME" "RUN_MODE"
    # sanity check $1 (file exists), $2 (string, not null), $3 in ${RUN_MODES[@]}
    [[ ! ${#} -eq 3 ]] && notify_script_error "process_study() called with incorrect args"

    [[ ! -f ${1} ]] && notify_script_error "${1} conf file not found"
    CONF_PATH=${1}

    [[ ! -z "${1}" ]] && notify_script_error "${2} not valid name for ${CONF_PATH} study"
    STUDY_NAME=${2}

    [[ ! " ${RUN_MODES[@]} " =~ " ${3} " ]] && notify_script_error "${3} not valid run mode for ${STUDY_NAME}"
    RUN_MODE=${3}

    echo "Passed pre-checks OK for ${STUDY_NAME}"
    # set defaults
    HAS_ERROR=1 # assume to have error until proven otherwise
    HAS_DATA=2 # will check whether all studies updated (0) or any new (1). (2) indicates not checked (error)
    LOG_FILE="${LOG_DIR}/${STUDY_NAME}_verbose.log"
    SUBJECT="${STUDY} Log `date +%Y-%m-%d`" # setup subject date/time code now to indicate start of run

    # Call DTC JAR (verbose logging required)
    echo "Running DTC for ${STUDY_NAME}"
    ./omics-mf-upload --config ${CONF_PATH} -v ${RUN_MODE} &> ${LOG_FILE}

    # check that log file exists
    [[ ! -f ${LOG_FILE} ]] && notify_script_error "${STUDY_NAME} log file not found"
    # check if log file last modified >~24hrs ago (i.e. not updated by today's run!)
    [[ ! -f $(find ${LOG_FILE} -mmin +1400) ]] && notify_script_error "${STUDY_NAME} log file not updated"
    
    # note to self: what to do if upload takes longer than 24hrs? or process hangs?
    echo "DTC run completed, processing..."

    # process log for errors
    process_error()

    # process log for new data
    process_data()

    # process log for summary
    process_summary()

    # notify result of run..
    echo "Processing completed, notifying outcome"
    notify()

    # clean log (remove TRACE and DEBUG info) and store
    echo "Cycling cleaned log for storage"
    clean_log()
    echo "DTC run for ${STUDY_NAME} completed"
}

### Entry code
# sanity checks that Java and JAR exists, slack tools emplaced, studies list file exists
echo "Starting DTC Launcher"
echo "Performing basic checks"
[[ -z $(which java) ]] && notify_script_error "Java not found"

DTC_JAR_PATH=$(dirname ${0})/${DTC_JAR_FILE}
[[ ! -f ${DTC_JAR_PATH} ]] && notify_script_error "${DTC_JAR_PATH} not found"

[[ ! -f ${SLACK_TOOLS}/postslack ]] && notify_script_error "postslack not found"
[[ ! -f ${SLACK_TOOLS}/sendslack ]] && notify_script_error "sendslack not found"

STUDIES_PATH=$(dirname ${0})/${STUDIES_FILE}
[[ ! -f ${STUDIES_PATH} ]] && notify_script_error "${STUDIES_PATH} not found"

echo "Tests passed OK"
echo "Running DTC..."
# loop through each study entry in the studies list file and process!
while read -r CONF_PATH STUDY_NAME RUN_MODE; do
  process_study ${CONF_PATH} ${STUDY_NAME} ${RUN_MODE}
done < ${STUDIES_PATH}

echo "DTC launcher completed"

### tinker's notes
## to finish:
#   process_error()
#       logic for final notification report
#   process_data()
#       need to extend dtc to log new uploads, report logically
#       logic for final notification report
#   process_summary()
#       logic for final notification report
#   notify()
#       logic for final notification report