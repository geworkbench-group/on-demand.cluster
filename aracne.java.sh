#!/bin/bash
# this is based on cloud.aracne.java.sh but allows the actual jar file, data file, and parameters
# the clustering part is based on cluster.aracne.sh

# instruction: this is how you run this script with some actual parameters
# $ ./aracne.java.sh wise-mantra-567 aracne_1.1.jar devtest/bcell-100.tab.txt devtest/GO_3700plus_TFs_HG-U95Av2.txt 0.00000001
# where $1 is the Google Cloud project ID; $2 is the complete java command with all the parameters and the options, quoted.

if [ $# -ne 5 ]
    then
        echo "Usage: ./aracne.java.sh project_id executable_jar exp_file tfs_file pvalue"
        exit
fi
START=`date +%s`
    
readonly PROJECT_ID=$1 # Google Cloud project ID
readonly EXECUTABLE_JAR=$2
readonly EXP_FILE=$3
readonly TFS_FILE=$4
readonly P_VALUE=$5

readonly OUTPUT_DIRECTORY=aracne
readonly RESULT_FILE=finalNetwork_4col.tsv

gcloud config set project $PROJECT_ID 

source cluster_properties.sh > /dev/null
./cluster_setup.sh up-full
gcloud config set compute/zone $MASTER_NODE_ZONE

gcloud compute copy-files ./install.sge.master.sh ./cluster_properties.sh $MASTER_NODE_NAME_PATTERN:~/.
echo ">>> setting up SGE master ..."
gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $MASTER_NODE_NAME_PATTERN --command ./install.sge.master.sh &> /dev/null
rc=$?; if [[ $rc != 0 ]]; then ./cluster_setup.sh down-full; exit $rc; fi
echo ">>> done setting up the master: $MASTER_NODE_NAME_PATTERN"
readonly INSTANCE_NAME=$MASTER_NODE_NAME_PATTERN

gcloud compute copy-files $EXECUTABLE_JAR $EXP_FILE $INSTANCE_NAME:~/.

# worker node name formatter
function worker_node_name() {
    local instance_id="$1"
    printf $WORKER_NODE_NAME_PATTERN $instance_id
}
readonly -f worker_node_name

echo ">>> setting up SGE workers ..."
for ((i = 0; i < $WORKER_NODE_COUNT; i++)) do
    echo "Configuring worker node $(worker_node_name $i)"
    gcloud compute copy-files ./install.worker.sh $(worker_node_name $i):~/.
    gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $(worker_node_name $i) --command ./install.worker.sh &> /dev/null
    rc=$?; if [[ $rc != 0 ]]; then ./cluster_setup.sh down-full; exit $rc; fi

    gcloud compute copy-files $EXECUTABLE_JAR $EXP_FILE $TFS_FILE $(worker_node_name $i):~/.
done
echo ">>> done setting up $WORKER_NODE_COUNT workers"

# Step 1: Calculated MI Threshold for desired p-value:
echo ">>> starting Step 1 ..."
STEP1_COMMAND="java -jar $EXECUTABLE_JAR -e $EXP_FILE -o $OUTPUT_DIRECTORY --pvalue $P_VALUE --seed 1 --calculateThreshold > step1log.txt"
echo "The command to be execuated: $STEP1_COMMAND"
gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $INSTANCE_NAME --command "$STEP1_COMMAND"

# copy the preprocessed threshold file to each node - not the best way, but just do this for now
gcloud compute copy-files $INSTANCE_NAME:~/"$OUTPUT_DIRECTORY"/miThreshold_*.txt .
for ((i = 0; i < $WORKER_NODE_COUNT; i++)) do
    gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $(worker_node_name $i) --command "mkdir -p $OUTPUT_DIRECTORY"
    gcloud compute copy-files ./miThreshold_*.txt $(worker_node_name $i):~/"$OUTPUT_DIRECTORY"/.
done

# Step 2: Run this main bootstrapping step e.g. 100 times.  The seed value should step from 1 to 100 (unless we hear otherwise).
echo ">>> starting Step 2 ..."
START2=`date +%s`
FULL_COMMAND="java -jar $EXECUTABLE_JAR -e $EXP_FILE -o $OUTPUT_DIRECTORY --tfs $TFS_FILE --pvalue $P_VALUE"
echo "The command to be execuated on the cluster: $FULL_COMMAND"
echo "#!/bin/bash
# request Bourne shell as shell for job
#$ -S /bin/sh
#$ -t 1-20 -cwd -j y -o ./aracne.log
$FULL_COMMAND --seed \$SGE_TASK_ID > aracne.job.log" > qsub.job.sh
gcloud compute copy-files qsub.job.sh $INSTANCE_NAME:~/.
gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $INSTANCE_NAME --command "qsub ./qsub.job.sh"

# check status
QSTAT_COUNT="-1"
while [ "$QSTAT_COUNT" -ne "0" ]
do
    sleep 60 # wait 60 seconds before checking the status again
    QSTAT_COUNT=$(gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $INSTANCE_NAME --command "qstat|wc -l")
    echo "$(( $QSTAT_COUNT - 2 )) jobs in queue..."
done
END2=`date +%s`

# copy all the results to the master - not the most brilliant way, but just do this for now
rm -r -f results
mkdir results
for ((i = 0; i < $WORKER_NODE_COUNT; i++)) do
    gcloud compute copy-files $(worker_node_name $i):~/$OUTPUT_DIRECTORY/bootstrapNetwork_*.txt ./results
done
gcloud compute copy-files ./results/bootstrapNetwork_*.txt $INSTANCE_NAME:~/$OUTPUT_DIRECTORY

# Step 3: Consolidate to one consenus network:
echo ">>> starting Step 3 ..."
STEP3_COMMAND="java -jar $EXECUTABLE_JAR -o $OUTPUT_DIRECTORY --consolidate"
echo "The command to be execuated: $STEP3_COMMAND"
gcloud compute ssh --ssh-flag="-o LogLevel=ERROR" $INSTANCE_NAME --command "$STEP3_COMMAND"

# copy the result back
#rm -r -f results
#mkdir results
gcloud compute copy-files $INSTANCE_NAME:~/java.version.txt $INSTANCE_NAME:~/$OUTPUT_DIRECTORY/$RESULT_FILE ./results

# delete all the VM instances and disks
./cluster_setup.sh down-full &> /dev/null

# check the results
echo "What are in the results directory?"
ls -lt results/

echo "please double check nothing is left running"
gcloud compute instances list
gcloud compute disks list

date
END=`date +%s`
ELAPSED=$(( ( $END - $START ) / 60 ))
ELAPSED2=$(( ( $END2 - $START2 ) / 60 ))
echo "total time $ELAPSED minutes; step 2 time $ELAPSED2 minutes"
