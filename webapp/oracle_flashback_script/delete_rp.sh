#!/bin/bash

set -o nounset
set -o pipefail

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

usage() {
  echo "Usage: $0 -p <pdb_name> -r <restore_point_name>"
}

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
      usage
      exit 1
      ;;
  esac
done

pdbn=${pdbn:-}
rpn=${rpn:-}
if [ -z "$pdbn" ] || [ -z "$rpn" ]; then
  echo "ERROR: Both PDB name and restore point name are required."
  usage
  exit 1
fi

pdb=$(echo "$pdbn" | tr '[:lower:]' '[:upper:]')
rp_name=$(echo "$rpn" | tr '[:lower:]' '[:upper:]')



drop_rp_sql(){
local f_pdb=$1
local f_rp=$2

output=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
DROP RESTORE POINT ${f_rp} FOR PLUGGABLE DATABASE ${f_pdb};
exit;
EOF
)

if echo "$output" | grep -i "error\|ORA-"; then
  echo "ERROR: Failed to drop restore point '$f_rp' for PDB '$f_pdb'"
  echo "$output"
  return 1
fi

return 0
}


del_rp_ck(){
local f_pdb=$1
local f_rp=$2

rp_1=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
select count(*) from v\\$restore_point where name='$f_rp' and con_id=(select con_id from v\\$pdbs where name='${f_pdb}' );
exit;
EOF
)

if echo "$rp_1" | grep -i "error\|ORA-"; then
  echo "ERROR: Failed to verify restore point deletion"
  echo "$rp_1"
  return 1
fi

rp_count=$(echo "$rp_1" | tr -d '[:space:]')
if [ -z "$rp_count" ]; then
  echo "ERROR: Empty verification result while checking restore point deletion"
  return 1
fi

if [ "$rp_count" = "0" ]
   then
     echo "DROP PDB: ${f_pdb} restore point : ${f_rp} successfully !"
     return 0
else
     echo "DROP PDB: ${f_pdb} restore point : ${f_rp} fail !"
     return 1
fi


}

ck_rp=$(sqlplus -s "/ as sysdba" << EOF
set feedback off;
set heading off;
set pagesize 0;
select name from v\\$restore_point where name='${rp_name}' and con_id=(select con_id from v\\$pdbs where name='${pdb}' );
exit;
EOF
) 

if echo "$ck_rp" | grep -i "error\|ORA-"; then
  echo "ERROR: Failed to check existing restore point"
  echo "$ck_rp"
  exit 1
fi

count_rp=$(echo "$ck_rp" | wc -w)

if [ "$count_rp" = "0" ]
then 
  echo "ERROR: No Restore Point '$rp_name' found for PDB '$pdb'"
    exit 1
fi

echo ""
echo "===== Starting Restore Point Deletion ====="
echo "PDB: $pdb"
echo "Restore Point: $rp_name"
echo "==========================================="
echo ""

drop_rp_sql "$pdb" "$rp_name"
if [ $? -ne 0 ]; then
  exit 1
fi

del_rp_ck "$pdb" "$rp_name"
if [ $? -ne 0 ]; then
  exit 1
fi

echo ""
echo "===== Restore Point Deletion Completed Successfully ====="
exit 0
   
