#!/bin/bash
echo -n "running clock MHz: "
nvidia-smi -q -d CLOCK | awk '/Clocks/{c=1; next} /Graphics/ && c {split($2,a,"MHZ"); print a[1]; exit}'
echo -n "GPU temp C: "
nvidia-smi -q -d TEMPERATURE | awk '/GPU Current Temp/{print $4; exit}'
echo -n "hottest sysfs thermal C: "
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk 'NR==1{m=$1} $1>m{m=$1} END{print m/1000}'
