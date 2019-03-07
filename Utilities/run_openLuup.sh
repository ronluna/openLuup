#!/bin/bash
echo "Starting openLuup server"
echo "To see tail of logfile: tail -f ./out.log"
cd /etc/cmh-ludl
sudo rm ./out.log
nohup ./openLuup_reload >> out.log 2>&1 &