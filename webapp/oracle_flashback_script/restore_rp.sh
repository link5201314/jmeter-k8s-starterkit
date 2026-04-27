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

sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
alter pluggable database $f_pdb close immediate instances=all;
exit;
EOF
}


restore_rp_sql_2(){
local f_pdb=$1
local f_rp=$2

echo "----- Flashbackup PDB : $f_pdb to Restore Point: $f_rp"

sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
FLASHBACK PLUGGABLE DATABASE $f_pdb TO RESTORE POINT $f_rp;
exit;
EOF
}


restore_rp_sql_3(){
local f_pdb=$1
local f_rp=$2

echo "----- PDB: $f_pdb Open Resetlogs"
sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
ALTER PLUGGABLE DATABASE $f_pdb OPEN RESETLOGS ;
ALTER PLUGGABLE DATABASE $f_pdb OPEN instances=all;
exit;
EOF
}


restore_pdb_ck(){
local f_pdb=$1
local f_rp=$2

rp_1=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
select count(*) from v\\$restore_point where name='$f_rp' and con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF`

if [ $rp_1 == 0 ]
   then
       echo "RESTORE PDB: ${pdb} restore point : ${rp_name} successfully !"
else
       echo "RESTORE PDB: ${pdb} restore point : ${rp_name} fail ! "
fi


}

ck_rp=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
select name from v\\$restore_point where name=${rp_name} and con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF
` 
count_rp=`echo ${ck_rp} | wc -w`

if [ ${count_rp} == 0 ]
then 
    echo "No Restore Poinrt to restore"
    exit 1
fi


restore_rp_sql_1 $pdb $rp_name
sleep 5
restore_rp_sql_2 $pdb $rp_name
sleep 5
restore_rp_sql_3 $pdb $rp_name
sleep 5





