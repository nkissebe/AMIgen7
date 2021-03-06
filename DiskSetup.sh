#!/bin/bash
#
# Script to automate basic setup of CHROOT device
#
#################################################################
PROGNAME=$(basename "$0")
BOOTDEVSZ="500m"
FSTYPE="xfs"

# Error-logging
function err_exit {
   echo "${1}" > /dev/stderr
   logger -t "${PROGNAME}" -p kern.crit "${1}"
   exit 1
}

# Check for arguments
if [[ $# -lt 1 ]]
then
   (
    printf "Missing parameter(s). Valid flags/parameters are:\n"
    printf "\t-b|--bootlabel: FS-label applied to '/boot' filesystem\n"
    printf "\t-d|--disk: dev-path to disk to be partitioned\n"
    printf "\t-r|--rootlabel: FS-label to apply to '/' filesystem (no LVM in use)\n"
    printf "\t-v|--vgname: LVM2 Volume-Group name for root volumes\n"
    printf "Aborting...\n"
   ) > /dev/stderr
   exit 1
fi

function LogBrk() {
   echo "${2}" > /dev/stderr
   exit "${1}"
}

# Partition as LVM
function CarveLVM() {
   local ROOTVOL=(rootVol 4g)
   local SWAPVOL=(swapVol 2g)
   local HOMEVOL=(homeVol 1g)
   local VARVOL=(varVol 2g)
   local LOGVOL=(logVol 1g)
   local AUDVOL=(auditVol 100%FREE)

   # Clear the MBR and partition table
   dd if=/dev/zero of="${CHROOTDEV}" bs=512 count=1000 > /dev/null 2>&1

   # Lay down the base partitions
   parted -s "${CHROOTDEV}" -- mklabel msdos mkpart primary ${FSTYPE} 2048s ${BOOTDEVSZ} \
      mkpart primary ${FSTYPE} ${BOOTDEVSZ} 100% set 2 lvm

   # Stop/umount boot device, in case parted/udev/systemd managed to remount it
   systemctl stop boot.mount

   # Create LVM objects
   vgcreate -y "${VGNAME}" "${CHROOTDEV}2" || LogBrk 5 "VG creation failed. Aborting!"
   lvcreate --yes -W y -L "${ROOTVOL[1]}" -n "${ROOTVOL[0]}" "${VGNAME}" || LVCSTAT=1
   if [[ "${SWAPON}" = 1 ]]; then
     lvcreate --yes -W y -L "${SWAPVOL[1]}" -n "${SWAPVOL[0]}" "${VGNAME}" || LVCSTAT=1
   fi
   lvcreate --yes -W y -L "${HOMEVOL[1]}" -n "${HOMEVOL[0]}" "${VGNAME}" || LVCSTAT=1
   lvcreate --yes -W y -L "${VARVOL[1]}" -n "${VARVOL[0]}" "${VGNAME}" || LVCSTAT=1
   lvcreate --yes -W y -L "${LOGVOL[1]}" -n "${LOGVOL[0]}" "${VGNAME}" || LVCSTAT=1
   lvcreate --yes -W y -l "${AUDVOL[1]}" -n "${AUDVOL[0]}" "${VGNAME}" || LVCSTAT=1

   if [[ ${LVCSTAT} = 1 ]]
   then
      echo "Failed creating one or more volumes. Aborting"
      exit 1
   fi

   # Gather info to diagnose seeming /boot race condition
   grep "${BOOTLABEL}" /proc/mounts
   if [[ $? -eq 0 ]]
   then
     tail -n 100 /var/log/messages
     sleep 3
   fi

   # Stop/umount boot device, in case parted/udev/systemd managed to remount it
   # again.
   systemctl stop boot.mount

   # Create filesystems
   mkfs -t ${FSTYPE} -L "${BOOTLABEL}" "${CHROOTDEV}1" || err_exit "Failure creating filesystem - /boot"
   mkfs -t ${FSTYPE} "/dev/${VGNAME}/${ROOTVOL[0]}" || err_exit "Failure creating filesystem - /"
   mkfs -t ${FSTYPE} "/dev/${VGNAME}/${HOMEVOL[0]}" || err_exit "Failure creating filesystem - /home"
   mkfs -t ${FSTYPE} "/dev/${VGNAME}/${VARVOL[0]}" || err_exit "Failure creating filesystem - /var"
   mkfs -t ${FSTYPE} "/dev/${VGNAME}/${LOGVOL[0]}" || err_exit "Failure creating filesystem - /var/log"
   mkfs -t ${FSTYPE} "/dev/${VGNAME}/${AUDVOL[0]}" || err_exit "Failure creating filesystem - /var/log/audit"
   if [[ "${SWAPON}" = 1 ]]; then
      mkswap "/dev/${VGNAME}/${SWAPVOL[0]}"
   fi
   if [[ $(e2label "${CHROOTDEV}1") != ${BOOTLABEL} ]]
   then
      e2label "${CHROOTDEV}1" "${BOOTLABEL}" || \
         err_exit "Failed to apply desired label to ${CHROOTDEV}1"
   fi
}

# Partition with no LVM
function CarveBare() {
   # Clear the MBR and partition table
   dd if=/dev/zero of="${CHROOTDEV}" bs=512 count=1000 > /dev/null 2>&1

   # Lay down the base partitions
   parted -s "${CHROOTDEV}" -- mklabel msdos mkpart primary ${FSTYPE} 2048s "${BOOTDEVSZ}" \
      mkpart primary ${FSTYPE} ${BOOTDEVSZ} 100%

   # Create FS on partitions
   mkfs -t ${FSTYPE} -L "${BOOTLABEL}" "${CHROOTDEV}1"
   mkfs -t ${FSTYPE} -L "${ROOTLABEL}" "${CHROOTDEV}2"
}



######################
## Main program-flow
######################
OPTIONBUFR=$(getopt -o b:d:r:v: --long bootlabel:,disk:,rootlabel:,vgname: -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -s|--swapon)
            case "$2" in
               *)
               SWAPON=1
                  shift 2;
               ;;
            esac
            ;;
               
      -b|--bootlabel)
	    case "$2" in
	       "")
	          LogBrk 1 "Error: option required but not specified"
	          shift 2;
	          exit 1
	          ;;
	       *)
               BOOTLABEL=${2}
	          shift 2;
	       ;;
	    esac
	    ;;
      -d|--disk)
	    case "$2" in
	       "")
	          LogBrk 1 "Error: option required but not specified"
	          shift 2;
	          exit 1
	          ;;
	       *)
               CHROOTDEV=${2}
	          shift 2;
	       ;;
	    esac
	    ;;
      -r|--rootlabel)
	    case "$2" in
	       "")
	          LogBrk 1"Error: option required but not specified"
	          shift 2;
	          exit 1
	          ;;
	       *)
               ROOTLABEL=${2}
	          shift 2;
	       ;;
	    esac
	    ;;
      -v|--vgname)
	    case "$2" in
	       "")
	          LogBrk 1 "Error: option required but not specified"
	          shift 2;
	          exit 1
	          ;;
	       *)
               VGNAME=${2}
	          shift 2;
	       ;;
	    esac
	    ;;
      --)
         shift
         break
         ;;
      *)
         LogBrk 1 "Internal error!"
         exit 1
         ;;
   esac
done

if [[ -z ${BOOTLABEL+xxx} ]]
then
   LogBrk 1 "Cannot continue without 'bootlabel' being specified. Aborting..."
elif [[ ! -z ${ROOTLABEL+xxx} ]] && [[ ! -z ${VGNAME+xxx} ]]
then
   LogBrk 1 "The 'rootlabel' and 'vgname' arguments are mutually exclusive. Exiting."
elif [[ -z ${ROOTLABEL+xxx} ]] && [[ ! -z ${VGNAME+xxx} ]]
then
   CarveLVM
elif [[ ! -z ${ROOTLABEL+xxx} ]] && [[ -z ${VGNAME+xxx} ]]
then
   CarveBare
fi
