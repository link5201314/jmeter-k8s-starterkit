#!/bin/bash

export ORACLE_BASE=/u01/app
export ORACLE_HOME=/u01/app/oracle/product/23.0.0.0/dbhome_1
export ORACLE_SID=CDBC1
export ORACLE_TERM=xterm
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:/u01/app/xag/bin:/u01/app/ogg:$PATH:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/lib:/usr/lib
export THREADS_FLAG=native
export CLASSPATH=$ORACLE_HOME/JRE:$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib:$ORACLE_HOME/network/jlib
export TEMP=/tmp
export TMPDIR=/tmp
export ORA_NLS33=$ORACLE_HOME/nls/data
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

cdate=`date +%Y%m%d%H%M%S`


while getopts "p:r:" opt; do
  case $opt in
    p)
      pdbn=$OPTARG
      ;;
    r)
      rpn=$OPTARG
      ;;
    \?)
      echo "Incorrect Option :  -$OPTARG" >&2
      exit 1
      ;;
  esac
done


pdb=`echo ${pdbn} |tr '[a-z]' '[A-Z]'`
rp_name=`echo ${rpn} |tr '[a-z]' '[A-Z]'`


restore_rp_sql_1(){
local f_pdb=$1
local f_rp=$2

echo "----- PDB: $f_pdb close"

output=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
alter pluggable database $f_pdb close immediate instances=all;
exit;
EOF
)

if echo "$output" | grep -i "error\|ORA-"; then
    echo "ERROR: Failed to close PDB $f_pdb"
    echo "$output"
    exit 1
fi
}


restore_rp_sql_2(){
local f_pdb=$1
local f_rp=$2

echo "----- Flashbackup PDB : $f_pdb to Restore Point: $f_rp"

output=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
FLASHBACK PLUGGABLE DATABASE $f_pdb TO RESTORE POINT $f_rp;
exit;
EOF
)

if echo "$output" | grep -i "error\|ORA-"; then
    echo "ERROR: Failed to flashback PDB $f_pdb to restore point $f_rp"
    echo "$output"
    echo ""
    echo "Troubleshooting suggestions:"
    echo "1. Check flashback database logs are enabled:"
    echo "   SELECT flashback_on FROM v\$database WHERE name='CDBC1';"
    echo "2. Check restore point exists:"
    echo "   SELECT name, scn, time FROM v\$restore_point WHERE name='$f_rp';"
    echo "3. Check recovery file destination:"
    echo "   SELECT name, value FROM v\$parameter WHERE name LIKE 'db_recovery%';"
    echo "4. Check available space in recovery area:"
    echo "   SELECT * FROM v\$recovery_file_dest;"
    exit 1
fi
}


restore_rp_sql_3(){
local f_pdb=$1
local f_rp=$2

echo "----- PDB: $f_pdb Open Resetlogs"
output=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
ALTER PLUGGABLE DATABASE $f_pdb OPEN RESETLOGS ;
ALTER PLUGGABLE DATABASE $f_pdb OPEN instances=all;
exit;
EOF
)

if echo "$output" | grep -i "error\|ORA-"; then
    echo "ERROR: Failed to open PDB $f_pdb with RESETLOGS"
    echo "$output"
    exit 1
fi
}


restore_pdb_ck(){
local f_pdb=$1
local f_rp=$2

echo "----- Verifying restore point status for PDB: $f_pdb"

rp_info=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
select name, to_char(time, 'YYYY-MM-DD HH24:MI:SS'), scn from v\\\$restore_point where name='$f_rp' and con_id=(select con_id from v\\\$pdbs where name='${pdb}' );
exit;
EOF`

if [ -z "$rp_info" ] || [ $(echo "$rp_info" | wc -w) -eq 0 ]
   then
       echo "WARNING: Restore point '$f_rp' not found"
       echo "The flashback database operation may have failed."
       return 1
else
       echo "SUCCESS: PDB $f_pdb has been restored to restore point $f_rp"
       echo "Restore Point Details:"
       echo "$rp_info"
       return 0
fi


}

ck_rp=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
select name from v\\$restore_point where name='${rp_name}' and con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF
` 
count_rp=`echo ${ck_rp} | wc -w`

if [ ${count_rp} == 0 ]
then 
    echo "ERROR: No Restore Point '$rp_name' found for PDB '$pdb'"
    echo "Please verify the restore point name and PDB name."
    exit 1
fi

echo ""
echo "===== Starting Flashback Database Recovery ====="
echo "PDB: $pdb"
echo "Restore Point: $rp_name"
echo "=================================================="
echo ""

restore_rp_sql_1 $pdb $rp_name
if [ $? -ne 0 ]; then
    echo "Failed to close PDB"
    exit 1
fi

sleep 5
restore_rp_sql_2 $pdb $rp_name
if [ $? -ne 0 ]; then
    echo "Failed to flashback PDB"
    exit 1
fi

sleep 5
restore_rp_sql_3 $pdb $rp_name
if [ $? -ne 0 ]; then
    echo "Failed to open PDB with RESETLOGS"
    exit 1
fi

sleep 5
restore_pdb_ck $pdb $rp_name
if [ $? -ne 0 ]; then
    echo "Restore point verification failed"
    exit 1
fi

echo ""
echo "===== Flashback Recovery Completed Successfully ====="
exit 0





