#!/usr/bin/env bash

. ../wvtest.sh

#set -e

# cluster, account and user
_cluster=tcluster
_account=taccount
_user=tuser

sbank()
{
    "../src/sbank" "$@"
}

WVSTART "init"

WVPASS which perl
WVPASS which scontrol
WVPASS which sacctmgr
WVPASS which sshare
WVPASS which sinfo
WVPASS which sbatch

WVFAIL sbank

WVSTART "sbank time"

WVPASSEQ "$(sbank time calc -t 4-00:00:00)" "96"
WVPASSEQ "$(sbank time estimate -N 4 -c 8 -t 24)" "768"
WVPASSEQ "$(sbank time estimate -n 32 -t 96)" "3072"
WVPASSEQ "$(sbank time estimate -n 32 -t $(sbank time calc -t 4-00:00:00))" "3072"
WVPASSEQ "$(sbank time estimate -n 64 -t 96)" "$(sbank time estimate -n 64 -t $(sbank time calc -t 4-00:00:00))"

WVSTART "sbank balance"

WVPASS sbank time estimatescript -s sample-job1.sh
WVPASS sbank time estimatescript -s sample-job2.sh

WVSTART "sbank cluster"

WVPASS sbank cluster create -c $_cluster
WVPASS sbank cluster delete -c $_cluster

WVPASSRC sbank cluster cpupernode
WVPASSRC sbank cluster cpupernode -m
WVPASSRC sbank cluster list
WVPASSRC sbank cluster list -a

WVSTART "sbank project"

WVPASS sbank cluster create -c $_cluster
WVPASS sbank project create -c $_cluster -a $_account
WVPASSEQ "$(sbank project list -c $_cluster | awk '{print $2}' | grep $_account)" "$_account"
WVPASS sbank project delete -c $_cluster -a $_account
WVPASS sbank cluster delete -c $_cluster

WVSTART "sbank deposit"

WVPASS sbank cluster create -c $_cluster
WVPASS sbank project create -c $_cluster -a $_account
WVPASSEQ "$(sbank project list -c $_cluster | awk '{print $2}' | grep $_account)" "$_account"
WVPASS sbank deposit -c $_cluster -a $_account -t 1000
WVPASSEQ "$(sbank balance request -a taccount -c tcluster -t 500)" "-500"
WVPASS sbank project delete -c $_cluster -a $_account
WVPASS sbank cluster delete -c $_cluster
