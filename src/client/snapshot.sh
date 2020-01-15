#!/bin/sh



LogVerbose(){
	return 0
	#print "LVMBACKUP $1"
}

LogError(){
	LogVerbose "ERROR $1"
}

get_snapshot_path() {
	local VMNAME=$1
	local SNAPSHOT_PATH=/dev/mapper/`lvs --noheadings -o vg_name,lv_name --separator=- ${VMNAME} | xargs echo -n`--snapshot
	echo $SNAPSHOT_PATH
}

start_snapshot() {
	local VMPATH="$1"
	LogVerbose "Start Snapshot ${VMPATH}"

	VMNAME_SNAPSHOT=`basename ${VMPATH}`
	LVINFO=`lvdisplay -c ${VMPATH}`
	SNAPSHOTSIZE=$((`echo ${LVINFO} | cut -d: -f7` / 2048/1000))G
	if [ -L "${VMPATH}-snapshot" ]; then
		return 1
	fi
	lvcreate -L 512M --snapshot --name ${VMNAME_SNAPSHOT}-snapshot ${VMPATH} > /dev/null

	SNAPSHOT_PATH=`get_snapshot_path ${VMPATH}`
	kpartx -a ${SNAPSHOT_PATH}
	echo ${SNAPSHOT_PATH} 
}

stop_snapshot() {
	local SNAPSHOT_PATH="$1"

	if [ ! -L ${SNAPSHOT_PATH} ]; then
		LogVerbose "Snapshot not found ${SNAPSHOT_PATH}"
		return 0

	fi

	LogVerbose "Stop snapshot ${SNAPSHOT_PATH}"
	kpartx -d ${SNAPSHOT_PATH}
	if [ ! $? -eq 0 ]; then
		LogError "Failed to remove partitions ${SNAPSHOT_PATH} with kpartx"
		return 1
	fi	
	lvremove --force ${SNAPSHOT_PATH}
	if [ ! $? -eq 0 ]; then
		LogError "Failed to remove snapshot ${SNAPSHOT_PATH} with lvremove"
		return 1 
	fi

	return 0
}

mount_partitions() {
	SNAPSHOT_PATH="$1"
	LogVerbose "Mount partitions ${SNAPSHOT_PATH}"

	sleep 1
	SNAPSHOTS=`echo "${SNAPSHOT_PATH}[1-99]"`
	ITEMS=`ls $SNAPSHOTS` > /dev/null 2>&1
	if [ ! $? -eq 0 ]; then
		LogVerbose "No partitions to mount for ${SNAPSHOT_PATH}"
		return 1
	fi

	for i in `ls $SNAPSHOTS`
	do
		local mount_name=`basename $i`
		local mount_directory="${MOUNT_PATH}/${mount_name}"
		if [ ! -d ${mount_directory} ]; then
			mkdir ${mount_directory}
		fi

		local partition_type=`blkid -o export $i | grep '^.*TYPE' | cut -d"=" -f2`
		if [ "$partition_type" = lvm2pv ]; then
			break;
		elif [ "$partition_type" = swap ]; then
			break;
		else
			mount ${i} ${mount_directory} > /dev/null 2>/dev/null
			if [ $? -eq 0 ]; then
				echo ${mount_directory}
			fi
		fi
	done
}

umount_partitions() {
	SNAPSHOT_PATH="$1"
	SNAPSHOTS=`echo "${SNAPSHOT_PATH}[1-99]"`
	ITEMS=`ls $SNAPSHOTS` > /dev/null 2>&1
	if [ ! $? -eq 0 ]; then
		LogVerbose "No partitions to umount for ${SNAPSHOT_PATH}"
		return 0
	fi
	
	LogVerbose "Remove partitions ${SNAPSHOT_PATH}"
	for i in $ITEMS 
	do
		local mount_name=`basename $i`
		local mount_directory="${MOUNT_PATH}/${mount_name}"
		local partition_type=`blkid -o export $i | grep '^.*TYPE' | cut -d"=" -f2`

		if ! mount | grep "${mount_directory}" > /dev/null; then
			LogVerbose "Not mounted, ignoring ${mount_directory}"
			continue
		fi

		LogVerbose "Umount ${i} ${mount_directory} ${partition_type}"
		if [ "$partition_type" = lvm2pv ]; then
			break;
		elif [ "$partition_type" = swap ]; then
			break;
		else
			umount ${mount_directory}
			if [ ! $? -eq 0 ]; then
				LogError "Unable to umount ${mount_directory}"
				return 1
			fi
		fi

		if [ -d ${mount_directory} ]; then
			rmdir ${mount_directory}
			if [ ! $? -eq 0 ]; then
				LogError "Unable to rmdir ${mount_directory}"
				return 1
			fi
		fi
	done

	return 0
}

MOUNT_PATH="/mnt/snapshots"
if [ ! -d $MOUNT_PATH ]; then
	mkdir -p ${MOUNT_PATH}
fi

if [ ! $# -eq 2 ]
then
	LogError "Invalid arguments provided"
	exit 1
fi

LogVerbose "Snapshot $2"

if [ "$1" = "create" ]; then
	SNAPSHOT_PATH=$(start_snapshot $2)
	if [ $? -eq 1 ]; then
		echo "Unable to create snapshot"
		exit 1
	fi
	LogVerbose "Create snapshots at ${SNAPSHOT_PATH}"
	mount_partitions ${SNAPSHOT_PATH}
	exit 0

fi

if [ "$1" = "delete" ]; then
	SNAPSHOT_PATH=`get_snapshot_path $2`
	LogVerbose "Delete snapshots from ${SNAPSHOT_PATH}"
	umount_partitions ${SNAPSHOT_PATH} 
	if [ $? -eq 1 ]; then
		exit 1
	fi
	stop_snapshot ${SNAPSHOT_PATH}
	if [ $? -eq 1 ]; then
		exit 1
	fi
	exit 0
fi

LogError "No action provided"
exit 1



