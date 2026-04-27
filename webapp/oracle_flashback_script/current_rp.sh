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


select_rp_ck(){
local f_pdb=$1

rp_1=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
select name from v\\$restore_point where con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF`

for i in ${rp_1}
  do
    echo "RESTORE POINT: "$i
  done


}

ck_rp=`sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
select name from v\\$restore_point where con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF
` 
count_rp=`echo ${ck_rp} | wc -w`

if [ ${count_rp} == 0 ]
then 
    echo "No Restore Poinrt Select"
    exit 1
fi

select_rp_ck $pdb 
   
